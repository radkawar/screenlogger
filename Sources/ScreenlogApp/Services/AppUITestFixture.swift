import AppKit
import Foundation
import ScreenlogCore

#if DEBUG
    /// Deterministic, fail-closed state used only by the routed UI regression suite.
    ///
    /// The fixture is installed from a routed window before bootstrap. This lets UI
    /// tests exercise capture affordances and local search without touching
    /// ScreenCaptureKit, TCC, or an existing Screenlogger library.
    @MainActor
    enum AppUITestFixture {
        enum LoginItemSimulation: Equatable {
            case registrationFailure
            case approvalRequired
        }

        private enum SnapshotSurface: String {
            case visible
            case library
            case timeline
            case setup
            case settings

            var windowTitle: String? {
                switch self {
                case .visible: return nil
                case .library: return "Library"
                case .timeline: return "Timeline"
                case .setup: return "Permissions & Privacy"
                case .settings: return "Settings"
                }
            }
        }

        private struct Configuration {
            let root: URL
            let captureIssue: CaptureIssue?
            let failsLibrarySearch: Bool
            let usesUnreadablePreview: Bool
            let loginItemSimulation: LoginItemSimulation?
            let applicationDiscoveryIssue: ApplicationDiscoveryError?
            let permissions: PermissionsSnapshot
            let microphoneAuthorization: MicrophoneAuthorization
            let seedsHistory: Bool
            let grantsPermissionAfterOpeningSettings: Bool
            let grantsPermissionsSequentially: Bool
            let selectsSessionAfterLoad: Bool
            let capturesContentSnapshot: Bool
            let appearance: String?
            let accent: AccentColorPreference?
            let increasedContrast: Bool
            let snapshotSurface: SnapshotSurface
            let settingsDestination: SettingsSidebarItem?
            let snapshotsAtMinimumWindowSize: Bool
            let assistantScenario: AssistantScenario
            let firstRunFrameDelayMilliseconds: UInt64?
            let seedsMultipleDisplays: Bool
            let seedsLongSession: Bool
            let compactsSeedHistory: Bool
            let presentsAudioTranscription: Bool
            let audioTranscriptionPhase: AudioTranscriptionPhase?
        }

        /// Assistant discovery and readiness are explicit fixture inputs. The
        /// default is intentionally empty so a routed test can never inherit
        /// an assistant, skill, command, or preference from the signed-in Mac.
        private struct AssistantScenario {
            let detected: Set<AssistantIntegrationTarget>
            let ready: Set<AssistantIntegrationTarget>
            let routingPreference: LibraryAssistantRoutingPreference

            static func parse(environment: [String: String]) -> AssistantScenario {
                let declaredDetected = targets(
                    from: environment["SCREENLOG_UI_TEST_DETECTED_ASSISTANTS"]
                )
                let ready = targets(
                    from: environment["SCREENLOG_UI_TEST_READY_ASSISTANTS"]
                )
                return AssistantScenario(
                    detected: declaredDetected.union(ready),
                    ready: ready,
                    routingPreference: LibraryAssistantRoutingPreference(
                        persistedValue:
                            environment["SCREENLOG_UI_TEST_ASSISTANT_ROUTING"] ?? "automatic"
                    )
                )
            }

            private static func targets(
                from value: String?
            ) -> Set<AssistantIntegrationTarget> {
                guard let value, !value.isEmpty else { return [] }
                let fields = value.split(separator: ",", omittingEmptySubsequences: false)
                let parsed = fields.compactMap { field in
                    AssistantIntegrationTarget(rawValue: String(field))
                }
                // Reject the whole declaration on malformed input. Partial
                // discovery would make a typo look like a valid UI scenario.
                guard parsed.count == fields.count else { return [] }
                return Set(parsed)
            }
        }

        private struct AssistantFixtureContext {
            let root: URL
            let scenario: AssistantScenario
        }

        private struct SeedMoment {
            let offsetMs: Int64
            let foreground: String
            let title: String
            let bundleID: String
            let displayName: String
            let domain: String?
            let url: String?
            let accent: NSColor
        }

        private static let fixtureName = "deterministic-navigation-v1"
        private static var installingModels: Set<ObjectIdentifier> = []
        private static var permissionsOverride: PermissionsSnapshot?

        /// Whether this process passed every routed-test isolation boundary.
        /// Window controllers use this to skip the one-time legacy AppKit frame
        /// migration, which reads the product's standard defaults domain.
        static let isAuthenticatedRoutedTest: Bool = {
            let process = ProcessInfo.processInfo
            return ScreenlogProcessPreferences.routedUITestSuiteName(
                environment: process.environment,
                arguments: process.arguments,
                temporaryDirectory: FileManager.default.temporaryDirectory
            ) != nil
        }()

        private static let configuration: Configuration? = {
            let process = ProcessInfo.processInfo
            let environment = process.environment
            guard environment["SCREENLOG_UI_TEST_FIXTURE"] == fixtureName,
                let rootPath = environment["SCREENLOG_DATA_DIR"],
                let preferencesSuite = environment["SCREENLOG_UI_TEST_PREFERENCES_SUITE"]
            else { return nil }

            let arguments = process.arguments
            guard
                ScreenlogProcessPreferences.routedUITestSuiteName(
                    environment: environment,
                    arguments: arguments,
                    temporaryDirectory: FileManager.default.temporaryDirectory
                ) == preferencesSuite
            else { return nil }

            let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
            let captureIssue: CaptureIssue? =
                environment["SCREENLOG_UI_TEST_CAPTURE_ISSUE"] == "start-failed"
                ? .startFailed
                : nil
            let loginItemSimulation: LoginItemSimulation? =
                switch environment["SCREENLOG_UI_TEST_LOGIN_ITEM_ISSUE"] {
                case "registration-failed": .registrationFailure
                case "approval-required": .approvalRequired
                default: nil
                }
            let permissions =
                switch environment["SCREENLOG_UI_TEST_PERMISSION_ISSUE"] {
                case "screen-recording-denied":
                    PermissionsSnapshot(screenRecording: false, accessibility: false)
                case "accessibility-denied":
                    PermissionsSnapshot(screenRecording: true, accessibility: false)
                default:
                    PermissionsSnapshot(screenRecording: true, accessibility: true)
                }
            let microphoneAuthorization =
                MicrophoneAuthorization(
                    rawValue: environment["SCREENLOG_UI_TEST_MICROPHONE_PERMISSION"]
                        ?? "notDetermined"
                ) ?? .notDetermined
            return Configuration(
                root: root,
                captureIssue: captureIssue,
                failsLibrarySearch: environment["SCREENLOG_UI_TEST_SEARCH_ISSUE"] == "query-failed",
                usesUnreadablePreview:
                    environment["SCREENLOG_UI_TEST_PREVIEW_ISSUE"] == "media-unreadable",
                loginItemSimulation: loginItemSimulation,
                applicationDiscoveryIssue:
                    environment["SCREENLOG_UI_TEST_APPLICATION_DISCOVERY_ISSUE"] == "catalog-unavailable"
                    ? .catalogUnavailable
                    : nil,
                permissions: permissions,
                microphoneAuthorization: microphoneAuthorization,
                seedsHistory: permissions.isCaptureReady
                    || environment["SCREENLOG_UI_TEST_SEED_HISTORY_WITHOUT_PERMISSION"] == "1",
                grantsPermissionAfterOpeningSettings:
                    environment["SCREENLOG_UI_TEST_GRANT_PERMISSION_AFTER_OPENING_SETTINGS"] == "1",
                grantsPermissionsSequentially:
                    environment["SCREENLOG_UI_TEST_GRANT_PERMISSION_AFTER_OPENING_SETTINGS"]
                    == "sequential",
                selectsSessionAfterLoad:
                    environment["SCREENLOG_UI_TEST_SELECT_SESSION_AFTER_LOAD"] == "1",
                capturesContentSnapshot: environment["SCREENLOG_UI_TEST_SNAPSHOT"] == "content",
                appearance: environment["SCREENLOG_UI_TEST_APPEARANCE"],
                accent: environment["SCREENLOG_UI_TEST_ACCENT"].flatMap {
                    AccentColorPreference(rawValue: $0)
                },
                increasedContrast:
                    environment["SCREENLOG_UI_TEST_INCREASED_CONTRAST"] == "1",
                snapshotSurface: SnapshotSurface(
                    rawValue: environment["SCREENLOG_UI_TEST_SNAPSHOT_SURFACE"] ?? "visible"
                ) ?? .visible,
                settingsDestination: SettingsSidebarItem(
                    rawValue: environment["SCREENLOG_UI_TEST_SETTINGS_DESTINATION"] ?? ""
                ),
                snapshotsAtMinimumWindowSize:
                    environment["SCREENLOG_UI_TEST_SNAPSHOT_WINDOW_SIZE"] == "minimum",
                assistantScenario: AssistantScenario.parse(environment: environment),
                firstRunFrameDelayMilliseconds: environment[
                    "SCREENLOG_UI_TEST_FIRST_RUN_FRAME_DELAY_MS"
                ].flatMap(UInt64.init),
                seedsMultipleDisplays: environment[
                    "SCREENLOG_UI_TEST_MULTIPLE_DISPLAYS"
                ] == "1",
                seedsLongSession: environment[
                    "SCREENLOG_UI_TEST_LONG_SESSION"
                ] == "1",
                compactsSeedHistory: environment[
                    "SCREENLOG_UI_TEST_COMPACT_HISTORY"
                ] == "1",
                presentsAudioTranscription: environment[
                    "SCREENLOG_UI_TEST_AUDIO_TRANSCRIPTION"
                ] != nil,
                audioTranscriptionPhase: environment[
                    "SCREENLOG_UI_TEST_AUDIO_TRANSCRIPTION"
                ].flatMap(AudioTranscriptionPhase.init(rawValue:))
            )
        }()

        private static var assistantFixtureContext: AssistantFixtureContext? {
            guard let configuration else { return nil }
            return AssistantFixtureContext(
                root: configuration.root,
                scenario: configuration.assistantScenario
            )
        }

        static var permissionsSnapshot: PermissionsSnapshot? {
            permissionsOverride ?? configuration?.permissions
        }

        static var microphoneAuthorization: MicrophoneAuthorization {
            configuration?.microphoneAuthorization ?? .notDetermined
        }

        static func presentedRecordingState(or liveValue: Bool) -> Bool {
            configuration?.presentsAudioTranscription == true ? true : liveValue
        }

        static func presentedAudioTranscriptionStatus(
            or liveValue: AudioTranscriptionStatus
        ) -> AudioTranscriptionStatus {
            guard let configuration, configuration.presentsAudioTranscription else {
                return liveValue
            }
            let phase = configuration.audioTranscriptionPhase ?? .active
            return AudioTranscriptionStatus(
                phase: phase,
                activeSources: phase == .active ? Set(TranscriptSource.allCases) : [],
                detail: audioTranscriptionDetail(phase: phase)
            )
        }

        static var shouldFailLibrarySearch: Bool {
            configuration?.failsLibrarySearch == true
        }

        static var launchAtLoginSimulation: LoginItemSimulation? {
            configuration?.loginItemSimulation
        }

        static var applicationDiscoveryIssue: ApplicationDiscoveryError? {
            configuration?.applicationDiscoveryIssue
        }

        /// A small, stable catalog for visual and interaction tests. Routed
        /// fixtures must not make screenshots or assertions depend on which
        /// applications happen to be installed on the developer Mac or CI
        /// host.
        static var discoveredApplications: [DiscoveredApplication]? {
            guard configuration != nil else { return nil }
            return [
                DiscoveredApplication(bundleID: "com.apple.iCal", name: "Calendar"),
                DiscoveredApplication(bundleID: "com.apple.mail", name: "Mail"),
                DiscoveredApplication(bundleID: "com.apple.Notes", name: "Notes"),
                DiscoveredApplication(bundleID: "com.apple.Safari", name: "Safari"),
                DiscoveredApplication(bundleID: "com.apple.TextEdit", name: "TextEdit"),
            ]
        }

        /// Returns the handoff destinations declared by the authenticated UI
        /// fixture, or `nil` outside a routed UI test.
        ///
        /// A routed window is intentionally shown before the app bootstraps its
        /// Store and socket bridge. Those production lifecycle steps may update
        /// the model's aggregate connection state after the fixture is first
        /// installed. The handoff sheet is testing routing and presentation,
        /// not a live socket, so read its declared destinations directly from
        /// this immutable boundary instead of racing bootstrap side effects.
        static func assistantHandoffDestinationsIfRequested()
            -> [AssistantHandoffDestination]?
        {
            guard let context = assistantFixtureContext else { return nil }
            let fixtureRoot = assistantFixtureRoot(for: context.root)
            return AssistantIntegrationTarget.allCases.compactMap { target in
                guard context.scenario.ready.contains(target) else {
                    return nil
                }
                return AssistantHandoffLaunchService.destination(
                    for: target,
                    presence: assistantPresence(
                        for: target,
                        detected: true,
                        fixtureRoot: fixtureRoot
                    )
                )
            }
        }

        /// Routed UI tests must not inspect assistant installations or shell
        /// commands from the signed-in account. Foundation's account home is
        /// not guaranteed to follow `CFFIXED_USER_HOME`, so publish an explicit
        /// synthetic snapshot rooted inside the authenticated temporary fixture.
        static func installIsolatedAssistantStateIfRequested(on model: AppModel) -> Bool {
            guard let context = assistantFixtureContext else { return false }

            model.cliInstallInspectionTask?.cancel()
            model.cliInstallInspectionTask = nil
            model.cliInstallInspectionRequestID = nil
            model.cliPathInspectionTask?.cancel()
            model.cliPathInspectionTask = nil
            model.agentSkillTasks.values.forEach { $0.cancel() }
            model.agentSkillTasks.removeAll()
            model.assistantIntegrationWorkRegistry = AssistantIntegrationWorkRegistry()
            model.assistantIntegrationActionNotices.removeAll()
            let scenario = context.scenario

            let expectedCommand = context.root.appendingPathComponent(
                "home/.local/bin/screenlog",
                isDirectory: false
            )
            if scenario.ready.isEmpty {
                model.cliInstallState = .notInstalled
                model.cliCommandAvailability = .notChecked(
                    expectedPath: expectedCommand.path,
                    setup: nil
                )
                model.cliBridgeState = .disabled
                model.assistantLiveVerificationState = .notRun
            } else {
                model.cliInstallState = .ready(path: expectedCommand.path)
                model.cliCommandAvailability = .available(path: expectedCommand.path)
                model.cliBridgeState = .available(
                    socketPath: context.root.appendingPathComponent(
                        "runtime/screenlog.sock",
                        isDirectory: false
                    ).path
                )
                model.assistantLiveVerificationState = .succeeded
            }
            model.assistantLiveVerificationIsRunning = false
            model.libraryAssistantRoutingPreference = scenario.routingPreference

            let fixtureRoot = assistantFixtureRoot(for: context.root)
            model.agentSkillSnapshotStates = Dictionary(
                uniqueKeysWithValues: AssistantIntegrationTarget.allCases.map { target in
                    let destination = fixtureRoot.appendingPathComponent(
                        target.rawValue,
                        isDirectory: true
                    )
                    let isReady = scenario.ready.contains(target)
                    let isDetected = scenario.detected.contains(target)
                    let inspection = AssistantIntegrationInspection(
                        target: target,
                        destination: destination,
                        state: isReady ? .currentCopy : .missing,
                        isRegistered: target == .openclaw ? isReady : nil
                    )
                    let snapshot = AgentSkillSnapshot(
                        inspection: inspection,
                        inspectionIssue: nil,
                        presence: assistantPresence(
                            for: target,
                            detected: isDetected,
                            fixtureRoot: fixtureRoot
                        ),
                        destinationParentExists: isDetected
                    )
                    return (target, AgentSkillSnapshotLoadState.loaded(snapshot))
                }
            )
            return true
        }

        private static func assistantFixtureRoot(
            for root: URL
        ) -> URL {
            root.appendingPathComponent(
                "assistant-integrations",
                isDirectory: true
            )
        }

        private static func assistantPresence(
            for target: AssistantIntegrationTarget,
            detected: Bool,
            fixtureRoot: URL
        ) -> AssistantHostDiscovery.Result {
            guard detected else {
                return AssistantHostDiscovery.Result(appURL: nil, cliURL: nil)
            }
            let executableName = target == .cursor ? "cursor-agent" : target.rawValue
            return AssistantHostDiscovery.Result(
                appURL: nil,
                cliURL: fixtureRoot.appendingPathComponent(
                    "hosts/\(target.rawValue)/bin/\(executableName)",
                    isDirectory: false
                )
            )
        }

        static func installIfRequested(on model: AppModel) {
            guard let configuration, let permissionsSnapshot else { return }

            // Native windows may be created after the fixture model was
            // installed. Reapply window-only presentation overrides on each
            // route without resetting mutable fixture state such as capture.
            applyPresentationOverridesIfRequested(on: model)

            let identifier = ObjectIdentifier(model)
            guard installingModels.insert(identifier).inserted else { return }

            model.permissions = permissionsSnapshot
            model.permissionFlowCoordinator = PermissionFlowCoordinator(
                snapshot: permissionsSnapshot,
                requestClient: PermissionRequestClient(
                    status: { permission in
                        guard let snapshot = AppUITestFixture.permissionsSnapshot else {
                            return false
                        }
                        return permission == .screenRecording
                            ? snapshot.screenRecording
                            : snapshot.accessibility
                    },
                    request: { _ in false }
                ),
                settingsOpener: PermissionSystemSettingsOpener(openURL: { _ in true })
            )
            model.permissionJourney = model.permissionFlowCoordinator.journey
            model.capturePauseReason = nil
            model.isRecording = configuration.presentsAudioTranscription
            model.statusMessage =
                configuration.presentsAudioTranscription
                ? "Capturing every 2s"
                : "Ready - capture off"
            model.captureIssue = configuration.captureIssue
            // Fixture readiness must not depend on a particular view reaching
            // `onAppear`. Install the declared assistant scenario with the
            // rest of the isolated model state so Library, Settings, and
            // screenshot routes all observe the same deterministic boundary.
            _ = installIsolatedAssistantStateIfRequested(on: model)

            Task { @MainActor [weak model] in
                guard let model else { return }
                do {
                    let store = try await waitForStore(on: model)
                    if configuration.seedsHistory {
                        try seedHistory(
                            in: store,
                            usesUnreadablePreview: configuration.usesUnreadablePreview,
                            includesMultipleDisplays: configuration.seedsMultipleDisplays,
                            includesLongSession: configuration.seedsLongSession
                        )
                        if configuration.compactsSeedHistory {
                            let compactor = VideoCompactionService()
                            compactor.minBatchSize = 2
                            compactor.minRunSize = 2
                            // The visual fixture intentionally spans more than
                            // a day. Treat it as one synthetic run without
                            // weakening production's 60-second compaction gap.
                            compactor.maxGapMs = .max
                            guard try await compactor.compact(store: store) > 0 else {
                                throw FixtureError.compactionFailed
                            }
                        }
                        if configuration.presentsAudioTranscription {
                            try seedAudioTranscript(in: store)
                        }
                    }
                    await model.refreshData(light: false)
                    await model.loadSessions()
                    if configuration.selectsSessionAfterLoad {
                        model.selectedSessionIndex = model.sessions.indices.first
                        // The fixture represents an explicit "all sessions"
                        // choice made after selecting Timeline context.
                        model.searchSessionScoped = false
                    }
                    await model.refreshRecordedDomains()
                    if configuration.capturesContentSnapshot {
                        if configuration.snapshotSurface == .settings {
                            if let destination = configuration.settingsDestination {
                                model.settingsSelection = destination
                            }
                            model.openProductSettings()
                        }
                        try await prepareContentSnapshot(
                            on: model,
                            surface: configuration.snapshotSurface
                        )
                        try await writeContentSnapshot(
                            in: configuration.root,
                            surface: configuration.snapshotSurface
                        )
                    }
                    try Data("ready\n".utf8).write(
                        to: configuration.root.appendingPathComponent("ui-fixture-ready"),
                        options: .atomic
                    )
                } catch {
                    let message = "\(error)\n"
                    try? Data(message.utf8).write(
                        to: configuration.root.appendingPathComponent("ui-fixture-error"),
                        options: .atomic
                    )
                }
            }
        }

        static func applyPresentationOverridesIfRequested(on model: AppModel) {
            guard let configuration else { return }

            model.microphoneAuthorization = configuration.microphoneAuthorization

            switch configuration.appearance {
            case "light": model.appearancePreference = .light
            case "dark": model.appearancePreference = .dark
            default: break
            }
            if let accent = configuration.accent {
                model.accentColorPreference = accent
            }
            if configuration.presentsAudioTranscription {
                model.isLoadingSettings = true
                model.audioTranscriptionEnabled = true
                model.computerAudioTranscriptionEnabled = true
                model.microphoneTranscriptionEnabled = true
                model.isLoadingSettings = false
                model.audioTranscriptionStatus = presentedAudioTranscriptionStatus(
                    or: model.audioTranscriptionStatus
                )
            }
            model.applyAppearancePreference()

            guard configuration.increasedContrast else { return }
            NSApp.appearance = NSAppearance(
                named: configuration.appearance == "dark"
                    ? .accessibilityHighContrastDarkAqua
                    : .accessibilityHighContrastAqua
            )
        }

        private static func audioTranscriptionDetail(
            phase: AudioTranscriptionPhase
        ) -> String {
            switch phase {
            case .active:
                return "Transcribing microphone and computer audio on this Mac."
            case .recovering:
                return "Display awake. Reconnecting audio transcription..."
            case .failed:
                return "Audio transcription couldn't reconnect automatically. Choose Try Again."
            case .permissionRequired:
                return "Allow Microphone access to transcribe your voice."
            case .capturePaused:
                return "The display is off. Audio transcription will resume automatically when it wakes."
            case .preparing:
                return "Preparing Apple's on-device speech model..."
            case .privacyPaused:
                return "Transcription is paused for protected activity."
            case .unavailable:
                return AudioTranscriptionSupport.requirementDescription
            case .off:
                return "Audio transcription is off."
            }
        }

        static func startCaptureIfRequested(on model: AppModel) -> Bool {
            guard configuration != nil, permissionsSnapshot?.isCaptureReady == true else {
                return false
            }
            model.permissions =
                permissionsSnapshot
                ?? PermissionsSnapshot(screenRecording: true, accessibility: true)
            model.capturePauseReason = nil
            model.isRecording = true
            let seconds =
                model.intervalSeconds == floor(model.intervalSeconds)
                ? "\(Int(model.intervalSeconds))"
                : String(format: "%.1f", model.intervalSeconds)
            model.statusMessage = "Capturing every \(seconds)s"
            if let delay = configuration?.firstRunFrameDelayMilliseconds {
                Task { @MainActor [weak model] in
                    try? await Task.sleep(nanoseconds: delay * 1_000_000)
                    guard let model, !Task.isCancelled else { return }
                    var progress = model.firstRunValueProgress
                    if progress.observeDurableFrame(Int64.max) {
                        model.firstRunValueProgress = progress
                    }
                }
            }
            return true
        }

        /// Simulate returning from System Settings with Screen Recording
        /// allowed. This is gated by the isolated routed UI fixture and keeps
        /// the successful Setup path testable without reading or mutating TCC.
        @discardableResult
        static func simulateSetupPermissionGrantIfRequested(on model: AppModel) -> Bool {
            guard let configuration,
                configuration.grantsPermissionAfterOpeningSettings
                    || configuration.grantsPermissionsSequentially
            else {
                return false
            }
            let current =
                permissionsSnapshot
                ?? PermissionsSnapshot(screenRecording: false, accessibility: false)
            let granted =
                configuration.grantsPermissionsSequentially && !current.screenRecording
                ? PermissionsSnapshot(screenRecording: true, accessibility: false)
                : PermissionsSnapshot(screenRecording: true, accessibility: true)
            // Model the external System Settings round trip after the button
            // action has completed so the rendered Setup view observes a real
            // denied-to-allowed transition.
            DispatchQueue.main.async {
                permissionsOverride = granted
                model.permissions = granted
                model.permissionFlowCoordinator.refresh(with: granted)
                model.permissionJourney = model.permissionFlowCoordinator.journey
            }
            return true
        }

        private static func waitForStore(on model: AppModel) async throws -> Store {
            for _ in 0..<200 {
                if let store = model.store { return store }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            throw FixtureError.storeUnavailable
        }

        private static func prepareContentSnapshot(
            on model: AppModel,
            surface: SnapshotSurface
        ) async throws {
            switch surface {
            case .library:
                model.searchQuery = "navigation"
                model.scheduleSearchDebounced()
                // Exercise the same debounced query path as a person typing and
                // wait for it without racing a second direct search task.
                for _ in 0..<100 {
                    if !model.filteredSearchResults.isEmpty {
                        try await Task.sleep(for: .milliseconds(80))
                        return
                    }
                    if model.librarySearchState.issue != nil {
                        throw FixtureError.snapshotContentUnavailable
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
                throw FixtureError.snapshotContentUnavailable
            case .timeline:
                model.scheduleSelectedFrameExtract()
                for _ in 0..<120 {
                    if model.selectedFrameImage != nil {
                        try await Task.sleep(for: .milliseconds(80))
                        return
                    }
                    if model.selectedFramePreviewIssue != nil {
                        throw FixtureError.snapshotContentUnavailable
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
                throw FixtureError.snapshotContentUnavailable
            case .settings:
                // NavigationSplitView's AppKit-backed sidebar may need more
                // than one layout pass after the dedicated window is created.
                try await Task.sleep(for: .milliseconds(300))
                return
            case .visible, .setup:
                break
            }

            try await Task.sleep(for: .milliseconds(80))
        }

        private static func seedHistory(
            in store: Store,
            usesUnreadablePreview: Bool,
            includesMultipleDisplays: Bool,
            includesLongSession: Bool
        ) throws {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
            let hourMs: Int64 = 60 * 60 * 1_000
            let minuteMs: Int64 = 60 * 1_000
            let moments = [
                SeedMoment(
                    offsetMs: -(24 * hourMs + 25 * minuteMs),
                    foreground: "Trip notes, packing list, and hotel confirmation",
                    title: "Weekend Plans",
                    bundleID: "com.apple.Notes",
                    displayName: "Notes",
                    domain: nil,
                    url: nil,
                    accent: NSColor.systemYellow
                ),
                SeedMoment(
                    offsetMs: -(24 * hourMs + 5 * minuteMs),
                    foreground: "Designing for privacy and clear user consent",
                    title: "Privacy Design Principles",
                    bundleID: "com.apple.Safari",
                    displayName: "Safari",
                    domain: "developer.apple.com",
                    url: "https://developer.apple.com/design/human-interface-guidelines/privacy",
                    accent: NSColor.systemBlue
                ),
                SeedMoment(
                    offsetMs: -(30 * minuteMs),
                    foreground: "Project handoff and next steps for the design review",
                    title: "Design Review Follow-up",
                    bundleID: "com.apple.mail",
                    displayName: "Mail",
                    domain: nil,
                    url: nil,
                    accent: NSColor.systemCyan
                ),
                SeedMoment(
                    offsetMs: -(24 * minuteMs),
                    foreground: "Build completed successfully with all checks passing",
                    title: "Screenlogger Build",
                    bundleID: "com.apple.Terminal",
                    displayName: "Terminal",
                    domain: nil,
                    url: nil,
                    accent: NSColor.systemGray
                ),
                SeedMoment(
                    offsetMs: -(18 * minuteMs),
                    foreground: "Timeline navigation and preview loading implementation",
                    title: "Navigation Improvements",
                    bundleID: "com.apple.dt.Xcode",
                    displayName: "Xcode",
                    domain: nil,
                    url: nil,
                    accent: NSColor.systemIndigo
                ),
                SeedMoment(
                    offsetMs: -(12 * minuteMs),
                    foreground: "Navigation and keyboard interactions for Mac apps",
                    title: "Human Interface Guidelines",
                    bundleID: "com.apple.Safari",
                    displayName: "Safari",
                    domain: "developer.apple.com",
                    url: "https://developer.apple.com/design/human-interface-guidelines/",
                    accent: NSColor.systemBlue
                ),
                SeedMoment(
                    offsetMs: -(6 * minuteMs),
                    foreground: "Product review with design and engineering",
                    title: "Product Review",
                    bundleID: "com.apple.iCal",
                    displayName: "Calendar",
                    domain: nil,
                    url: nil,
                    accent: NSColor.systemRed
                ),
                SeedMoment(
                    offsetMs: -minuteMs,
                    foreground: "Quarterly planning decisions and launch checklist",
                    title: "Quarterly Planning Notes",
                    bundleID: "com.apple.TextEdit",
                    displayName: "TextEdit",
                    domain: nil,
                    url: nil,
                    accent: NSColor.systemGreen
                ),
            ]

            for (index, moment) in moments.enumerated() {
                let isNewestMoment = index == moments.index(before: moments.endIndex)
                let captureDisplay = CaptureDisplayRect(
                    x: 0,
                    y: 0,
                    width: 1_728,
                    height: 1_117
                )
                let imageData =
                    usesUnreadablePreview && isNewestMoment
                    ? Data("unreadable preview fixture".utf8)
                    : try fixtureImageData(for: moment)
                _ = try store.store(
                    payload: CapturePayload(
                        imageData: imageData,
                        timestampMs: nowMs + moment.offsetMs,
                        width: 1_280,
                        height: 800,
                        foreground: moment.foreground,
                        title: moment.title,
                        bundleID: moment.bundleID,
                        displayName: moment.displayName,
                        url: moment.url,
                        domain: moment.domain,
                        ocrBoxes: [
                            OCRBox(
                                x: 360,
                                y: 310,
                                width: 700,
                                height: 48,
                                textOffset: 0,
                                textLength: moment.foreground.utf16.count
                            )
                        ],
                        imageFileExtension: "png",
                        captureDisplay: captureDisplay
                    )
                )

                if includesMultipleDisplays,
                    index == moments.count - 1 || index == moments.count - 3
                {
                    let secondaryMoment = SeedMoment(
                        offsetMs: moment.offsetMs,
                        foreground: "Secondary display: \(moment.foreground)",
                        title: moment.title,
                        bundleID: moment.bundleID,
                        displayName: moment.displayName,
                        domain: moment.domain,
                        url: moment.url,
                        accent: NSColor.systemPurple
                    )
                    _ = try store.store(
                        payload: CapturePayload(
                            imageData: try fixtureImageData(for: secondaryMoment),
                            timestampMs: nowMs + moment.offsetMs,
                            width: 1_280,
                            height: 800,
                            foreground: secondaryMoment.foreground,
                            title: secondaryMoment.title,
                            bundleID: secondaryMoment.bundleID,
                            displayName: secondaryMoment.displayName,
                            url: secondaryMoment.url,
                            domain: secondaryMoment.domain,
                            ocrBoxes: [
                                OCRBox(
                                    x: 260,
                                    y: 310,
                                    width: 800,
                                    height: 48,
                                    textOffset: 0,
                                    textLength: secondaryMoment.foreground.utf16.count
                                )
                            ],
                            imageFileExtension: "png",
                            captureDisplay: CaptureDisplayRect(
                                x: 1_728,
                                y: 0,
                                width: 1_920,
                                height: 1_080
                            )
                        )
                    )
                }
            }

            if includesLongSession {
                let spacingMs: Int64 = 10_000
                let momentCount = 620
                let firstTimestamp = nowMs - Int64(momentCount) * spacingMs
                for index in 0..<momentCount {
                    _ = try store.insertSeedFrame(
                        timestampMs: firstTimestamp + Int64(index) * spacingMs,
                        foreground: "Long session moment \(index + 1)",
                        bundleID: "com.apple.TextEdit",
                        displayName: "TextEdit"
                    )
                }
            }
        }

        private static func seedAudioTranscript(in store: Store) throws {
            let timestampMs = Int64(Date().timeIntervalSince1970 * 1_000) - 60_000
            _ = try store.storeTranscript(
                TranscriptSegmentDraft(
                    startTimestampMs: timestampMs - 700,
                    endTimestampMs: timestampMs + 900,
                    source: .microphone,
                    text: "Let's confirm the launch plan and owners.",
                    localeIdentifier: "en-US"
                )
            )
            _ = try store.storeTranscript(
                TranscriptSegmentDraft(
                    startTimestampMs: timestampMs + 1_000,
                    endTimestampMs: timestampMs + 2_600,
                    source: .computer,
                    text: "The design review is scheduled for Thursday.",
                    localeIdentifier: "en-US"
                )
            )
        }

        private static func fixtureImageData(for moment: SeedMoment) throws -> Data {
            let size = NSSize(width: 1_280, height: 800)
            let image = NSImage(size: size, flipped: false) { bounds in
                NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1).setFill()
                bounds.fill()

                let window = NSBezierPath(
                    roundedRect: NSRect(x: 80, y: 70, width: 1_120, height: 660),
                    xRadius: 18,
                    yRadius: 18
                )
                NSColor.white.setFill()
                window.fill()

                let sidebar = NSBezierPath(
                    roundedRect: NSRect(x: 80, y: 70, width: 220, height: 660),
                    xRadius: 18,
                    yRadius: 18
                )
                moment.accent.withAlphaComponent(0.16).setFill()
                sidebar.fill()
                NSColor.white.setFill()
                NSRect(x: 282, y: 70, width: 18, height: 660).fill()

                moment.accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: 116, y: 649, width: 38, height: 38)).fill()

                let titleAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
                    .foregroundColor: NSColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1),
                ]
                moment.title.draw(
                    in: NSRect(x: 360, y: 560, width: 740, height: 54),
                    withAttributes: titleAttributes
                )

                let appAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 20, weight: .medium),
                    .foregroundColor: moment.accent,
                ]
                moment.displayName.draw(
                    in: NSRect(x: 360, y: 522, width: 600, height: 32),
                    withAttributes: appAttributes
                )

                let bodyAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 25, weight: .regular),
                    .foregroundColor: NSColor(srgbRed: 0.34, green: 0.36, blue: 0.41, alpha: 1),
                ]
                moment.foreground.draw(
                    in: NSRect(x: 360, y: 390, width: 700, height: 100),
                    withAttributes: bodyAttributes
                )

                for index in 0..<4 {
                    let lineWidth = CGFloat(620 - index * 70)
                    let line = NSBezierPath(
                        roundedRect: NSRect(
                            x: 360,
                            y: CGFloat(328 - index * 48),
                            width: lineWidth,
                            height: 14
                        ),
                        xRadius: 7,
                        yRadius: 7
                    )
                    NSColor(srgbRed: 0.78, green: 0.80, blue: 0.84, alpha: 0.7).setFill()
                    line.fill()
                }

                return true
            }
            guard let tiff = image.tiffRepresentation,
                let representation = NSBitmapImageRep(data: tiff),
                let png = representation.representation(using: .png, properties: [:])
            else { throw FixtureError.imageEncodingFailed }
            return png
        }

        /// Render only Screenlogger's own window hierarchy. Using the content
        /// view's private theme-frame parent includes native titlebar and toolbar
        /// chrome without Screen Recording permission, and cannot capture another
        /// app or desktop content.
        private static func writeContentSnapshot(
            in root: URL,
            surface: SnapshotSurface
        ) async throws {
            for _ in 0..<80 {
                let visibleWindows = NSApp.windows.filter { $0.isVisible && !$0.isMiniaturized }
                let candidates =
                    surface.windowTitle.map { title in
                        visibleWindows.filter { $0.title == title }
                    } ?? visibleWindows
                let window =
                    candidates
                    .max { lhs, rhs in
                        let lhsArea = lhs.contentView.map { $0.bounds.width * $0.bounds.height } ?? 0
                        let rhsArea = rhs.contentView.map { $0.bounds.width * $0.bounds.height } ?? 0
                        return lhsArea < rhsArea
                    }
                if let window,
                    let contentView = window.contentView,
                    !contentView.bounds.isEmpty
                {
                    if configuration?.snapshotsAtMinimumWindowSize == true,
                        window.contentMinSize.width > 0,
                        window.contentMinSize.height > 0
                    {
                        let requestedMinimum =
                            surface == .timeline
                            ? SLDesign.workspaceMinimumSize
                            : window.contentMinSize
                        // Request the product contract, not a dynamic minimum
                        // that a hosted toolbar may have accidentally enlarged.
                        window.contentMinSize = requestedMinimum
                        window.setContentSize(requestedMinimum)
                        // Give SwiftUI and NSToolbar one turn to resolve their
                        // compact variants after the AppKit frame changes.
                        try await Task.sleep(for: .milliseconds(80))
                        let actualSize = contentView.bounds.size
                        guard abs(actualSize.width - requestedMinimum.width) <= 1,
                            abs(actualSize.height - requestedMinimum.height) <= 1
                        else {
                            throw FixtureError.windowSizeMismatch(
                                expected: requestedMinimum,
                                actual: actualSize
                            )
                        }
                    }
                    window.displayIfNeeded()
                    let renderedView = contentView.superview ?? contentView
                    renderedView.layoutSubtreeIfNeeded()
                    guard
                        let representation = renderedView.bitmapImageRepForCachingDisplay(
                            in: renderedView.bounds
                        )
                    else { throw FixtureError.snapshotUnavailable }
                    renderedView.cacheDisplay(in: renderedView.bounds, to: representation)
                    guard let png = representation.representation(using: .png, properties: [:]) else {
                        throw FixtureError.snapshotUnavailable
                    }
                    try png.write(
                        to: root.appendingPathComponent("ui-content-snapshot.png"),
                        options: .atomic
                    )
                    return
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            throw FixtureError.snapshotUnavailable
        }

        private enum FixtureError: Error {
            case storeUnavailable
            case snapshotUnavailable
            case imageEncodingFailed
            case compactionFailed
            case snapshotContentUnavailable
            case windowSizeMismatch(expected: NSSize, actual: NSSize)
        }
    }
#endif
