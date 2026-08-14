import AppKit
import Combine
import Foundation
import ScreenlogCore

@MainActor
final class AppModel: ObservableObject {
    // MARK: - Live state

    @Published var isRecording = false
    @Published var captureIssue: CaptureIssue?
    @Published var firstRunValueProgress = FirstRunValueProgress()
    /// Feature-scoped feedback for the manual Capture Now operation in Settings.
    @Published var captureOnceState: CaptureOnceState = .idle
    @Published var permissions = PermissionsSnapshot(screenRecording: false, accessibility: false)
    /// Optional microphone consent is intentionally separate from the two
    /// permissions required for screen capture readiness.
    @Published var microphoneAuthorization = MicrophoneAuthorization.current
    @Published var permissionJourney = PermissionJourney(
        snapshot: PermissionsSnapshot(screenRecording: false, accessibility: false)
    )
    @Published var permissionSettingsResult: PermissionSettingsOpenResult?
    @Published var stats: RecordingStats?
    @Published var recent: [FrameRow] = []
    @Published var timeline: [TimelineFrame] = [] {
        didSet {
            timelineNavigationIndex = TimelineNavigationIndex(frames: timeline)
            timelineTranscriptPassages = TimelineTranscriptPresentation.passages(from: timeline)
        }
    }
    /// Rebuilt once per loaded window so selection-driven UI reads do not rescan the Timeline.
    var timelineNavigationIndex = TimelineNavigationIndex(frames: [])
    /// UI-only grouping rebuilt once per loaded Timeline window. Canonical
    /// transcript rows remain untouched for search, export, and deletion.
    private(set) var timelineTranscriptPassages: [TimelineTranscriptPresentation.Passage] = []
    /// Display choice survives single-display gaps while stepping or replaying.
    /// It changes only when a new Timeline context is opened or the person
    /// explicitly chooses another captured display.
    var preferredTimelineDisplay: CaptureDisplayRect?
    var preferredTimelineDisplayIndex: Int?
    /// Store bootstrap failure is independent from capture, permissions, search,
    /// and ordinary Timeline query errors.
    @Published var libraryStartupIssue: LibraryStartupIssue?
    @Published var libraryBootstrapRetrying = false
    /// Recoverable Timeline/session navigation failure, separate from Library search.
    @Published var timelineIssue: TimelineIssue?
    /// Transient Timeline-local feedback. This never substitutes for capture,
    /// Library health, or another surface's authoritative status.
    @Published var timelineNotice: TimelineNotice?
    /// Primary Timeline query lifecycle. Empty content is only first-run content
    /// after a full query has completed successfully.
    @Published var timelineLoadState: TimelineLoadState = .awaitingInitialLoad
    @Published var selectedTimelineID: Int64? {
        didSet {
            guard oldValue != selectedTimelineID else { return }
            scheduleSelectedFrameExtract()
            loadOCRBoxesForSelection()
        }
    }
    /// Preview image for the selected timeline frame (still or extracted from video).
    @Published var selectedFrameImage: NSImage?
    @Published var selectedFrameExtracting = false
    @Published var selectedFramePreviewIssue: TimelinePreviewIssue?
    /// Auto-step through the loaded timeline.
    @Published var isReplaying = false
    @Published var searchQuery = ""
    /// Final Library hits after every active text, operator, time, session,
    /// application, and website constraint has been applied by the Store.
    @Published var searchResults: [FTSResult] = []
    /// Facet source constrained by text, operators, time, and session but not
    /// the optional application/website chips. This keeps alternative filters
    /// discoverable without using a post-LIMIT result set for final matches.
    @Published var searchFacetResults: [FTSResult] = []
    /// Loading and typed recovery for Library search, independent of capture,
    /// Timeline navigation, bootstrap, and the app's global status text.
    @Published var librarySearchState: LibrarySearchState = .idle
    var isSearching: Bool { librarySearchState.isLoading }
    /// True when SQLite returned a sentinel row beyond the visible page.
    /// The Library uses this to say '80+' instead of presenting a page size as
    /// an exact total.
    @Published var librarySearchResultsAreTruncated = false
    /// Optional bundle-id filter applied to the current result set (chip UI).
    @Published var searchAppFilter: String? = nil
    /// Optional domain filter for search chips (favicon chips).
    @Published var searchDomainFilter: String? = nil
    /// When true, restrict hits to the selected session time window.
    @Published var searchSessionScoped = false
    /// Optional relative-time filter: today | yesterday | lastWeek | nil.
    @Published var searchTimeFilter: SearchTimeFilter? = nil
    /// Unified by default; people can narrow a search to visible text or
    /// finalized on-device transcripts without changing their query.
    @Published var searchContent: LibrarySearchContent = .all
    /// Recent free-text queries for empty-state chips.
    @Published var recentSearchQueries: [String] = []
    /// Last parsed operator query (for chips / highlight tokens).
    @Published var lastParsedSearch: ParsedSearchQuery = ParsedSearchQuery()
    /// Show structured-search autocomplete under the search field.
    @Published var showSearchOperatorMenu = false
    /// Live autocomplete rows (operators / apps / sites / dates).
    @Published var searchAutocompleteRows: [SearchAutocompleteRow] = []
    /// Graphical calendar for `date:` / `before:` / `since:`.
    @Published var showSearchDatePicker = false
    /// The control that owns the graphical calendar's popover anchor.
    @Published var searchDatePickerOrigin: LibrarySearchDatePickerOrigin = .search
    /// Which operator the calendar will complete (`date` / `before` / `since`).
    @Published var searchDatePickerKind: SearchOperatorKind = .date
    /// Draft date for the graphical picker.
    @Published var searchDatePickerSelection: Date = Date()
    /// Terms to highlight on stage Live Text overlays after opening a hit.
    @Published var stageHighlightTokens: [String] = []
    /// App catalog for `app:` autocomplete (name + bundle id).
    @Published var searchAppCatalog: [(name: String, bundleID: String)] = []
    /// Domain catalog for `site:` autocomplete.
    @Published var searchSiteCatalog: [String] = []
    @Published var timelineNavigationOrigin: TimelineNavigationOrigin = .direct
    /// Selection, preview, and restoration anchor for the retained Library
    /// workspace. Search text and committed filters remain in their dedicated
    /// AppModel properties above.
    @Published var libraryWorkspaceNavigation = LibraryWorkspaceNavigationState()
    @Published var statusMessage = "Ready"
    var replayTask: Task<Void, Never>?
    var timelineNoticeDismissTask: Task<Void, Never>?
    /// Injectable delivery seam for VoiceOver announcements from Timeline actions.
    var timelineNoticeAnnouncementHandler: (TimelineNoticeAnnouncement) -> Void = {
        announcement in
        guard let application = NSApp else { return }
        let priority: NSAccessibilityPriorityLevel =
            switch announcement.priority {
            case .low:
                .low
            case .medium:
                .medium
            case .high:
                .high
            }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement.message,
                .priority: priority.rawValue,
            ]
        )
    }
    @Published var lastOCRReused = false
    @Published var lastAXNodes = 0
    /// Authoritative local CLI connection state shown in Integrations settings.
    @Published var cliBridgeState: CLIConnectionState = .disabled
    @Published var pausedForDisk = false
    /// Expected capture pause, published on AppModel so SwiftUI updates when
    /// the engine changes without relying on an unrelated polling redraw.
    @Published var capturePauseReason: CapturePauseReason?
    @Published var audioTranscriptionStatus: AudioTranscriptionStatus = .off
    /// User-requested pause end time (menu: 'Pause Recording for 1 Hour'). Nil when not paused.
    @Published var recordingPausedUntil: Date? = nil
    var pauseResumeTask: Task<Void, Never>?
    /// True only when a timed pause interrupted an active recording session.
    var shouldResumeAfterTimedPause = false

    // MARK: - Floating main shell

    /// True while the first-class timeline/search window is open.
    @Published var shellVisible = false
    /// When true, shell shows Search instead of Timeline.
    @Published var shellSearchMode = false
    /// One-shot signal to focus the shell search field (`/` or Open Search).
    @Published var shellFocusSearch = false
    /// Contiguous recording blocks for the sessions sidebar (pinned first).
    @Published var sessions: [SessionRow] = []
    /// Selected row in the sessions list (nil = recent window).
    @Published var selectedSessionIndex: Int?
    /// Pinned session IDs (refreshed with loadSessions).
    @Published var pinnedSessionIDs: Set<String> = []

    // MARK: - Product prefs (Settings)

    @Published var airgapMode = false {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(airgapMode, forKey: ProductPreferenceKey.airgapMode)
            FaviconCache.shared.airgapMode = airgapMode
        }
    }
    /// Explicit opt-in for sending website domains to the favicon provider.
    @Published var remoteFaviconsEnabled = false {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(
                remoteFaviconsEnabled,
                forKey: ProductPreferenceKey.remoteFaviconsEnabled
            )
            FaviconCache.shared.remoteFetchingEnabled = remoteFaviconsEnabled
        }
    }
    @Published var showDockIcon = false {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(showDockIcon, forKey: ProductPreferenceKey.showDockIcon)
            applyDockIconPreference()
        }
    }
    @Published var pauseOnInactivity = true {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(pauseOnInactivity, forKey: ProductPreferenceKey.pauseOnInactivity)
            applySettingsToEngine()
        }
    }
    @Published var captureDisplayMode: CaptureDisplayMode = .active {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(
                captureDisplayMode.rawValue,
                forKey: ProductPreferenceKey.captureDisplayMode
            )
            applySettingsToEngine()
            updateStatusMessage()
        }
    }
    @Published var appearancePreference: AppearancePreference = .system {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(appearancePreference.rawValue, forKey: ProductPreferenceKey.appearance)
            applyAppearancePreference()
        }
    }
    @Published var storageMode: StorageManagementMode = .limit {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(storageMode.rawValue, forKey: ProductPreferenceKey.storageMode)
            persistAndApplySettings()
        }
    }
    /// Snapshots pane: HEIC vs JPEG still encoding.
    @Published var stillEncoding: StillEncodingPreference = .heic {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(stillEncoding.rawValue, forKey: ProductPreferenceKey.stillEncoding)
            applySnapshotPrefsToEngine()
        }
    }
    /// Snapshots pane: comma-separated Vision language codes (empty = system).
    @Published var ocrLanguagesCSV: String = "" {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(ocrLanguagesCSV, forKey: ProductPreferenceKey.ocrLanguages)
            applySnapshotPrefsToEngine()
        }
    }
    /// Snapshots pane: differential OCR reuse when frames are similar.
    @Published var differentialOCREnabled: Bool = true {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(differentialOCREnabled, forKey: ProductPreferenceKey.differentialOCR)
            applySnapshotPrefsToEngine()
        }
    }
    @Published var audioTranscriptionEnabled = false {
        didSet {
            guard !isLoadingSettings else { return }
            persistAndApplyAudioTranscriptionSettings()
        }
    }
    @Published var computerAudioTranscriptionEnabled = true {
        didSet {
            guard !isLoadingSettings else { return }
            persistAndApplyAudioTranscriptionSettings()
        }
    }
    @Published var microphoneTranscriptionEnabled = true {
        didSet {
            guard !isLoadingSettings else { return }
            persistAndApplyAudioTranscriptionSettings()
        }
    }

    // MARK: - Appearance / timeline controls

    @Published var accentColorPreference: AccentColorPreference = .azure {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(accentColorPreference.rawValue, forKey: ProductPreferenceKey.accentColor)
        }
    }
    @Published var showOpenExternally = true {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(showOpenExternally, forKey: ProductPreferenceKey.showOpenExternally)
        }
    }
    @Published var showLiveText = true {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(showLiveText, forKey: ProductPreferenceKey.showLiveText)
        }
    }
    @Published var showZoomControls = true {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(showZoomControls, forKey: ProductPreferenceKey.showZoomControls)
        }
    }
    @Published var showSegmentNavigation = true {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(showSegmentNavigation, forKey: ProductPreferenceKey.showSegmentNavigation)
        }
    }
    @Published var excludePrivateTabs = true {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(excludePrivateTabs, forKey: ProductPreferenceKey.excludePrivateTabs)
            applySettingsToEngine()
        }
    }
    /// When enabled, supported browsers are skipped unless their active HTTP(S)
    /// website can be matched to the foreground app captured in that frame.
    @Published var pauseWhenBrowserAddressUnavailable = false {
        didSet {
            guard !isLoadingSettings else { return }
            BrowserAddressProtectionPreference.save(pauseWhenBrowserAddressUnavailable, to: preferences)
            applySettingsToEngine()
        }
    }
    /// Stage zoom (1.0 = fit).
    @Published var stageZoom: CGFloat = 1.0
    /// OCR boxes for Live Text overlay on the selected frame.
    @Published var selectedFrameOCRBoxes: [OCRBox] = []
    /// Live login-item state reported by macOS. The UI never treats a stored
    /// preference or an unapproved registration request as enabled.
    @Published var launchAtLoginState: LaunchAtLoginState = .ready(isEnabled: false)
    /// When false, CLI socket bridge is stopped (agents cannot query until re-enabled).
    @Published var cliEnabled = true {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(cliEnabled, forKey: ProductPreferenceKey.cliEnabled)
            applyCLIEnabled()
        }
    }
    /// Separate, explicit authorization for local tools to mutate capture or
    /// run Library maintenance. Missing preferences stay read-only.
    @Published var localToolCaptureControlAndMaintenanceEnabled = false {
        didSet {
            guard !isLoadingSettings else { return }
            LocalToolControlAccessPreference.save(
                localToolCaptureControlAndMaintenanceEnabled,
                to: preferences
            )
        }
    }
    /// Approximate on-disk size of the data root (bytes). Refreshed from Storage pane.
    @Published var librarySizeBytes: Int64 = 0
    /// Explicit lifecycle for disk-capacity measurement. A previous successful
    /// value remains visible while a manual refresh is in flight or fails.
    @Published var storageMeasurementState: StorageMeasurementLoadState = .idle
    /// Read-only consequence estimate for the currently configured limits.
    @Published var storageCleanupPreflightState: StorageCleanupPreflightLoadState = .idle
    @Published var storageMaintenanceState: StorageMaintenanceOperationState = .idle
    var storageMaintenanceInProgress: Bool { storageMaintenanceState.isRunning }
    /// Explicit, user-chosen Library export. The service never mutates or
    /// replaces the live Library.
    @Published var libraryExportState: LibraryExportOperationState = .idle
    @Published var libraryRestoreReview: LibraryRestoreReview?
    @Published var libraryRestoreState: LibraryRestoreOperationState = .idle
    /// Privacy-safe support bundle export from Support & About settings.
    @Published var diagnosticsExportState: DiagnosticsExportState = .idle
    /// Transient, semantic feedback from the last assistant-integration action.
    @Published var assistantIntegrationActionNotices: [AssistantIntegrationTarget: AssistantIntegrationActionNotice] = [:]
    /// Cached assistant state. Settings reads this memory-only snapshot; all
    /// filesystem and product discovery happens on a background executor.
    @Published var agentSkillSnapshotStates: [AssistantIntegrationTarget: AgentSkillSnapshotLoadState] = [:]
    @Published var assistantIntegrationWorkRegistry =
        AssistantIntegrationWorkRegistry()
    @Published var cliInstallState: CLIInstallState = .notInstalled
    /// Whether the user's login shell resolves the authenticated managed
    /// command, which is distinct from whether its files are installed.
    @Published var cliCommandAvailability: CLICommandAvailability = .unknown
    @Published var assistantLiveVerificationState: AssistantIntegrationLiveVerificationState = .notRun
    @Published var assistantLiveVerificationIsRunning = false
    @Published var assistantTestSearchOutcome: AssistantTestSearchOutcome?
    @Published var assistantTestSearchIsRunning = false
    @Published var libraryAssistantRoutingPreference: LibraryAssistantRoutingPreference = .automatic {
        didSet {
            guard !isLoadingSettings else { return }
            preferences.set(
                libraryAssistantRoutingPreference.persistedValue,
                forKey: ProductPreferenceKey.assistantHandoffRouting
            )
        }
    }
    /// One published revision keeps every menu, help label, event monitor, and
    /// Settings row synchronized with the single versioned shortcut store.
    @Published var keyboardShortcutRevision: UInt = 0
    /// Current Settings destination. Keeping this outside the view makes
    /// contextual routes work even when the Settings window is already open.
    @Published var settingsSelection: SettingsSidebarItem = .general
    /// One-shot request consumed by Settings after its retained window is
    /// frontmost. A fresh identity lets repeated routes target the same row.
    @Published private(set) var settingsNavigationRequest: SettingsNavigationRequest?
    /// One-shot request for the offline guide. The Help command should present
    /// help itself, while the Support pane keeps its ordinary Open Guide card.
    @Published private(set) var userGuidePresentationRequest: UUID?

    func requestSettingsNavigation(
        to destination: SettingsDestination,
        focusedElementIdentifier: String? = nil
    ) {
        settingsSelection = destination.section
        settingsNavigationRequest = SettingsNavigationRequest(
            destination: destination,
            focusedElementIdentifier: focusedElementIdentifier
        )
    }

    func completeSettingsNavigation(_ requestID: UUID) {
        guard settingsNavigationRequest?.id == requestID else { return }
        settingsNavigationRequest = nil
    }

    func requestUserGuidePresentation() {
        userGuidePresentationRequest = UUID()
    }

    func completeUserGuidePresentation(_ requestID: UUID) {
        guard userGuidePresentationRequest == requestID else { return }
        userGuidePresentationRequest = nil
    }

    // MARK: - Reviewed library deletion

    @Published var libraryDeletionReview: LibraryDeletionReview?
    @Published var libraryDeletionInProgress = false
    @Published var libraryDeletionIssue: LibraryDeletionIssue?
    @Published var libraryDeletionSuccess: LibraryDeletionSuccess?
    var resumeCaptureAfterLibraryDeletion = false

    // MARK: - Persisted settings

    @Published var intervalSeconds: Double = 2.0 {
        didSet { persistAndApplySettings() }
    }
    @Published var maxDimension: Int = 2_880 {
        didSet { persistAndApplySettings() }
    }
    @Published var retentionDays: Int = 30 {
        didSet { persistAndApplySettings() }
    }
    /// Soft cap on the entire managed library (MB). 0 = disabled. Default 50 000 (50 GB).
    @Published var storageCapMB: Int64 = 50_000 {
        didSet { persistAndApplySettings() }
    }
    @Published var excludedBundles: [String] = []
    /// Most recent menu-bar exclusion, retained so the next menu open offers Undo.
    @Published var recentCaptureExclusion: RecentCaptureExclusion?
    @Published var newExclusionBundle = ""
    @Published var excludedDomains: [String] = []
    @Published var newExclusionDomain = ""
    /// Domains observed in the local library, used by exclusions and search suggestions.
    @Published var recordedDomainList: [String] = []
    @Published var recordedDomainLoadState: RecordedDomainLoadState = .loading
    /// Installed and running applications available to the exclusion picker.
    /// A loaded empty catalog is intentionally distinct from a failed scan.
    @Published var applicationDiscoveryLoadState: ApplicationDiscoveryLoadState = .loading

    var quality: CaptureQuality {
        get { CaptureQuality.from(maxDimension: maxDimension) }
        set { maxDimension = newValue.maxDimension }
    }

    private(set) var store: Store?
    // Feature extensions share these dependencies through internal, module-scoped seams.
    let engine = RecordingEngine.shared
    let exclusionStore = ExclusionStore.shared
    let preferences = ScreenlogProcessPreferences.current
    let recentSearchStore = RecentSearchStore(defaults: ScreenlogProcessPreferences.current)
    let sessionPinStore = SessionPinStore(defaults: ScreenlogProcessPreferences.current)
    let keyboardShortcutStore = KeyboardShortcutStore(
        defaults: ScreenlogProcessPreferences.current
    )
    var permissionFlowCoordinator = PermissionFlowCoordinator(
        snapshot: PermissionsSnapshot(screenRecording: false, accessibility: false)
    )
    var root: URL = ScreenlogPaths.resolvedRoot()
    private var refreshTask: Task<Void, Never>?
    private var bootstrapRefreshTask: Task<Void, Never>?
    private var libraryBootstrapTask: Task<Void, Never>?
    private var capturedFrameRefreshTask: Task<Void, Never>?
    var libraryPresentationRefreshTask: Task<Void, Never>?
    private var engineCancellables: Set<AnyCancellable> = []
    private var lastObservedFrameID: Int64?
    var extractTask: Task<Void, Never>?
    var ocrBoxesTask: Task<Void, Never>?
    var prefetchTask: Task<Void, Never>?
    var searchTask: Task<Void, Never>?
    var searchDebounceTask: Task<Void, Never>?
    var librarySearchWorkers: [UInt: Task<Void, Never>] = [:]
    var librarySearchGeneration: UInt = 0
    var currentLibrarySearchGeneration: UInt?
    /// Keyset cursor for the next bounded Library page. The cursor belongs to
    /// `librarySearchGeneration` and is cleared synchronously when input changes.
    var librarySearchNextCursor: LibrarySearchCursor?
    var cliInstallTask: Task<Void, Never>?
    var cliInstallInspectionTask: Task<Void, Never>?
    var cliInstallInspectionRequestID: UUID?
    var cliPathInspectionTask: Task<Void, Never>?
    var assistantLiveVerificationTask: Task<Void, Never>?
    var assistantLiveVerificationRequestID: UUID?
    var assistantTestSearchTask: Task<Void, Never>?
    var assistantTestSearchRequestID: UUID?
    var agentSkillTasks: [AssistantIntegrationTarget: Task<Void, Never>] = [:]
    var lastAutomaticIntegrationRefreshAt: Date?
    var libraryExportTask: Task<Void, Never>?
    var libraryRestoreTask: Task<Void, Never>?
    var diagnosticsExportTask: Task<Void, Never>?
    var storageMeasurementTask: Task<Void, Never>?
    var storageMeasurementRequestID: UUID?
    var storagePreflightTask: Task<Void, Never>?
    var storagePreflightRequestID: UUID?
    var diagnosticsLog: StructuredDiagnosticsLog?
    var isLoadingSettings = false
    var settingsApplyTask: Task<Void, Never>?
    var recordedDomainLoadRequestID: UUID?
    var applicationDiscoveryLoadRequestID: UUID?
    /// Full-fidelity selected previews are large on Retina and 6K displays. The
    /// cache remains bounded while retaining enough room for the current moment
    /// and its immediate navigation neighbors.
    let previewCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 4
        c.totalCostLimit = 256 * 1024 * 1024
        return c
    }()

    // MARK: - Lifecycle

    func bootstrap() {
        // Bootstrap owns these tasks. A successful retry replaces the previous
        // generation instead of creating another refresh heartbeat.
        refreshTask?.cancel()
        refreshTask = nil
        bootstrapRefreshTask?.cancel()
        bootstrapRefreshTask = nil
        loadSettings()
        applyAppearancePreference()
        applyDockIconPreference()
        root = ScreenlogPaths.resolvedRoot()
        do {
            try ScreenlogPaths.ensureDirectories(root: root)
            // Restore activation is journaled outside the live root. Reconcile
            // it before any Store opens so SQLite can never attach to a
            // half-swapped database after an interrupted launch.
            _ = try LibraryRestoreService().recoverInterruptedRestore(at: root)
            diagnosticsLog = try? StructuredDiagnosticsLog(root: root)
            recordDiagnostic(.bootstrap, .started)
            writeBootstrapLog("bootstrap root=\(root.path)")
            let store = try Store(root: root)
            self.store = store
            libraryStartupIssue = nil
            timelineIssue = nil
            timelineLoadState = .awaitingInitialLoad
            librarySearchState = .idle
            FaviconCache.shared.reconfigure(
                cacheDirectory: root.appendingPathComponent("favicon-cache", isDirectory: true)
            )
            FaviconCache.shared.airgapMode = airgapMode
            FaviconCache.shared.remoteFetchingEnabled = remoteFaviconsEnabled
            engine.configure(store: store, dataRoot: root, exclusions: exclusionStore)
            applySettingsToEngine()
            bindEngineState()
            writeBootstrapLog("store open ok")
            recordDiagnostic(.localStore, .succeeded)

            // CLI bridge: Unix domain socket at <root>/cli.sock (app owns SQLite).
            applyCLIEnabled()
            if ProcessInfo.processInfo.environment["SCREENLOG_XPC_MACH"] == "1" {
                do {
                    try ScreenlogXPCHost.shared.start(
                        store: store,
                        root: root,
                        engine: RecordingEngineBox()
                    )
                    writeBootstrapLog("mach XPC start ok")
                } catch {
                    writeBootstrapLog("mach XPC start FAILED: \(error)")
                }
            }

            bootstrapRefreshTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshPermissions()
                guard !Task.isCancelled else { return }
                let timedPauseRestored = self.restoreTimedPauseAfterLibraryReopen()
                if self.captureIntent == true, !timedPauseRestored {
                    self.startCapture(persistIntent: false)
                }
                await self.refreshData()
                guard !Task.isCancelled else { return }
                // Never auto-show floating windows - onboarding lives in the popover.
                self.updateStatusMessage()
                self.recordDiagnostic(.bootstrap, .succeeded)
            }
            refreshTask = Task {
                var tick = 0
                while !Task.isCancelled {
                    // Permission/status is intentionally a lightweight heartbeat.
                    // Library mutations arrive through RecordingEngine publishers,
                    // so Timeline and session queries do not redraw on a timer.
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    tick += 1
                    #if DEBUG
                        if let fixturePermissions = AppUITestFixture.permissionsSnapshot {
                            permissions = fixturePermissions
                            reconcileMicrophoneAuthorization(
                                AppUITestFixture.microphoneAuthorization
                            )
                        } else {
                            permissions = PermissionsSnapshot.currentFast()
                            reconcileMicrophoneAuthorization(MicrophoneAuthorization.current)
                        }
                    #else
                        permissions = PermissionsSnapshot.currentFast()
                        reconcileMicrophoneAuthorization(MicrophoneAuthorization.current)
                    #endif
                    synchronizePermissionJourney(with: permissions)
                    // Slow reconciliation covers maintenance or out-of-process
                    // mutations without making broad polling the primary update path.
                    if tick % 12 == 0 {
                        await refreshData(light: true)
                    }
                    synchronizeCLIBridgeStateFromHost()
                    reconcileTimedPausePreference()
                    updateStatusMessage()
                }
            }
        } catch {
            store = nil
            timelineLoadState = .failed
            libraryStartupIssue = LibraryStartupIssue(error: error)
            statusMessage = libraryStartupIssue?.statusTitle ?? "Library Unavailable"
            writeBootstrapLog("bootstrap FAILED: \(error)")
            recordDiagnostic(.bootstrap, .failed)
        }
    }

    func retryLibraryBootstrap() {
        guard store == nil, libraryStartupIssue != nil, !libraryBootstrapRetrying else { return }
        libraryBootstrapRetrying = true
        updateStatusMessage()
        libraryBootstrapTask?.cancel()
        libraryBootstrapTask = Task { @MainActor [weak self] in
            // Publish the busy state before quick_check performs synchronous
            // local I/O on the main actor.
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            defer {
                self.libraryBootstrapRetrying = false
                self.libraryBootstrapTask = nil
                self.updateStatusMessage()
            }
            self.bootstrap()
        }
    }

    var canRevealLibrary: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    var canRevealLibraryDiagnostics: Bool {
        FileManager.default.fileExists(atPath: libraryDiagnosticsURL.path)
    }

    func revealLibrary() {
        guard canRevealLibrary else { return }
        NSWorkspace.shared.open(root)
    }

    func revealLibraryDiagnostics() {
        guard canRevealLibraryDiagnostics else {
            revealLibrary()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([libraryDiagnosticsURL])
    }

    private var libraryDiagnosticsURL: URL {
        root.appendingPathComponent("bootstrap.log", isDirectory: false)
    }

    func updateStatusMessage() {
        if libraryBootstrapRetrying {
            statusMessage = "Retrying Library"
        } else if let libraryStartupIssue {
            statusMessage = libraryStartupIssue.statusTitle
        } else if let until = recordingPausedUntil, until > Date() {
            statusMessage = "Paused until \(Self.shortTimeFormatter.string(from: until))"
        } else if let capturePauseReason {
            statusMessage = capturePauseReason.statusTitle
        } else if let captureIssue {
            statusMessage = captureIssue.title
        } else if isRecording {
            statusMessage = captureRunningStatusMessage
        } else if !permissions.isCaptureReady {
            statusMessage = "Finish Permissions setup to continue"
        } else {
            statusMessage = "Ready - capture off"
        }
    }

    /// Durable diagnostics under data root (used when OSLog is hard to capture headless).
    func writeBootstrapLog(_ line: String) {
        let url = root.appendingPathComponent("bootstrap.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(line)\n"
        if let data = text.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
                let handle = try? FileHandle(forWritingTo: url)
            {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Records only allowlisted event/outcome pairs. This deliberately has no
    /// message parameter so private content cannot enter exportable diagnostics.
    func recordDiagnostic(
        _ event: DiagnosticsLogEntry.Event,
        _ outcome: DiagnosticsLogEntry.Outcome
    ) {
        diagnosticsLog?.record(DiagnosticsLogEntry(event: event, outcome: outcome))
    }

    /// Drain every task that can still touch Store, then deterministically close
    /// SQLite. The restore service's filesystem swap may only start after this
    /// method returns.
    func quiesceForLibraryRestore() async throws {
        stopReplay()
        // A one-shot capture runs directly on the pipeline rather than the
        // recording loop. Let an already-started write finish, while the
        // restoring state prevents another one from entering.
        while captureOnceState == .inProgress {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let tasks =
            [
                refreshTask,
                bootstrapRefreshTask,
                libraryBootstrapTask,
                capturedFrameRefreshTask,
                libraryPresentationRefreshTask,
                settingsApplyTask,
                extractTask,
                ocrBoxesTask,
                prefetchTask,
                searchDebounceTask,
                pauseResumeTask,
                storageMeasurementTask,
                storagePreflightTask,
            ].compactMap { $0 } + Array(librarySearchWorkers.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { _ = await task.result }
        refreshTask = nil
        bootstrapRefreshTask = nil
        libraryBootstrapTask = nil
        capturedFrameRefreshTask = nil
        libraryPresentationRefreshTask = nil
        settingsApplyTask = nil
        extractTask = nil
        ocrBoxesTask = nil
        prefetchTask = nil
        searchTask = nil
        searchDebounceTask = nil
        librarySearchWorkers.removeAll()
        currentLibrarySearchGeneration = nil
        pauseResumeTask = nil
        storageMeasurementTask = nil
        storageMeasurementRequestID = nil
        storagePreflightTask = nil
        storagePreflightRequestID = nil

        await ScreenlogSocketHost.shared.stopAndDrain()
        await ScreenlogXPCHost.shared.stopAndDrain()
        await engine.quiesceForLibraryReplacement()
        guard let currentStore = store else {
            throw LibraryRestoreError.liveLibraryUnavailable
        }
        try currentStore.withSerializedMutation {
            try currentStore.db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
            try currentStore.db.close()
        }
        store = nil
        previewCache.removeAllObjects()
        selectedFrameImage = nil
        selectedFrameOCRBoxes = []
    }

    func shutdown() {
        engine.stop()
        ScreenlogSocketHost.shared.stop()
        ScreenlogXPCHost.shared.stop()
        refreshTask?.cancel()
        bootstrapRefreshTask?.cancel()
        bootstrapRefreshTask = nil
        libraryBootstrapTask?.cancel()
        libraryBootstrapTask = nil
        libraryBootstrapRetrying = false
        capturedFrameRefreshTask?.cancel()
        capturedFrameRefreshTask = nil
        libraryPresentationRefreshTask?.cancel()
        libraryPresentationRefreshTask = nil
        engineCancellables.removeAll()
        settingsApplyTask?.cancel()
        extractTask?.cancel()
        ocrBoxesTask?.cancel()
        ocrBoxesTask = nil
        prefetchTask?.cancel()
        searchTask?.cancel()
        searchDebounceTask?.cancel()
        librarySearchWorkers.values.forEach { $0.cancel() }
        librarySearchWorkers.removeAll()
        currentLibrarySearchGeneration = nil
        timelineNoticeDismissTask?.cancel()
        timelineNoticeDismissTask = nil
        timelineNotice = nil
        cliInstallTask?.cancel()
        cliInstallInspectionTask?.cancel()
        cliInstallInspectionTask = nil
        cliInstallInspectionRequestID = nil
        cliPathInspectionTask?.cancel()
        cliPathInspectionTask = nil
        assistantLiveVerificationTask?.cancel()
        assistantLiveVerificationTask = nil
        assistantLiveVerificationRequestID = nil
        assistantLiveVerificationIsRunning = false
        assistantTestSearchTask?.cancel()
        assistantTestSearchTask = nil
        assistantTestSearchRequestID = nil
        assistantTestSearchIsRunning = false
        assistantTestSearchOutcome = nil
        agentSkillTasks.values.forEach { $0.cancel() }
        agentSkillTasks.removeAll()
        assistantIntegrationWorkRegistry = AssistantIntegrationWorkRegistry()
        libraryExportTask?.cancel()
        libraryExportTask = nil
        libraryRestoreTask?.cancel()
        libraryRestoreTask = nil
        diagnosticsExportTask?.cancel()
        diagnosticsExportTask = nil
        storageMeasurementTask?.cancel()
        storageMeasurementTask = nil
        storageMeasurementRequestID = nil
        storagePreflightTask?.cancel()
        storagePreflightTask = nil
        storagePreflightRequestID = nil
        pauseResumeTask?.cancel()
        pauseResumeTask = nil
        recordingPausedUntil = nil
        shouldResumeAfterTimedPause = false
        stopReplay()
        hidePermissions()
        MainShellController.shared.hide()
        SearchWindowController.shared.hide()
        SettingsWindowController.shared.hide()
    }

    /// Bind UI state to the recording engine once during bootstrap. Individual
    /// publishers keep status surfaces current immediately; only a saved frame
    /// schedules a database-backed Library refresh.
    private func bindEngineState() {
        engineCancellables.removeAll()

        engine.$isRecording
            .removeDuplicates()
            .sink { [weak self] value in
                Task { @MainActor [weak self] in
                    self?.isRecording = value
                    self?.updateStatusMessage()
                }
            }
            .store(in: &engineCancellables)

        engine.$pauseReason
            .removeDuplicates()
            .sink { [weak self] value in
                Task { @MainActor [weak self] in
                    self?.capturePauseReason = value
                    self?.updateStatusMessage()
                }
            }
            .store(in: &engineCancellables)

        engine.$audioTranscriptionStatus
            .removeDuplicates()
            .sink { [weak self] value in
                Task { @MainActor [weak self] in
                    self?.audioTranscriptionStatus = value
                }
            }
            .store(in: &engineCancellables)

        engine.$pausedForDisk
            .removeDuplicates()
            .sink { [weak self] value in
                Task { @MainActor [weak self] in self?.pausedForDisk = value }
            }
            .store(in: &engineCancellables)

        engine.$lastOCRReused
            .removeDuplicates()
            .sink { [weak self] value in
                Task { @MainActor [weak self] in self?.lastOCRReused = value }
            }
            .store(in: &engineCancellables)

        engine.$lastAXNodes
            .removeDuplicates()
            .sink { [weak self] value in
                Task { @MainActor [weak self] in self?.lastAXNodes = value }
            }
            .store(in: &engineCancellables)

        engine.$lastError
            .removeDuplicates()
            .sink { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if value != nil, self.engine.isRecording {
                        self.captureIssue = .automaticCaptureFailed
                    } else if self.captureIssue == .automaticCaptureFailed {
                        self.captureIssue = nil
                    }
                    self.updateStatusMessage()
                }
            }
            .store(in: &engineCancellables)

        engine.$lastFrameID
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] frameID in
                Task { @MainActor [weak self] in
                    self?.scheduleCapturedFrameRefresh(frameID: frameID)
                }
            }
            .store(in: &engineCancellables)
    }

    private func scheduleCapturedFrameRefresh(frameID: Int64) {
        var firstRunProgress = firstRunValueProgress
        if firstRunProgress.observeDurableFrame(frameID) {
            firstRunValueProgress = firstRunProgress
        }
        guard frameID != lastObservedFrameID else { return }
        lastObservedFrameID = frameID
        capturedFrameRefreshTask?.cancel()
        capturedFrameRefreshTask = Task { @MainActor [weak self] in
            // Coalesce the published frame and companion stats updates from one
            // capture cycle before querying the store.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshAfterCapturedFrame()
        }
    }

}
