import Foundation

/// Shared UserDefaults keys for product Settings (native multi-pane).
public enum ProductPreferenceKey {
    public static let airgapMode = "screenlog.airgapMode"
    /// Explicit consent to send website domains to the public favicon provider.
    /// Missing keys intentionally read as `false` so upgrades remain private.
    public static let remoteFaviconsEnabled = "screenlog.remoteFaviconsEnabled"
    public static let launchAtLogin = "screenlog.launchAtLogin"
    public static let showDockIcon = "screenlog.showDockIcon"
    public static let pauseOnInactivity = "screenlog.pauseOnInactivity"
    /// Which connected displays are saved during each capture interval.
    /// Missing keys preserve the original active-display behavior.
    public static let captureDisplayMode = "screenlog.capture.displayMode"
    /// Persisted only after the user explicitly starts or stops capture.
    public static let captureEnabled = "screenlog.captureEnabled"
    /// Paired wall-clock values for a user-requested timed capture pause.
    public static let timedCapturePauseStartedAt = "screenlog.capturePause.startedAt"
    public static let timedCapturePauseResumeAt = "screenlog.capturePause.resumeAt"
    public static let appearance = "screenlog.appearance"  // system|light|dark
    public static let storageMode = "screenlog.storageMode"  // off|compress|limit
    public static let cliEnabled = "screenlog.cliEnabled"
    /// Explicit opt-in for local command-line tools to control capture or run
    /// Library maintenance. A missing key intentionally keeps tool access
    /// read-only.
    public static let localToolCaptureControlAndMaintenanceEnabled =
        "screenlog.localTool.captureControlAndMaintenanceEnabled"
    public static let excludePrivateTabs = "screenlog.excludePrivateTabs"
    /// When true, supported browsers are not captured unless the active website
    /// domain can be identified. Missing keys stay false for upgrade continuity.
    public static let pauseWhenBrowserAddressUnavailable = "screenlog.exclude.pauseWhenBrowserAddressUnavailable"
    public static let accentColor = "screenlog.accentColor"
    public static let showOpenExternally = "screenlog.ui.showOpenExternally"
    public static let showLiveText = "screenlog.ui.showLiveText"
    public static let showZoomControls = "screenlog.ui.showZoomControls"
    public static let showSegmentNavigation = "screenlog.ui.showSegmentNavigation"
    public static let assistantHandoffRouting = "screenlog.assistantHandoff.routing"
    public static let excludePasswordManagers = "screenlog.exclude.passwordManagers"
    public static let excludeBanksCategory = "screenlog.exclude.banks"
    /// Audio transcription is deliberately opt-in. Source switches retain
    /// their choices while the master switch is off.
    public static let audioTranscriptionEnabled = "screenlog.audioTranscription.enabled"
    public static let computerAudioTranscriptionEnabled =
        "screenlog.audioTranscription.computerAudio"
    public static let microphoneTranscriptionEnabled =
        "screenlog.audioTranscription.microphone"
}

/// Privacy-first persisted settings for on-device audio transcription.
public enum AudioTranscriptionPreferenceStore {
    public struct Snapshot: Equatable, Sendable {
        public var isEnabled: Bool
        public var computerAudioEnabled: Bool
        public var microphoneEnabled: Bool

        public init(
            isEnabled: Bool = false,
            computerAudioEnabled: Bool = true,
            microphoneEnabled: Bool = true
        ) {
            self.isEnabled = isEnabled
            self.computerAudioEnabled = computerAudioEnabled
            self.microphoneEnabled = microphoneEnabled
        }

        public var enabledSources: Set<TranscriptSource> {
            guard isEnabled else { return [] }
            var sources: Set<TranscriptSource> = []
            if computerAudioEnabled { sources.insert(.computer) }
            if microphoneEnabled { sources.insert(.microphone) }
            return sources
        }
    }

    public static func load(
        from defaults: UserDefaults = ScreenlogProcessPreferences.current
    ) -> Snapshot {
        Snapshot(
            isEnabled: defaults.bool(forKey: ProductPreferenceKey.audioTranscriptionEnabled),
            computerAudioEnabled: defaults.object(
                forKey: ProductPreferenceKey.computerAudioTranscriptionEnabled
            ) == nil
                ? true
                : defaults.bool(forKey: ProductPreferenceKey.computerAudioTranscriptionEnabled),
            microphoneEnabled: defaults.object(
                forKey: ProductPreferenceKey.microphoneTranscriptionEnabled
            ) == nil
                ? true
                : defaults.bool(forKey: ProductPreferenceKey.microphoneTranscriptionEnabled)
        )
    }

    public static func save(
        _ snapshot: Snapshot,
        to defaults: UserDefaults = ScreenlogProcessPreferences.current
    ) {
        defaults.set(snapshot.isEnabled, forKey: ProductPreferenceKey.audioTranscriptionEnabled)
        defaults.set(
            snapshot.computerAudioEnabled,
            forKey: ProductPreferenceKey.computerAudioTranscriptionEnabled
        )
        defaults.set(
            snapshot.microphoneEnabled,
            forKey: ProductPreferenceKey.microphoneTranscriptionEnabled
        )
    }
}

/// Persisted authorization for mutating commands sent through Screenlogger's
/// local tool bridge. The UI can bind a toggle to this API without becoming the
/// security boundary: socket and XPC hosts read this preference for every
/// mutating request.
public enum LocalToolControlAccessPreference {
    public static func isEnabled(
        in defaults: UserDefaults = ScreenlogProcessPreferences.current
    ) -> Bool {
        defaults.bool(
            forKey: ProductPreferenceKey.localToolCaptureControlAndMaintenanceEnabled
        )
    }

    public static func save(
        _ enabled: Bool,
        to defaults: UserDefaults = ScreenlogProcessPreferences.current
    ) {
        defaults.set(
            enabled,
            forKey: ProductPreferenceKey.localToolCaptureControlAndMaintenanceEnabled
        )
    }
}

/// Tri-state capture intent: `nil` means onboarding has not asked yet.
public enum CaptureIntentPreference {
    public static func value(from defaults: UserDefaults) -> Bool? {
        guard defaults.object(forKey: ProductPreferenceKey.captureEnabled) != nil else { return nil }
        return defaults.bool(forKey: ProductPreferenceKey.captureEnabled)
    }

    public static func save(_ enabled: Bool, to defaults: UserDefaults) {
        defaults.set(enabled, forKey: ProductPreferenceKey.captureEnabled)
    }
}

/// Durable state for the one-hour capture pause.
///
/// Both the start and resume dates are stored so malformed values and clock
/// changes can be handled deliberately. A backward clock jump re-anchors the
/// original duration from the new current time, favoring the user's privacy;
/// expired or invalid state is cleared so it cannot create an indefinite pause.
public enum TimedCapturePausePreference {
    public static let maximumDuration: TimeInterval = 60 * 60

    public static func save(
        startedAt: Date,
        resumeAt: Date,
        to defaults: UserDefaults
    ) {
        let duration = resumeAt.timeIntervalSince(startedAt)
        guard startedAt.timeIntervalSince1970.isFinite,
            resumeAt.timeIntervalSince1970.isFinite,
            duration > 0,
            duration <= maximumDuration
        else {
            clear(from: defaults)
            return
        }
        defaults.set(
            startedAt.timeIntervalSince1970,
            forKey: ProductPreferenceKey.timedCapturePauseStartedAt
        )
        defaults.set(
            resumeAt.timeIntervalSince1970,
            forKey: ProductPreferenceKey.timedCapturePauseResumeAt
        )
    }

    public static func restoredResumeDate(
        from defaults: UserDefaults,
        now: Date = Date()
    ) -> Date? {
        guard now.timeIntervalSince1970.isFinite,
            let startedTimestamp = defaults.object(
                forKey: ProductPreferenceKey.timedCapturePauseStartedAt
            ) as? Double,
            let resumeTimestamp = defaults.object(
                forKey: ProductPreferenceKey.timedCapturePauseResumeAt
            ) as? Double,
            startedTimestamp.isFinite,
            resumeTimestamp.isFinite
        else {
            clear(from: defaults)
            return nil
        }

        let startedAt = Date(timeIntervalSince1970: startedTimestamp)
        let resumeAt = Date(timeIntervalSince1970: resumeTimestamp)
        let duration = resumeAt.timeIntervalSince(startedAt)
        guard duration > 0, duration <= maximumDuration else {
            clear(from: defaults)
            return nil
        }

        if now >= resumeAt {
            clear(from: defaults)
            return nil
        }

        if now < startedAt {
            let adjustedResumeAt = now.addingTimeInterval(duration)
            save(startedAt: now, resumeAt: adjustedResumeAt, to: defaults)
            return adjustedResumeAt
        }

        return resumeAt
    }

    public static func clear(from defaults: UserDefaults) {
        defaults.removeObject(forKey: ProductPreferenceKey.timedCapturePauseStartedAt)
        defaults.removeObject(forKey: ProductPreferenceKey.timedCapturePauseResumeAt)
    }
}

/// Opt-in strict handling for supported browsers whose active website cannot
/// be attributed. A missing key intentionally preserves existing browser
/// capture behavior until the user enables the protection.
public enum BrowserAddressProtectionPreference {
    public static func value(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: ProductPreferenceKey.pauseWhenBrowserAddressUnavailable)
    }

    public static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: ProductPreferenceKey.pauseWhenBrowserAddressUnavailable)
    }
}

public enum AccentColorPreference: String, CaseIterable, Identifiable, Sendable {
    case system, azure, purple, pink, orange, green

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "System"
        case .azure: return "Azure"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .orange: return "Orange"
        case .green: return "Green"
        }
    }
}

public enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

public enum StorageManagementMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case compress
    case limit

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: return "Off"
        case .compress: return "Compress"
        case .limit: return "Limit"
        }
    }

    public var detail: String {
        switch self {
        case .off:
            return "No automatic cleanup. Data stays until you free space manually."
        case .compress:
            return "Compress older snapshots to video. Does not delete by age or size cap."
        case .limit:
            return "Compress, then remove the oldest capture media past the age or size limit. Searchable text remains."
        }
    }

    /// Pure mapping from product Storage mode to what the auto maintenance loop may run.
    /// - **off**: neither auto-compact nor auto-retention
    /// - **compress**: auto-compact only (no age/size purge)
    /// - **limit**: auto-compact + auto-retention using the configured days/cap
    public func maintenancePlan(
        retentionDays: Int,
        storageCapMB: Int64
    ) -> StorageMaintenancePlan {
        let days = max(1, retentionDays)
        let cap = max(0, storageCapMB)
        switch self {
        case .off:
            return StorageMaintenancePlan(
                runCompact: false,
                runRetention: false,
                retentionDays: days,
                storageCapMB: cap
            )
        case .compress:
            // Compact stills; disable retention by zeroing effective purge (engine still
            // skips retention when `runRetention` is false).
            return StorageMaintenancePlan(
                runCompact: true,
                runRetention: false,
                retentionDays: days,
                storageCapMB: 0
            )
        case .limit:
            return StorageMaintenancePlan(
                runCompact: true,
                runRetention: true,
                retentionDays: days,
                storageCapMB: cap
            )
        }
    }
}

/// What the recording engine maintenance loop should do for a storage mode.
public struct StorageMaintenancePlan: Equatable, Sendable {
    public var runCompact: Bool
    public var runRetention: Bool
    public var retentionDays: Int
    public var storageCapMB: Int64

    public init(
        runCompact: Bool,
        runRetention: Bool,
        retentionDays: Int,
        storageCapMB: Int64
    ) {
        self.runCompact = runCompact
        self.runRetention = runRetention
        self.retentionDays = retentionDays
        self.storageCapMB = storageCapMB
    }
}

// MARK: - Snapshot / capture quality prefs keys

/// Product-level capture fidelity. Ultra uses the zero maximum-dimension
/// sentinel so ScreenCaptureKit receives the display's native backing size.
public enum CaptureQualityPreset: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case standard
    case high
    case ultra

    public static let nativeResolutionMaxDimension = 0

    public var id: Int { rawValue }

    public var maxDimension: Int {
        switch self {
        case .standard: return 1_920
        case .high: return 2_880
        case .ultra: return Self.nativeResolutionMaxDimension
        }
    }

    public var stillCompressionQuality: Double {
        switch self {
        case .standard: return 0.88
        case .high: return 0.94
        case .ultra: return 0.99
        }
    }

    public var label: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        case .ultra: return "Ultra"
        }
    }

    public static func from(maxDimension: Int) -> CaptureQualityPreset {
        if maxDimension == nativeResolutionMaxDimension { return .ultra }
        if maxDimension <= CaptureQualityPreset.standard.maxDimension { return .standard }
        if maxDimension <= CaptureQualityPreset.high.maxDimension { return .high }
        return .ultra
    }

    /// Converts the three pre-release 720/1080/1440 values to the fidelity they
    /// represented in the UI. New values do not overlap those legacy sentinels.
    public static func migratedMaxDimension(_ storedValue: Int) -> Int {
        switch storedValue {
        case 720: return CaptureQualityPreset.standard.maxDimension
        case 1_080: return CaptureQualityPreset.high.maxDimension
        case 1_440: return CaptureQualityPreset.ultra.maxDimension
        default: return storedValue
        }
    }
}

extension ProductPreferenceKey {
    /// `heic` (default) or `jpeg` preferred still encoding.
    public static let stillEncoding = "screenlog.stillEncoding"
    /// Comma-separated Vision OCR language codes, e.g. `en-US` or `en-US,fr-FR`. Empty = system.
    public static let ocrLanguages = "screenlog.ocrLanguages"
    /// Prefer differential OCR when similar to previous frame.
    public static let differentialOCR = "screenlog.differentialOCR"
}

public enum StillEncodingPreference: String, CaseIterable, Identifiable, Sendable {
    case heic
    case jpeg

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .heic: return "HEIC (smaller)"
        case .jpeg: return "JPEG (compatible)"
        }
    }
}

/// The set of displays Screenlogger saves during one capture interval.
public enum CaptureDisplayMode: String, CaseIterable, Identifiable, Sendable {
    /// Follow the display containing the app the person is currently using.
    case active
    /// Save one moment for every display currently connected to the Mac.
    case all

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .active: return "Active display"
        case .all: return "All displays"
        }
    }
}

// MARK: - Capture / retention defaults (pure, unit-testable)

/// UserDefaults keys + load/save for capture interval, quality, retention.
/// Kept in Core so tests exercise the same keys AppModel uses.
public enum CapturePreferenceStore {
    public static let intervalSeconds = "screenlog.intervalSeconds"
    public static let maxDimension = "screenlog.maxDimension"
    public static let retentionDays = "screenlog.retentionDays"
    public static let storageCapMB = "screenlog.storageCapMB"
    public static let displayMode = ProductPreferenceKey.captureDisplayMode

    public struct Snapshot: Equatable, Sendable {
        public var intervalSeconds: Double
        public var maxDimension: Int
        public var retentionDays: Int
        public var storageCapMB: Int64
        public var storageMode: StorageManagementMode
        public var stillEncoding: StillEncodingPreference
        public var ocrLanguagesCSV: String
        public var differentialOCR: Bool
        public var displayMode: CaptureDisplayMode

        public init(
            intervalSeconds: Double = 2.0,
            maxDimension: Int = 2_880,
            retentionDays: Int = 30,
            storageCapMB: Int64 = 50_000,
            storageMode: StorageManagementMode = .limit,
            stillEncoding: StillEncodingPreference = .heic,
            ocrLanguagesCSV: String = "",
            differentialOCR: Bool = true,
            displayMode: CaptureDisplayMode = .active
        ) {
            self.intervalSeconds = intervalSeconds
            self.maxDimension = maxDimension
            self.retentionDays = retentionDays
            self.storageCapMB = storageCapMB
            self.storageMode = storageMode
            self.stillEncoding = stillEncoding
            self.ocrLanguagesCSV = ocrLanguagesCSV
            self.differentialOCR = differentialOCR
            self.displayMode = displayMode
        }

        public var ocrLanguages: [String] {
            ocrLanguagesCSV
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        public var maintenancePlan: StorageMaintenancePlan {
            storageMode.maintenancePlan(
                retentionDays: retentionDays,
                storageCapMB: storageCapMB
            )
        }
    }

    public static func load(from defaults: UserDefaults = .standard) -> Snapshot {
        var s = Snapshot()
        if defaults.object(forKey: intervalSeconds) != nil {
            s.intervalSeconds = max(0.5, defaults.double(forKey: intervalSeconds))
        }
        if defaults.object(forKey: maxDimension) != nil {
            let storedValue = defaults.integer(forKey: maxDimension)
            let migratedValue = CaptureQualityPreset.migratedMaxDimension(storedValue)
            s.maxDimension = migratedValue == 0 ? 0 : max(480, migratedValue)
        }
        if defaults.object(forKey: retentionDays) != nil {
            s.retentionDays = max(1, defaults.integer(forKey: retentionDays))
        }
        if defaults.object(forKey: storageCapMB) != nil {
            s.storageCapMB = max(0, Int64(defaults.integer(forKey: storageCapMB)))
        }
        if let raw = defaults.string(forKey: ProductPreferenceKey.storageMode),
            let mode = StorageManagementMode(rawValue: raw)
        {
            s.storageMode = mode
        }
        if let raw = defaults.string(forKey: ProductPreferenceKey.stillEncoding),
            let enc = StillEncodingPreference(rawValue: raw)
        {
            s.stillEncoding = enc
        }
        if let langs = defaults.string(forKey: ProductPreferenceKey.ocrLanguages) {
            s.ocrLanguagesCSV = langs
        }
        if defaults.object(forKey: ProductPreferenceKey.differentialOCR) != nil {
            s.differentialOCR = defaults.bool(forKey: ProductPreferenceKey.differentialOCR)
        }
        if let raw = defaults.string(forKey: displayMode),
            let mode = CaptureDisplayMode(rawValue: raw)
        {
            s.displayMode = mode
        }
        return s
    }

    public static func save(_ snapshot: Snapshot, to defaults: UserDefaults = .standard) {
        defaults.set(snapshot.intervalSeconds, forKey: intervalSeconds)
        defaults.set(snapshot.maxDimension, forKey: maxDimension)
        defaults.set(snapshot.retentionDays, forKey: retentionDays)
        defaults.set(snapshot.storageCapMB, forKey: storageCapMB)
        defaults.set(snapshot.storageMode.rawValue, forKey: ProductPreferenceKey.storageMode)
        defaults.set(snapshot.stillEncoding.rawValue, forKey: ProductPreferenceKey.stillEncoding)
        defaults.set(snapshot.ocrLanguagesCSV, forKey: ProductPreferenceKey.ocrLanguages)
        defaults.set(snapshot.differentialOCR, forKey: ProductPreferenceKey.differentialOCR)
        defaults.set(snapshot.displayMode.rawValue, forKey: displayMode)
    }
}
