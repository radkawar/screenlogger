import AppKit
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.screenlog", category: "recording")

/// Retry policy for unexpected capture failures. Keeping this separate from the
/// loop makes the behavior deterministic and prevents a broken capture source
/// from being hammered at the user's normal capture interval.
struct RecordingCaptureBackoff: Equatable {
    let baseDelay: TimeInterval
    let maximumDelay: TimeInterval

    init(baseDelay: TimeInterval = 2, maximumDelay: TimeInterval = 60) {
        self.baseDelay = max(0.5, baseDelay)
        self.maximumDelay = max(self.baseDelay, maximumDelay)
    }

    func delay(afterConsecutiveFailures failureCount: Int) -> TimeInterval {
        guard failureCount > 0 else { return 0 }
        let exponent = min(failureCount - 1, 20)
        return min(maximumDelay, baseDelay * pow(2, Double(exponent)))
    }
}

/// Product-owned capture protection. This is deliberately independent from
/// user preferences so Screenlogger can never record its own windows.
public enum ScreenloggerCapturePrivacy {
    public static let bundleIdentifier = "dev.screenlog.app"

    public static func isScreenlogger(bundleID: String?) -> Bool {
        bundleID?.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
    }

    public static func includingScreenlogger(in bundleIDs: Set<String>) -> Set<String> {
        var result = Set(bundleIDs.map { $0.lowercased() })
        result.insert(bundleIdentifier)
        return result
    }
}

// MARK: - Off-MainActor capture pipeline

/// Heavy capture work: ScreenCaptureKit stills, Vision OCR, HEIC encode, AX, SQLite writes.
/// Isolated from the UI so RecordingEngine's MainActor loop only hops back for published state.
private actor CapturePipeline {
    private let capture = ScreenCaptureService()
    private var differentialOCRByDisplay: [UInt32: DifferentialOCRService] = [:]
    private let fullOCR = OCRService()
    private let browserURL = BrowserURLService()
    private let axExtractor = AXTreeExtractor()

    private var exclusions: ExclusionStore = .shared
    private var dataRoot: URL?
    private var recognitionLanguages: [String] = []

    var maxDimension: Int = 2_880
    var stillQuality: Double = 0.94
    var captureAXTree = true
    var captureBrowserURL = true
    var useDifferentialOCR = true
    /// Skip store when browser title/URL looks like private / incognito.
    var excludePrivateTabs = true
    /// Fail closed for supported browsers when their active domain is unknown.
    var pauseWhenBrowserAddressUnavailable = false
    var displayMode: CaptureDisplayMode = .active

    struct CycleOutcome: Sendable {
        /// One frame per successfully stored display. Empty when privacy skips
        /// the entire interval.
        var frameIDs: [Int64]
        var ocrReused: Bool
        var axNodes: Int
        var pauseReason: CapturePauseReason?
    }

    func configure(
        exclusions: ExclusionStore,
        dataRoot: URL?,
        maxDimension: Int,
        stillQuality: Double,
        captureAXTree: Bool? = nil,
        captureBrowserURL: Bool? = nil,
        useDifferentialOCR: Bool? = nil,
        excludePrivateTabs: Bool? = nil,
        pauseWhenBrowserAddressUnavailable: Bool? = nil,
        displayMode: CaptureDisplayMode? = nil
    ) {
        self.exclusions = exclusions
        self.dataRoot = dataRoot
        self.maxDimension = maxDimension
        capture.maxDimension = maxDimension
        self.stillQuality = min(1, max(0, stillQuality))
        capture.stillQuality = self.stillQuality
        if let captureAXTree { self.captureAXTree = captureAXTree }
        if let captureBrowserURL { self.captureBrowserURL = captureBrowserURL }
        if let useDifferentialOCR { self.useDifferentialOCR = useDifferentialOCR }
        if let excludePrivateTabs { self.excludePrivateTabs = excludePrivateTabs }
        if let pauseWhenBrowserAddressUnavailable {
            self.pauseWhenBrowserAddressUnavailable = pauseWhenBrowserAddressUnavailable
        }
        if let displayMode {
            self.displayMode = displayMode
            capture.displayMode = displayMode
        }
    }

    func setExcludePrivateTabs(_ value: Bool) { excludePrivateTabs = value }
    func setPauseWhenBrowserAddressUnavailable(_ value: Bool) {
        pauseWhenBrowserAddressUnavailable = value
    }

    func applyCaptureQuality(maxDimension: Int, stillQuality: Double) {
        self.maxDimension = maxDimension
        capture.maxDimension = maxDimension
        self.stillQuality = min(1, max(0, stillQuality))
        capture.stillQuality = self.stillQuality
    }

    func setCaptureAXTree(_ value: Bool) { captureAXTree = value }
    func setCaptureBrowserURL(_ value: Bool) { captureBrowserURL = value }
    func setUseDifferentialOCR(_ value: Bool) { useDifferentialOCR = value }
    func setDisplayMode(_ value: CaptureDisplayMode) {
        displayMode = value
        capture.displayMode = value
    }

    func applyCaptureFlags(ax: Bool, browserURL: Bool, differentialOCR: Bool) {
        captureAXTree = ax
        captureBrowserURL = browserURL
        useDifferentialOCR = differentialOCR
    }

    func applySnapshotPrefs(preferJPEG: Bool, ocrLanguages: [String], differentialOCR: Bool) {
        capture.preferJPEG = preferJPEG
        recognitionLanguages = ocrLanguages
        fullOCR.recognitionLanguages = ocrLanguages
        for service in differentialOCRByDisplay.values {
            service.recognitionLanguages = ocrLanguages
            service.reset()
        }
        useDifferentialOCR = differentialOCR
    }

    func captureAndStore(store: Store) async throws -> CycleOutcome {
        // Cheap early exclusions before ScreenCaptureKit, OCR, or encoding.
        let earlyBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if ScreenloggerCapturePrivacy.isScreenlogger(bundleID: earlyBundle) {
            log.debug("skip capture: Screenlogger is frontmost")
            return CycleOutcome(
                frameIDs: [],
                ocrReused: false,
                axNodes: 0,
                pauseReason: .excludedContent
            )
        }

        var preflightBrowserAttribution: BrowserURLAttribution?
        if exclusions.hasWebsiteExclusions,
            BrowserURLService.isSupportedBrowser(bundleID: earlyBundle)
        {
            preflightBrowserAttribution = browserURL.frontmostBrowserAttribution()
        }
        let preflightDomain = preflightBrowserAttribution?.domain
        if exclusions.isExcluded(bundleID: earlyBundle, domain: preflightDomain) {
            log.info("skip capture: excluded frontmost bundle \(earlyBundle ?? "?", privacy: .private(mask: .hash))")
            return CycleOutcome(
                frameIDs: [],
                ocrReused: false,
                axNodes: 0,
                pauseReason: .excludedContent
            )
        }

        let excludedBundleIDs = excludedApplicationBundleIDs()
        var bitmaps = try await capture.captureDisplays(
            excludingApplicationsWithBundleIDs: excludedBundleIDs
        )
        guard !bitmaps.isEmpty else { throw CaptureError.noDisplay }
        let representativeTitle = bitmaps[0].focusedTitle
        let representativeBundleID = bitmaps[0].focusedBundleID
        let displayCount = bitmaps.count

        var url: String?
        var domain: String?
        var privacyURL: String?
        var privacyDomain: String?
        var title = representativeTitle ?? ""
        let bundleID = representativeBundleID ?? earlyBundle

        var browserAttribution: BrowserURLAttribution?
        if captureBrowserURL || excludePrivateTabs || pauseWhenBrowserAddressUnavailable
            || preflightBrowserAttribution != nil
        {
            // Re-read after the still. Preflight avoids work when the website
            // is already excluded; postflight prevents a tab or focus change
            // during capture from being attributed to the previous website.
            browserAttribution = browserURL.frontmostBrowserAttribution()
            // The foreground app can change while ScreenCaptureKit is working.
            // Never attach Browser B's address or title to Browser A's pixels.
            if let b = browserAttribution,
                b.observedBundleID == bundleID
            {
                privacyURL = b.url
                privacyDomain = b.domain
                if captureBrowserURL {
                    url = b.url
                    domain = b.domain
                }
                if let t = b.title, !t.isEmpty { title = t }
            }
        }

        if exclusions.isExcluded(bundleID: bundleID, domain: privacyDomain) {
            log.info(
                "skip frame storage: excluded bundle=\(bundleID ?? "-", privacy: .private(mask: .hash)) domain=\(privacyDomain ?? "-", privacy: .private(mask: .hash))"
            )
            return CycleOutcome(
                frameIDs: [],
                ocrReused: false,
                axNodes: 0,
                pauseReason: .excludedContent
            )
        }

        if excludePrivateTabs,
            PrivateBrowsingDetector.looksPrivate(
                title: title,
                url: privacyURL,
                bundleID: bundleID
            )
        {
            log.info(
                "skip private browsing tab bundle=\(bundleID ?? "-", privacy: .private(mask: .hash)) title=\(title, privacy: .private(mask: .hash))"
            )
            return CycleOutcome(
                frameIDs: [],
                ocrReused: false,
                axNodes: 0,
                pauseReason: .privateBrowsing
            )
        }

        if BrowserCapturePrivacyPolicy.shouldPause(
            capturedBundleID: bundleID,
            attribution: browserAttribution,
            pauseWhenAddressUnavailable: pauseWhenBrowserAddressUnavailable
        ) {
            log.info(
                "skip browser frame: address unavailable or changed bundle=\(bundleID ?? "-", privacy: .private(mask: .hash))"
            )
            return CycleOutcome(
                frameIDs: [],
                ocrReused: false,
                axNodes: 0,
                pauseReason: .browserAddressUnavailable
            )
        }

        var frameIDs: [Int64] = []
        var reusedCount = 0
        var axNodes = 0
        var attachedAXTree = false
        var firstFailure: Error?

        // Remove each processed bitmap so native multi-display buffers are
        // released as soon as their OCR and stored copy are complete.
        while !bitmaps.isEmpty {
            let bitmap = bitmaps.removeFirst()
            let visibleWindows = ScreenCaptureService.windows(
                bitmap.windowBounds,
                visibleOn: bitmap.captureDisplay
            ).filter { window in
                guard let bundleID = window.bundleID?.lowercased() else { return true }
                return !excludedBundleIDs.contains(bundleID)
            }
            let containsFocusedWindow =
                bundleID.map { focusedBundleID in
                    visibleWindows.contains(where: { $0.bundleID == focusedBundleID })
                } ?? false

            do {
                // Each display owns independent differential state. Alternating
                // between displays must never reuse text from a different screen.
                let rawOCR: OCRResult
                let reused: Bool
                if useDifferentialOCR {
                    let service = differentialOCRService(for: bitmap.displayID)
                    let diff = try await service.recognize(image: bitmap.image)
                    rawOCR = diff.result
                    reused = diff.reused
                } else {
                    rawOCR = try await fullOCR.recognize(image: bitmap.image)
                    reused = false
                }

                let attributed = OCRService.attributeToForegroundBackground(
                    result: rawOCR,
                    imageWidth: bitmap.width,
                    imageHeight: bitmap.height,
                    captureDisplay: bitmap.captureDisplay,
                    windowBounds: visibleWindows,
                    foregroundBundleID: bundleID,
                    allowVisibleWindowFallback: displayCount == 1 || containsFocusedWindow
                )

                // Attach the active browser address only to its visible window.
                var windowBounds = visibleWindows
                if let url, let bundleID {
                    if let index = windowBounds.indices
                        .sorted(by: { windowBounds[$0].zOrder < windowBounds[$1].zOrder })
                        .first(where: { windowBounds[$0].bundleID == bundleID })
                    {
                        windowBounds[index].url = url
                    }
                }

                // Encode exactly once, after privacy checks and OCR have
                // consumed the native ScreenCaptureKit image. Standard and
                // High resize only this stored copy; Ultra keeps native pixels.
                let encoded = try await capture.encodeStill(bitmap.image)
                let storedOCRBoxes = OCRService.rescaleBoxes(
                    attributed.boxes,
                    sourceWidth: bitmap.width,
                    sourceHeight: bitmap.height,
                    destinationWidth: encoded.pixelWidth,
                    destinationHeight: encoded.pixelHeight
                )
                let payload = CapturePayload(
                    imageData: encoded.data,
                    timestampMs: bitmap.timestampMs,
                    width: encoded.pixelWidth,
                    height: encoded.pixelHeight,
                    foreground: attributed.foreground,
                    background: attributed.background,
                    title: title,
                    bundleID: bundleID,
                    bundleVersion: bitmap.focusedBundleVersion ?? "",
                    displayName: bitmap.displayName,
                    url: url,
                    domain: domain,
                    ocrBoxes: storedOCRBoxes,
                    windowBounds: windowBounds,
                    isInactive: false,
                    imageFileExtension: encoded.fileExtension,
                    captureDisplay: bitmap.captureDisplay
                )

                let frameID = try store.store(payload: payload)
                frameIDs.append(frameID)
                if reused { reusedCount += 1 }

                if !attachedAXTree,
                    containsFocusedWindow || displayCount == 1,
                    captureAXTree,
                    AccessibilityPermission.isTrusted(prompt: false),
                    let snapshot = axExtractor.captureFocusedTree(
                        expectedPID: bitmap.focusedProcessID
                    )
                {
                    try store.storeAXSnapshot(frameID: frameID, snapshot: snapshot)
                    axNodes = snapshot.nodeCount
                    attachedAXTree = true
                }
            } catch {
                firstFailure = firstFailure ?? error
                log.error(
                    "display processing failed id=\(bitmap.displayID ?? 0): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if frameIDs.isEmpty {
            if let firstFailure { throw firstFailure }
        }

        return CycleOutcome(
            frameIDs: frameIDs,
            ocrReused: !frameIDs.isEmpty && reusedCount == frameIDs.count,
            axNodes: axNodes,
            pauseReason: nil
        )
    }

    private func differentialOCRService(for displayID: UInt32?) -> DifferentialOCRService {
        let key = displayID ?? UInt32.max
        if let existing = differentialOCRByDisplay[key] { return existing }
        let service = DifferentialOCRService()
        service.recognitionLanguages = recognitionLanguages
        differentialOCRByDisplay[key] = service
        return service
    }

    private func excludedApplicationBundleIDs() -> Set<String> {
        var bundleIDs = Set(exclusions.allSorted().map { $0.lowercased() })
        if exclusions.passwordManagersCategoryEnabled {
            bundleIDs.formUnion(ExclusionCatalog.passwordManagerBundleIDs.map { $0.lowercased() })
        }
        return ScreenloggerCapturePrivacy.includingScreenlogger(in: bundleIDs)
    }

    func runMaintenance(
        store: Store,
        retentionDays: Int,
        storageCapMB: Int64,
        runCompact: Bool = true,
        runRetention: Bool = true
    ) async {
        do {
            if runCompact {
                let compactor = VideoCompactionService()
                compactor.minBatchSize = 20
                let n = try compactor.compactIfNeeded(store: store)
                if n > 0 { log.info("auto-compacted \(n) frames") }
            }
            if runRetention {
                let policy = RetentionPolicy(
                    retentionDays: retentionDays,
                    storageCapMB: storageCapMB
                )
                _ = try RetentionService(policy: policy).run(store: store)
            }
        } catch {
            log.error("maintenance failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - UI-facing engine

/// Capture loop coordinator. **@MainActor only for published UI state**; heavy work runs in `CapturePipeline`.
@MainActor
public final class RecordingEngine: ObservableObject {
    public static let shared = RecordingEngine()

    @Published public private(set) var isRecording = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastFrameID: Int64?
    @Published public private(set) var framesCapturedSession: Int = 0
    @Published public private(set) var lastCycleFrameCount: Int = 0
    @Published public private(set) var lastOCRReused = false
    @Published public private(set) var lastAXNodes: Int = 0
    @Published public private(set) var pausedForDisk = false
    /// Why a running capture loop is intentionally not saving frames.
    @Published public private(set) var pauseReason: CapturePauseReason?
    @Published public private(set) var audioTranscriptionStatus: AudioTranscriptionStatus = .off
    /// True when an automatic compression/retention pass is due but is waiting
    /// for external power. User-initiated maintenance remains available.
    @Published public private(set) var automaticMaintenanceDeferredForPower = false

    public var intervalSeconds: TimeInterval = 2.0
    public private(set) var maxDimension: Int = 2_880
    public private(set) var stillQuality: Double = 0.94
    public var retentionDays: Int = 30
    /// Soft cap on compacted video size (MB). 0 = disabled. Default 50 GB.
    public var storageCapMB: Int64 = 50_000
    /// Auto maintenance: run HEVC compaction in the background loop.
    public var autoCompactEnabled = true
    /// Auto maintenance: run age/size retention in the background loop.
    public var autoRetentionEnabled = true
    /// Background video encoding and retention wait for external power by
    /// default. Live capture, OCR, and opted-in transcription remain continuous.
    public var deferAutomaticMaintenanceOnBattery = true
    /// When true, skip capture cycles while the user is system-idle.
    public var pauseOnInactivity = true
    /// Idle seconds before Pause on Inactivity skips a cycle (default 5 minutes).
    public var inactivityThresholdSeconds: TimeInterval = 300
    /// When true, skip storing browser private / incognito tabs.
    public var excludePrivateTabs = true {
        didSet {
            let v = excludePrivateTabs
            Task { await pipeline.setExcludePrivateTabs(v) }
        }
    }
    /// Privacy-first optional behavior for website exclusions. When enabled,
    /// known browsers are not stored unless their active domain is available.
    public var pauseWhenBrowserAddressUnavailable = false {
        didSet {
            let value = pauseWhenBrowserAddressUnavailable
            Task { await pipeline.setPauseWhenBrowserAddressUnavailable(value) }
        }
    }
    public var captureAXTree = true {
        didSet {
            let v = captureAXTree
            Task { await pipeline.setCaptureAXTree(v) }
        }
    }
    public var captureBrowserURL = true {
        didSet {
            let v = captureBrowserURL
            Task { await pipeline.setCaptureBrowserURL(v) }
        }
    }
    public var useDifferentialOCR = true {
        didSet {
            let v = useDifferentialOCR
            Task { await pipeline.setUseDifferentialOCR(v) }
        }
    }
    /// Prefer JPEG stills over HEIC.
    public var preferJPEGStill = false
    /// Vision OCR language codes (empty = system).
    public var ocrLanguages: [String] = []
    /// Which connected displays are saved during each capture interval.
    public private(set) var displayMode: CaptureDisplayMode = .active
    public private(set) var audioTranscriptionSettings =
        AudioTranscriptionPreferenceStore.Snapshot()
    /// Published when the capture loop is skipping due to idle (not disk).
    @Published public private(set) var pausedForInactivity = false

    private var task: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var audioControlTask: Task<Void, Never>?
    private var audioControlRevision: UInt64 = 0
    private let pipeline = CapturePipeline()
    private let audioTranscription = AudioTranscriptionCoordinator()
    private var store: Store?
    private var dataRoot: URL?
    private var exclusions: ExclusionStore = .shared

    public init() {
        audioTranscription.statusDidChange = { [weak self] status in
            self?.audioTranscriptionStatus = status
        }
    }

    public func configure(
        store: Store,
        dataRoot: URL? = nil,
        exclusions: ExclusionStore? = nil
    ) {
        self.store = store
        self.dataRoot = dataRoot ?? store.root
        if let exclusions {
            self.exclusions = exclusions
        }
        let root = self.dataRoot
        let excl = self.exclusions
        let dim = maxDimension
        let quality = stillQuality
        let ax = captureAXTree
        let browser = captureBrowserURL
        let diff = useDifferentialOCR
        let jpeg = preferJPEGStill
        let langs = ocrLanguages
        let displayMode = displayMode
        Task {
            await pipeline.configure(
                exclusions: excl,
                dataRoot: root,
                maxDimension: dim,
                stillQuality: quality,
                displayMode: displayMode
            )
            await pipeline.applyCaptureFlags(ax: ax, browserURL: browser, differentialOCR: diff)
            await pipeline.applySnapshotPrefs(
                preferJPEG: jpeg,
                ocrLanguages: langs,
                differentialOCR: diff
            )
            guard !Task.isCancelled else { return }
            scheduleAudioReconciliation()
        }
    }

    /// Apply explicit audio choices without coupling them to image quality or
    /// capture timing. The coordinator performs no microphone prompt itself.
    public func applyAudioTranscriptionSettings(
        _ settings: AudioTranscriptionPreferenceStore.Snapshot
    ) {
        audioTranscriptionSettings = settings
        scheduleAudioReconciliation()
    }

    /// Explicit recovery action used by Settings after a terminal framework
    /// failure or an exhausted automatic retry window.
    public func retryAudioTranscription() {
        scheduleAudioReconciliation(markCaptureAvailable: isRecording)
    }

    private func scheduleAudioReconciliation(markCaptureAvailable: Bool = false) {
        audioControlRevision &+= 1
        let requestedRevision = audioControlRevision
        audioControlTask?.cancel()
        audioControlTask = Task { [weak self] in
            guard let self,
                !Task.isCancelled,
                self.audioControlRevision == requestedRevision
            else { return }
            if markCaptureAvailable {
                await audioTranscription.setCaptureAvailable(true)
            }
            guard !Task.isCancelled,
                self.audioControlRevision == requestedRevision
            else { return }
            await reconcileAudioTranscription()
        }
    }

    private func reconcileAudioTranscription() async {
        await audioTranscription.apply(
            settings: audioTranscriptionSettings,
            captureIsRunning: isRecording,
            store: store,
            exclusions: exclusions,
            pauseWhenBrowserAddressUnavailable: pauseWhenBrowserAddressUnavailable
        )
    }

    /// Snapshot-class prefs (encoding, OCR languages, differential OCR).
    public func applySnapshotSettings(
        preferJPEG: Bool,
        ocrLanguages: [String],
        differentialOCR: Bool
    ) {
        preferJPEGStill = preferJPEG
        self.ocrLanguages = ocrLanguages
        useDifferentialOCR = differentialOCR
        let jpeg = preferJPEG
        let langs = ocrLanguages
        let diff = differentialOCR
        Task {
            await pipeline.applySnapshotPrefs(
                preferJPEG: jpeg,
                ocrLanguages: langs,
                differentialOCR: diff
            )
        }
    }

    /// Apply live settings from the app (interval, quality, retention, storage mode flags).
    public func applySettings(
        intervalSeconds: TimeInterval,
        maxDimension: Int,
        stillQuality: Double = 0.94,
        retentionDays: Int,
        storageCapMB: Int64 = 50_000,
        autoCompactEnabled: Bool = true,
        autoRetentionEnabled: Bool = true,
        pauseOnInactivity: Bool? = nil,
        inactivityThresholdSeconds: TimeInterval? = nil,
        excludePrivateTabs: Bool? = nil,
        pauseWhenBrowserAddressUnavailable: Bool? = nil,
        displayMode: CaptureDisplayMode = .active
    ) {
        let previousPauseWhenAddressUnavailable = self.pauseWhenBrowserAddressUnavailable
        self.intervalSeconds = max(0.5, intervalSeconds)
        self.maxDimension = maxDimension == 0 ? 0 : max(480, maxDimension)
        self.stillQuality = min(1, max(0, stillQuality))
        self.retentionDays = max(1, retentionDays)
        self.storageCapMB = max(0, storageCapMB)
        self.autoCompactEnabled = autoCompactEnabled
        self.autoRetentionEnabled = autoRetentionEnabled
        if let pauseOnInactivity { self.pauseOnInactivity = pauseOnInactivity }
        if let inactivityThresholdSeconds {
            self.inactivityThresholdSeconds = max(30, inactivityThresholdSeconds)
        }
        if let excludePrivateTabs { self.excludePrivateTabs = excludePrivateTabs }
        if let pauseWhenBrowserAddressUnavailable {
            self.pauseWhenBrowserAddressUnavailable = pauseWhenBrowserAddressUnavailable
        }
        self.displayMode = displayMode
        Task { await pipeline.setDisplayMode(displayMode) }
        applyCaptureQualityToPipeline()
        if previousPauseWhenAddressUnavailable != self.pauseWhenBrowserAddressUnavailable {
            scheduleAudioReconciliation()
        }
    }

    private func applyCaptureQualityToPipeline() {
        let dimension = maxDimension
        let quality = min(1, max(0, stillQuality))
        Task {
            await pipeline.applyCaptureQuality(
                maxDimension: dimension,
                stillQuality: quality
            )
        }
    }

    /// Apply a pure `StorageMaintenancePlan` (from `StorageManagementMode.maintenancePlan`).
    public func applyStoragePlan(_ plan: StorageMaintenancePlan) {
        retentionDays = plan.retentionDays
        storageCapMB = plan.storageCapMB
        autoCompactEnabled = plan.runCompact
        autoRetentionEnabled = plan.runRetention
    }

    /// Starts the capture loops and returns the authoritative resulting state.
    @discardableResult
    public func start() -> Bool {
        guard !isRecording else { return true }
        guard store != nil else {
            lastError = "Store not configured"
            isRecording = false
            return false
        }
        guard PermissionsSnapshot.currentFast().isCaptureReady else {
            lastError = "Screen Recording and Accessibility permissions are required"
            pauseReason = .permissionRequired
            isRecording = false
            return false
        }
        isRecording = true
        lastError = nil
        framesCapturedSession = 0
        lastCycleFrameCount = 0
        pausedForDisk = false
        pausedForInactivity = false
        pauseReason = nil
        // Unstructured task: awaits on pipeline release MainActor during OCR/encode/DB.
        task = Task { [weak self] in await self?.runLoop() }
        maintenanceTask = Task { [weak self] in await self?.maintenanceLoop() }
        scheduleAudioReconciliation(markCaptureAvailable: true)
        log.info("recording started interval=\(self.intervalSeconds)s")
        return isRecording
    }

    /// Stops capture and returns whether the engine reached the stopped state.
    @discardableResult
    public func stop() -> Bool {
        isRecording = false
        task?.cancel()
        task = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        automaticMaintenanceDeferredForPower = false
        audioControlRevision &+= 1
        audioControlTask?.cancel()
        audioTranscription.deactivateImmediately()
        audioControlTask = Task { [audioTranscription] in
            await audioTranscription.stop()
        }
        pausedForDisk = false
        pausedForInactivity = false
        pauseReason = nil
        log.info("recording stopped")
        return !isRecording
    }

    /// Stop and await both loops before a Library replacement closes SQLite.
    /// `stop()` is intentionally immediate for ordinary UI use; restore needs
    /// the stronger guarantee that no pipeline operation still holds `Store`.
    public func quiesceForLibraryReplacement() async {
        isRecording = false
        let captureTask = task
        let backgroundMaintenanceTask = maintenanceTask
        let previousAudioControlTask = audioControlTask
        captureTask?.cancel()
        backgroundMaintenanceTask?.cancel()
        task = nil
        maintenanceTask = nil
        audioControlRevision &+= 1
        previousAudioControlTask?.cancel()
        audioControlTask = nil
        audioTranscription.deactivateImmediately()
        _ = await captureTask?.result
        _ = await backgroundMaintenanceTask?.result
        _ = await previousAudioControlTask?.result
        await audioTranscription.stop()
        store = nil
        dataRoot = nil
        pausedForDisk = false
        pausedForInactivity = false
        pauseReason = nil
        log.info("recording quiesced for Library replacement")
    }

    public func captureOneNow() async throws -> Int64 {
        guard let store else { throw CaptureError.notAuthorized }
        guard PermissionsSnapshot.currentFast().isCaptureReady else {
            pauseReason = .permissionRequired
            throw CaptureError.notAuthorized
        }
        if let root = dataRoot ?? Optional(store.root),
            DiskSpaceMonitor.shared.shouldPauseRecording(dataRoot: root)
        {
            pausedForDisk = true
            pauseReason = .lowDiskSpace
            throw CaptureError.diskFull
        }
        // await pipeline to MainActor free during capture/OCR/store
        let outcome = try await pipeline.captureAndStore(store: store)
        if let reason = outcome.pauseReason {
            lastCycleFrameCount = 0
            pauseReason = reason
            throw CaptureError.excluded
        }
        guard let id = outcome.frameIDs.last else {
            throw CaptureError.excluded
        }
        pausedForDisk = false
        pausedForInactivity = false
        pauseReason = nil
        lastFrameID = id
        lastCycleFrameCount = outcome.frameIDs.count
        framesCapturedSession += outcome.frameIDs.count
        lastOCRReused = outcome.ocrReused
        lastAXNodes = outcome.axNodes
        lastError = nil
        return id
    }

    private func runLoop() async {
        let failureBackoff = RecordingCaptureBackoff()
        var consecutiveFailures = 0
        while !Task.isCancelled && isRecording {
            if !PermissionsSnapshot.currentFast().isCaptureReady {
                await audioTranscription.setCaptureAvailable(false)
                pausedForDisk = false
                pausedForInactivity = false
                pauseReason = .permissionRequired
                lastError = nil
                log.warning("capture paused: required macOS permissions are unavailable")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }

            // Disk check is cheap; keep on MainActor for published `pausedForDisk`.
            if let root = dataRoot ?? store?.root,
                DiskSpaceMonitor.shared.shouldPauseRecording(dataRoot: root)
            {
                await audioTranscription.setCaptureAvailable(false)
                pausedForDisk = true
                pausedForInactivity = false
                pauseReason = .lowDiskSpace
                lastError = nil
                log.warning("capture paused: free disk space below 1GB threshold")
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                continue
            }
            if pausedForDisk {
                log.info("disk space OK; resuming capture loop")
            }
            pausedForDisk = false

            // Pause on Inactivity - skip store while user is idle (no keyboard/mouse).
            if pauseOnInactivity,
                SystemIdleMonitor.isIdle(thresholdSeconds: inactivityThresholdSeconds)
            {
                await audioTranscription.setCaptureAvailable(false)
                if !pausedForInactivity {
                    log.info(
                        "capture paused for inactivity (idle >= \(Int(self.inactivityThresholdSeconds))s)"
                    )
                }
                pausedForInactivity = true
                pauseReason = .inactivity
                lastError = nil
                let ns = UInt64(intervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                continue
            }
            if pausedForInactivity {
                log.info("user active again; resuming capture")
            }
            pausedForInactivity = false
            await audioTranscription.setCaptureAvailable(true)

            do {
                if let store {
                    // Suspension point: CapturePipeline runs OCR / HEIC / DB off MainActor.
                    let outcome = try await pipeline.captureAndStore(store: store)
                    if let id = outcome.frameIDs.last {
                        lastFrameID = id
                        lastCycleFrameCount = outcome.frameIDs.count
                        framesCapturedSession += outcome.frameIDs.count
                        lastOCRReused = outcome.ocrReused
                        lastAXNodes = outcome.axNodes
                    }
                    pauseReason = outcome.pauseReason
                    if outcome.frameIDs.isEmpty { lastCycleFrameCount = 0 }
                    // A completed cycle (including an intentional exclusion) proves
                    // the capture pipeline is healthy and resets retry throttling.
                    consecutiveFailures = 0
                    lastError = nil
                    // A privacy pause is intentional and remains visible until
                    // the next cycle can save a frame.
                }
            } catch CaptureError.excluded {
                consecutiveFailures = 0
                lastError = nil
            } catch CaptureError.notAuthorized {
                consecutiveFailures = 0
                pauseReason = .permissionRequired
                lastError = nil
            } catch {
                consecutiveFailures += 1
                pauseReason = nil
                lastError = error.localizedDescription
                log.error("capture cycle failed: \(error.localizedDescription)")
            }
            let retryDelay = failureBackoff.delay(
                afterConsecutiveFailures: consecutiveFailures
            )
            let sleepSeconds = max(intervalSeconds, retryDelay)
            let ns = UInt64(sleepSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
        }
    }

    private func maintenanceLoop() async {
        var nextMaintenanceAt = Date().addingTimeInterval(300)
        while !Task.isCancelled && isRecording {
            // Polling power at this low cadence lets a queued pass begin soon
            // after AC returns without installing another long-lived callback.
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let store, !Task.isCancelled else { continue }
            guard Date() >= nextMaintenanceAt else { continue }
            let days = retentionDays
            let cap = storageCapMB
            let compact = autoCompactEnabled
            let retain = autoRetentionEnabled
            // Off mode: skip both. Compress: compact only. Limit: both.
            if !compact && !retain {
                automaticMaintenanceDeferredForPower = false
                nextMaintenanceAt = Date().addingTimeInterval(300)
                continue
            }
            if MaintenancePowerPolicy.shouldDeferAutomaticWork(
                powerSource: SystemPowerSource.current(),
                deferOnBattery: deferAutomaticMaintenanceOnBattery
            ) {
                automaticMaintenanceDeferredForPower = true
                continue
            }
            automaticMaintenanceDeferredForPower = false
            await pipeline.runMaintenance(
                store: store,
                retentionDays: days,
                storageCapMB: cap,
                runCompact: compact,
                runRetention: retain
            )
            nextMaintenanceAt = Date().addingTimeInterval(300)
        }
    }
}
