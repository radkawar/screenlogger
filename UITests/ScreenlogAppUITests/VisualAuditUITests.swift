import AppKit
import Foundation
import XCTest

/// Deterministic, human-reviewed screenshots of Screenlogger's major surfaces.
///
/// These are an audit matrix, not brittle pixel-equality tests. Every launch is
/// authenticated against an isolated temporary Library and preferences suite,
/// uses synthetic local media, and captures only an app-owned window, sheet, or
/// bounded native menu.
/// Run through `Scripts/test-ui.sh` or select this class in Xcode, then export
/// the named attachments with `Scripts/export-ui-audit.sh`.
final class VisualAuditUITests: XCTestCase {
    private static let bundleIdentifier = "dev.screenlog.app"
    private static let readinessTimeout: TimeInterval = 8

    private enum SnapshotSurface: String {
        case library, timeline, setup, settings
    }

    private enum WindowSize {
        case `default`
        case minimum
    }

    private static let settingsPanes: [(sidebar: String, pane: String, name: String)] = [
        ("settings.sidebar.general", "settings.pane.general.heading", "general"),
        ("settings.sidebar.appearance", "settings.pane.appearance.heading", "appearance"),
        ("settings.sidebar.shortcuts", "settings.pane.shortcuts.heading", "keyboard-shortcuts"),
        ("settings.sidebar.capture", "settings.pane.capture.heading", "capture"),
        ("settings.sidebar.privacy", "settings.pane.privacy.heading", "privacy"),
        (
            "settings.sidebar.exclusions",
            "settings.pane.exclusions.heading",
            "exclusions-applications"
        ),
        ("settings.sidebar.storage", "settings.pane.storage.heading", "storage"),
        ("settings.sidebar.integrations", "settings.pane.integrations.heading", "integrations"),
        ("settings.sidebar.support", "settings.pane.support.heading", "support-about"),
    ]

    private var app: XCUIApplication?
    private var dataDirectory: URL?
    private var preferencesSuite: String?
    private var navigationObservations: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false

        let productIsRunning = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        ).contains { !$0.isTerminated }
        try XCTSkipIf(
            productIsRunning,
            "Quit the running Screenlogger app before running visual-audit tests."
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlogger-ui-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at:
                directory
                .appendingPathComponent("home", isDirectory: true)
                .appendingPathComponent("Library/Preferences", isDirectory: true),
            withIntermediateDirectories: true
        )
        dataDirectory = directory
    }

    override func tearDownWithError() throws {
        attachNavigationObservations()

        app?.terminate()
        _ = app?.wait(for: .notRunning, timeout: 4)
        app = nil

        if let preferencesSuite {
            UserDefaults.standard.removePersistentDomain(forName: preferencesSuite)
        }
        preferencesSuite = nil

        if let dataDirectory {
            try? FileManager.default.removeItem(at: dataDirectory)
        }
        dataDirectory = nil
    }

    // MARK: - Library

    func testVisualAuditLibraryDefaultStatesAndAssistantSheet() throws {
        let app = try launch(
            route: "--open-library",
            assistantReady: ["claude", "codex", "grok"]
        )
        let library = assertWindow("Library", in: app)

        assertElement("library.state.idle", in: app)
        capture(library, named: "ui-audit-library-empty-default-light")

        let search = assertElement("library.search.field", in: app)
        let result = observeNavigation("Library query to populated results") {
            search.click()
            search.typeText("navigation")
            return app.descendants(matching: .any)["library.result.6"]
        }
        XCTAssertTrue(result.exists)
        result.click()
        assertElement("library.filters.pane", in: app)
        assertElement("library.inspector.pane", in: app)
        assertElement("library.result.inspector.selection.6", in: app)
        capture(library, named: "ui-audit-library-results-filters-preview-default-light")

        let todayFilter = assertElement("library.filter.time.today", in: app)
        todayFilter.click()
        capture(library, named: "ui-audit-library-time-filter-selected-default-light")
        todayFilter.click()

        let datePicker = observeNavigation("Library Filters to date picker") {
            assertElement("library.filter.date.choose", in: app).click()
            return app.popovers.firstMatch
        }
        assertElement("library.search.date-picker.calendar", in: app)
        assertElement("library.search.date-picker.cancel", in: app)
        assertElement("library.search.date-picker.apply", in: app)
        capture(library, named: "ui-audit-library-date-filter-context-default-light")
        capture(datePicker, named: "ui-audit-library-date-picker-detail-light")
        _ = observeNavigation("Library date picker to applied date filter") {
            assertButton("Apply", in: datePicker).click()
            return app.descendants(matching: .any)["library.search.operator.date"]
        }
        capture(library, named: "ui-audit-library-date-filter-applied-default-light")

        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText("Find the design review I was reading")
        let handoff = observeNavigation("Library Command-Return to assistant review") {
            app.typeKey(.return, modifierFlags: .command)
            return app.sheets.firstMatch
        }
        assertElement("library.assistant.sheet", in: app)
        assertButton("Claude Code", in: app)
        assertButton("Codex", in: app)
        assertButton("Grok Build", in: app)
        capture(library, named: "ui-audit-library-assistant-routing-sheet-default-light")
        capture(handoff, named: "ui-audit-assistant-routing-sheet-detail-light")
    }

    func testVisualAuditLibraryMinimumDark() throws {
        let app = try launch(
            route: "--open-library",
            snapshotSurface: .library,
            windowSize: .minimum,
            appearance: "dark"
        )
        let library = assertWindow("Library", in: app)
        resizeWorkspaceToMinimum(library)
        assertElement("library.workspace.compact", in: app)
        assertElement("library.result.6", in: app)
        capture(library, named: "ui-audit-library-results-minimum-dark")
    }

    // MARK: - Timeline

    func testVisualAuditTimelineDefaultControlsAndDeletionReview() throws {
        let app = try launch(
            route: "--open-timeline",
            snapshotSurface: .timeline
        )
        let timeline = assertWindow("Timeline", in: app)
        assertElement("timeline.moment", in: app)
        assertElement("timeline.navigation", in: app)
        assertElement("timeline.playback.toggle", in: app)
        assertElement("timeline.moment.actions", in: app)
        capture(timeline, named: "ui-audit-timeline-normal-controls-default-light")

        assertElement("timeline.moment.actions", in: app).click()
        let review = observeNavigation("Timeline action to deletion review") {
            let delete = app.descendants(matching: .any)["timeline.moment.actions.delete"]
            XCTAssertTrue(
                delete.waitForExistence(timeout: Self.readinessTimeout),
                "Moment Actions should expose Delete Moment."
            )
            delete.click()
            return app.sheets.firstMatch
        }
        assertElement("library.deletion.review.irreversible-warning", in: app)
        assertElement("library.deletion.review.cancel", in: app)
        assertElement("library.deletion.review.confirm", in: app)
        capture(timeline, named: "ui-audit-timeline-deletion-review-context-light")
        capture(review, named: "ui-audit-deletion-review-sheet-detail-light")
    }

    func testVisualAuditTimelineRecoveryNotices() throws {
        let app = try launch(
            route: "--open-timeline",
            captureIssue: true,
            unreadablePreview: true
        )
        let timeline = assertWindow("Timeline", in: app)
        assertElement("capture.issue.timeline", in: app)
        assertElement("timeline.preview.issue", in: app)
        capture(timeline, named: "ui-audit-timeline-capture-and-preview-notices-light")
    }

    func testVisualAuditTimelineMinimumDark() throws {
        let app = try launch(
            route: "--open-timeline",
            snapshotSurface: .timeline,
            windowSize: .minimum,
            appearance: "dark"
        )
        let timeline = assertWindow("Timeline", in: app)
        resizeWorkspaceToMinimum(timeline)
        assertMinimumWorkspaceFrame(timeline)
        parkPointer(in: timeline)
        assertElement("timeline.moment", in: app)
        assertElement("timeline.playback.toggle", in: app)
        assertElement("navigation.timeline.library", in: app)
        assertElement("navigation.timeline.settings", in: app)
        capture(timeline, named: "ui-audit-timeline-controls-minimum-dark")
    }

    // MARK: - Setup

    func testVisualAuditSetupMissingPermission() throws {
        let app = try launch(
            route: "--open-setup",
            snapshotSurface: .setup,
            missingPermission: true
        )
        let setup = assertWindow("Permissions & Privacy", in: app)
        assertMissingScreenRecordingStep(in: app)
        assertElement("setup.open-screen-recording", in: app)
        assertElement("setup.keep-off", in: app)
        capture(setup, named: "ui-audit-setup-screen-recording-required-default-light")
    }

    func testVisualAuditSetupMissingPermissionMinimumDark() throws {
        let app = try launch(
            route: "--open-setup",
            snapshotSurface: .setup,
            windowSize: .minimum,
            appearance: "dark",
            missingPermission: true
        )
        let setup = assertWindow("Permissions & Privacy", in: app)
        assertMissingScreenRecordingStep(in: app)
        assertElement("setup.open-screen-recording", in: app)
        assertElement("setup.keep-off", in: app)
        capture(setup, named: "ui-audit-setup-screen-recording-required-minimum-dark")
    }

    func testVisualAuditSetupReadyWithOptionalAudio() throws {
        let app = try launch(
            route: "",
            snapshotSurface: .setup
        )
        let setup = assertWindow("Permissions & Privacy", in: app)
        assertElement("setup.audio", in: app)
        assertElement("setup.audio.enabled", in: app)
        assertElement("setup.start-capture", in: app)
        capture(setup, named: "ui-audit-setup-ready-optional-audio-default-light")
    }

    // MARK: - Status menu

    func testVisualAuditStatusMenuDefaultLight() throws {
        let app = try launch(route: "--open-library")
        assertWindow("Library", in: app)

        let statusItem = app.statusItems["status-menu.button"]
        XCTAssertTrue(
            statusItem.waitForExistence(timeout: Self.readinessTimeout),
            "The app-owned status item should be available for a bounded native-menu capture."
        )
        statusItem.click()

        let captureStatus = assertElement("status-menu.capture-status", in: app)
        XCTAssertEqual(captureStatus.label, "Capture Off")
        XCTAssertEqual(
            assertElement("status-menu.capture-toggle", in: app).label,
            "Start Capture"
        )
        assertElement("status-menu.library", in: app)
        assertElement("status-menu.timeline", in: app)
        assertElement("status-menu.settings", in: app)
        assertElement("status-menu.quit", in: app)

        let menu =
            app.menus.allElementsBoundByIndex.first {
                $0.exists && !$0.frame.isEmpty && $0.frame.width > 0 && $0.frame.height > 0
            } ?? app.menus.firstMatch
        XCTAssertFalse(menu.frame.isEmpty, "The open app-owned NSMenu should have a visible frame.")
        capture(menu, named: "ui-audit-status-menu-capture-off-default-light")
    }

    // MARK: - Settings

    func testVisualAuditEverySettingsPaneDefault() throws {
        let app = try launch(
            route: "--open-library",
            snapshotSurface: .settings,
            assistantReady: ["claude", "codex", "grok"]
        )
        let settings = assertWindow("Settings", in: app)

        for pane in Self.settingsPanes {
            _ = observeNavigation("Settings sidebar to \(pane.name)") {
                assertElement(pane.sidebar, in: app).click()
                return app.descendants(matching: .any)[pane.pane]
            }
            capture(
                settings,
                named: "ui-audit-settings-\(pane.name)-default-light"
            )
        }

        _ = observeNavigation("Settings sidebar back to Exclusions") {
            assertElement("settings.sidebar.exclusions", in: app).click()
            return app.descendants(matching: .any)["settings.pane.exclusions.heading"]
        }
        let websitesControl = control(labeled: "Websites", in: app)
        let websitesScope = app.descendants(matching: .any)["exclusions.websites.scope"]
        _ = observeNavigation("Exclusions Applications to Websites") {
            websitesControl.click()
            return websitesScope
        }
        assertElement("exclusions.websites.search", in: app)
        assertElement("exclusions.websites.filter", in: app)
        capture(settings, named: "ui-audit-settings-exclusions-websites-default-light")

        assertElement("settings.sidebar.support", in: app).click()
        assertElement("settings.pane.support.heading", in: app)
        let guide = observeNavigation("Support to offline User Guide") {
            assertElement("settings.support.user-guide", in: app).click()
            return app.sheets.firstMatch
        }
        assertElement("settings.guide.detail.gettingStarted", in: app)
        capture(app.windows.firstMatch, named: "ui-audit-settings-user-guide-sheet-context-light")
        capture(guide, named: "ui-audit-user-guide-sheet-detail-light")
    }

    func testVisualAuditEverySettingsPaneMinimumDark() throws {
        let app = try launch(
            route: "--open-library",
            snapshotSurface: .settings,
            settingsDestination: "general",
            windowSize: .minimum,
            appearance: "dark",
            assistantReady: ["claude", "codex", "grok"]
        )
        let settings = assertWindow("Settings", in: app)

        for pane in Self.settingsPanes {
            _ = observeNavigation("Minimum Settings sidebar to \(pane.name)") {
                assertElement(pane.sidebar, in: app).click()
                return app.descendants(matching: .any)[pane.pane]
            }
            capture(settings, named: "ui-audit-settings-\(pane.name)-minimum-dark")
        }

        _ = observeNavigation("Minimum Settings back to Exclusions") {
            assertElement("settings.sidebar.exclusions", in: app).click()
            return app.descendants(matching: .any)["settings.pane.exclusions.heading"]
        }
        let websitesControl = control(labeled: "Websites", in: app)
        let websitesScope = app.descendants(matching: .any)["exclusions.websites.scope"]
        _ = observeNavigation("Minimum Exclusions Applications to Websites") {
            websitesControl.click()
            return websitesScope
        }
        capture(settings, named: "ui-audit-settings-exclusions-websites-minimum-dark")
    }

    func testVisualAuditAppearanceIncreasedContrastOrange() throws {
        let app = try launch(
            route: "--open-library",
            snapshotSurface: .settings,
            settingsDestination: "appearance",
            appearance: "light",
            accent: "orange",
            increasedContrast: true
        )
        let settings = assertWindow("Settings", in: app)
        assertElement("settings.pane.appearance.heading", in: app)
        assertElement("settings.appearance.accent", in: app)
        capture(
            settings,
            named: "ui-audit-settings-appearance-increased-contrast-orange"
        )
    }

    func testVisualAuditAudioTranscriptionSettingsAndTimelineCaptions() throws {
        let app = try launch(
            route: "--open-library",
            snapshotSurface: .settings,
            settingsDestination: "capture",
            audioTranscription: "active"
        )
        let settings = assertWindow("Settings", in: app)
        let search = app.searchFields["Search Settings"]
        XCTAssertTrue(search.waitForExistence(timeout: Self.readinessTimeout))
        search.click()
        search.typeText("audio transcription")
        assertElement("settings.search-result.capture-audio", in: app).click()

        assertElement("capture.audio-transcription", in: app)
        assertElement("capture.audio.enabled.toggle", in: app)
        assertElement("capture.audio.computer.toggle", in: app)
        assertElement("capture.audio.microphone.toggle", in: app)
        assertElement("capture.audio.status", in: app)
        capture(settings, named: "ui-audit-settings-audio-transcription-enabled-light")

        assertElement("navigation.settings.timeline", in: app).click()
        let timeline = assertWindow("Timeline", in: app)
        assertElement("timeline.transcript", in: app)
        capture(timeline, named: "ui-audit-timeline-audio-captions-light")
    }

    func testVisualAuditAudioTranscriptionNeedsAttention() throws {
        let app = try launch(
            route: "--open-library",
            snapshotSurface: .settings,
            settingsDestination: "capture",
            audioTranscription: "failed"
        )
        let settings = assertWindow("Settings", in: app)
        let search = app.searchFields["Search Settings"]
        XCTAssertTrue(search.waitForExistence(timeout: Self.readinessTimeout))
        search.click()
        search.typeText("audio transcription")
        assertElement("settings.search-result.capture-audio", in: app).click()
        assertElement("capture.audio-transcription", in: app)
        assertElement("capture.audio.status", in: app)
        assertElement("capture.audio.status.action", in: app)
        capture(settings, named: "ui-audit-settings-audio-needs-attention-light")
    }

    /// A deliberately short, deterministic product tour intended for screen
    /// recording. It is opt-in so the pauses never slow the ordinary UI suite.
    func testRecordProductTour() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SCREENLOGGER_RECORD_DEMO"] == "1"
                || FileManager.default.fileExists(
                    atPath: "/tmp/screenlogger-record-product-tour"
                ),
            "Run explicitly while recording the product tour."
        )

        let app = try launch(
            route: "--open-library",
            assistantReady: ["claude", "codex", "grok"]
        )
        assertWindow("Library", in: app)
        demoPause(0.8)

        let search = assertElement("library.search.field", in: app)
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        search.typeText("navigation")
        XCTAssertEqual(search.value as? String, "navigation")
        assertElement("library.result.6", in: app)
        demoPause(0.8)

        let secondResult = assertElement("library.result.5", in: app)
        secondResult.click()
        assertElement("library.result.inspector.selection.5", in: app)
        demoPause(0.6)

        assertElement("library.result.inspector.open", in: app).click()
        assertWindow("Timeline", in: app)
        assertElement("timeline.moment", in: app)
        demoPause(0.9)

        assertElement("timeline.segment.previous", in: app).click()
        demoPause(0.5)
        assertElement("timeline.segment.next", in: app).click()
        demoPause(0.5)

        let playback = assertElement("timeline.playback.toggle", in: app)
        playback.click()
        demoPause(1.0)
        playback.click()
        demoPause(0.4)

        assertElement("navigation.timeline.settings", in: app).click()
        let settings = assertWindow("Settings", in: app)
        demoPause(0.7)

        for pane in [
            "settings.sidebar.capture",
            "settings.sidebar.privacy",
            "settings.sidebar.exclusions",
            "settings.sidebar.integrations",
        ] {
            assertElement(pane, in: app).click()
            XCTAssertTrue(settings.exists)
            demoPause(pane == "settings.sidebar.integrations" ? 1.0 : 0.7)
        }

        app.typeKey("1", modifierFlags: .command)
        assertWindow("Library", in: app)
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText("Find the design review I was reading")
        app.typeKey(.return, modifierFlags: .command)
        assertElement("library.assistant.sheet", in: app)
        demoPause(1.2)
    }

    /// A deterministic Settings-to-Timeline tour for recording the
    /// multi-display workflow without slowing the ordinary UI suite.
    func testRecordMultiDisplayTour() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SCREENLOGGER_RECORD_MULTIDISPLAY_DEMO"] == "1"
                || FileManager.default.fileExists(
                    atPath: "/tmp/screenlogger-record-multidisplay-tour"
                ),
            "Run explicitly while recording the multi-display tour."
        )

        let app = try launch(
            route: "--open-library",
            multipleDisplays: true
        )
        assertWindow("Library", in: app)
        demoPause(0.8)

        assertElement("navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)
        demoPause(0.8)

        let search = app.searchFields["Search Settings"]
        XCTAssertTrue(search.waitForExistence(timeout: Self.readinessTimeout))
        search.click()
        search.typeText("multiple monitors")
        demoPause(1.0)

        assertElement("settings.search-result.capture-displays", in: app).click()
        let picker = assertElement("capture.displays.picker", in: app)
        XCTAssertEqual(picker.value as? String, "Active display")
        demoPause(1.0)

        assertControl("All displays", in: app).click()
        XCTAssertEqual(picker.value as? String, "All displays")
        assertElement("capture.displays.privacy-note", in: app)
        demoPause(1.4)

        assertElement("navigation.settings.timeline", in: app).click()
        assertWindow("Timeline", in: app)
        let timelinePicker = assertElement("timeline.display.picker", in: app)
        XCTAssertEqual(timelinePicker.value as? String, "Display 2")
        demoPause(1.2)

        assertControl("Main Display", in: app).click()
        XCTAssertEqual(timelinePicker.value as? String, "Main Display")
        demoPause(1.0)

        assertControl("Display 2", in: app).click()
        XCTAssertEqual(timelinePicker.value as? String, "Display 2")
        demoPause(1.0)

        assertElement("timeline.playback.previous", in: app).click()
        demoPause(0.9)
        assertElement("timeline.playback.previous", in: app).click()
        XCTAssertEqual(
            assertElement("timeline.display.picker", in: app).value as? String,
            "Display 2"
        )
        demoPause(1.2)

        assertElement("timeline.playback.next", in: app).click()
        demoPause(0.8)
        assertElement("timeline.playback.next", in: app).click()
        XCTAssertEqual(
            assertElement("timeline.display.picker", in: app).value as? String,
            "Display 2"
        )
        demoPause(1.4)
    }

    func testVisualAuditAssistantConnectionRecoveryDefaultLight() throws {
        let app = try launch(
            route: "--open-library",
            assistantDetected: ["codex"]
        )
        let library = assertWindow("Library", in: app)
        let search = assertElement("library.search.field", in: app)
        search.click()
        search.typeText("find my design review")

        let settings = observeNavigation("Library ask to assistant connections") {
            app.typeKey(.return, modifierFlags: .command)
            return app.windows["Settings"]
        }
        XCTAssertFalse(
            app.descendants(matching: .any)["library.assistant.unavailable"].exists,
            "A query with no assistant connection should skip the empty Ask an Assistant sheet."
        )
        capture(library, named: "ui-audit-library-assistant-unavailable-context-light")
        assertElement("settings.pane.integrations.heading", in: app)
        let recoveredRow = assertElement("settings.integration.codex", in: app)
        XCTAssertTrue(recoveredRow.isHittable)
        capture(settings, named: "ui-audit-settings-assistant-recovery-default-light")
    }

    // MARK: - Isolated launch

    private func launch(
        route: String,
        snapshotSurface: SnapshotSurface? = nil,
        settingsDestination: String? = nil,
        windowSize: WindowSize = .default,
        appearance: String = "light",
        accent: String? = nil,
        increasedContrast: Bool = false,
        captureIssue: Bool = false,
        unreadablePreview: Bool = false,
        missingPermission: Bool = false,
        assistantDetected: [String] = [],
        assistantReady: [String] = [],
        multipleDisplays: Bool = false,
        audioTranscription: String? = nil
    ) throws -> XCUIApplication {
        let directory = try XCTUnwrap(dataDirectory)
        let token = try XCTUnwrap(UUID(uuidString: directory.lastPathComponent)).uuidString
        let suite = "dev.screenlog.ui-tests.\(token)"
        preferencesSuite = suite

        let application = XCUIApplication(bundleIdentifier: Self.bundleIdentifier)
        application.launchArguments = [
            route,
            "--screenlogger-ui-test-token",
            token,
        ]
        application.launchEnvironment["SCREENLOG_DATA_DIR"] = directory.path
        application.launchEnvironment["CFFIXED_USER_HOME"] =
            directory.appendingPathComponent("home", isDirectory: true).path
        application.launchEnvironment["LANGUAGE"] = "en"
        application.launchEnvironment["LC_ALL"] = "en_US.UTF-8"
        application.launchEnvironment["SCREENLOG_UI_TEST_PREFERENCES_MODE"] = "isolated-v1"
        application.launchEnvironment["SCREENLOG_UI_TEST_PREFERENCES_SUITE"] = suite
        application.launchEnvironment["SCREENLOG_UI_TEST_FIXTURE"] =
            "deterministic-navigation-v1"
        application.launchEnvironment["SCREENLOG_UI_TEST_APPEARANCE"] = appearance
        if let accent {
            application.launchEnvironment["SCREENLOG_UI_TEST_ACCENT"] = accent
        }
        if increasedContrast {
            application.launchEnvironment["SCREENLOG_UI_TEST_INCREASED_CONTRAST"] = "1"
        }
        application.launchEnvironment["SCREENLOG_UI_TEST_LOGIN_ITEM_ISSUE"] =
            "registration-failed"
        application.launchEnvironment["SCREENLOG_UI_TEST_READY_ASSISTANTS"] =
            assistantReady.joined(separator: ",")
        application.launchEnvironment["SCREENLOG_UI_TEST_DETECTED_ASSISTANTS"] =
            assistantDetected.joined(separator: ",")

        if multipleDisplays {
            application.launchEnvironment["SCREENLOG_UI_TEST_MULTIPLE_DISPLAYS"] = "1"
        }
        if let audioTranscription {
            application.launchEnvironment["SCREENLOG_UI_TEST_AUDIO_TRANSCRIPTION"] =
                audioTranscription
        }

        if captureIssue {
            application.launchEnvironment["SCREENLOG_UI_TEST_CAPTURE_ISSUE"] = "start-failed"
        }
        if unreadablePreview {
            application.launchEnvironment["SCREENLOG_UI_TEST_PREVIEW_ISSUE"] = "media-unreadable"
        }
        if missingPermission {
            application.launchEnvironment["SCREENLOG_UI_TEST_PERMISSION_ISSUE"] =
                "screen-recording-denied"
        }
        if let snapshotSurface {
            application.launchEnvironment["SCREENLOG_UI_TEST_SNAPSHOT"] = "content"
            application.launchEnvironment["SCREENLOG_UI_TEST_SNAPSHOT_SURFACE"] =
                snapshotSurface.rawValue
        }
        if let settingsDestination {
            application.launchEnvironment["SCREENLOG_UI_TEST_SETTINGS_DESTINATION"] =
                settingsDestination
        }
        if windowSize == .minimum {
            application.launchEnvironment["SCREENLOG_UI_TEST_SNAPSHOT_WINDOW_SIZE"] =
                "minimum"
        }

        application.launch()
        // Screenlogger normally runs as an accessory app. Xcode can leave the
        // test runner active even after the product has ordered its key window,
        // so explicitly request activation before querying its named window.
        application.activate()
        app = application
        let running =
            application.wait(for: .runningForeground, timeout: 2)
            || application.wait(for: .runningBackground, timeout: Self.readinessTimeout - 2)
        XCTAssertTrue(running, "Screenlogger did not remain running after launching with \(route).")
        try waitForFixture(in: directory)
        return application
    }

    private func waitForFixture(in directory: URL) throws {
        let marker = directory.appendingPathComponent("ui-fixture-ready")
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: marker.path)
            },
            object: nil
        )
        guard XCTWaiter.wait(for: [ready], timeout: Self.readinessTimeout) == .completed else {
            let errorURL = directory.appendingPathComponent("ui-fixture-error")
            let detail =
                (try? String(contentsOf: errorURL, encoding: .utf8))
                ?? "No fixture error was written."
            XCTFail("The deterministic visual fixture did not become ready. \(detail)")
            return
        }
    }

    // MARK: - Audit evidence

    private func assertMissingScreenRecordingStep(in app: XCUIApplication) {
        let permissionStep = assertElement("setup.progress.permission", in: app)
        XCTAssertEqual(permissionStep.label, "Screen Recording")
        XCTAssertEqual(permissionStep.value as? String, "Current step")
        assertElement("setup.next-action", in: app)
    }

    private func capture(
        _ element: XCUIElement,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.exists, "Expected \(name) capture target.", file: file, line: line)
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertMinimumWorkspaceFrame(
        _ window: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frame = window.frame
        XCTAssertEqual(
            frame.width,
            820,
            accuracy: 5,
            "The minimum audit must capture the 820-point workspace, not the default window.",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            frame.height,
            540,
            "The native titlebar frame must contain the 540-point content minimum.",
            file: file,
            line: line
        )
        XCTAssertLessThan(
            frame.height,
            640,
            "The minimum audit must not silently retain the 760-point default content height.",
            file: file,
            line: line
        )
    }

    private func resizeWorkspaceToMinimum(
        _ window: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let target = CGSize(width: 820, height: 592)
        let current = window.frame
        guard abs(current.width - target.width) > 5 || abs(current.height - target.height) > 5 else {
            return
        }

        let handle = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        let destination = handle.withOffset(
            CGVector(dx: target.width - current.width, dy: target.height - current.height)
        )
        handle.click(forDuration: 0.1, thenDragTo: destination)

        let reachedSize = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return abs(element.frame.width - target.width) <= 5
                    && abs(element.frame.height - target.height) <= 5
            },
            object: window
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [reachedSize], timeout: Self.readinessTimeout),
            .completed,
            "Expected the visual audit workspace to reach its minimum size.",
            file: file,
            line: line
        )
    }

    private func parkPointer(in window: XCUIElement) {
        // Keep edge-activated Dock chrome and hover treatments out of the
        // bounded product screenshot without synthesizing a click.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    }

    private func demoPause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Records navigation time as audit evidence while correctness is guarded
    /// by a deliberately generous bounded readiness wait. The observation has
    /// no fragile performance threshold; regressions can be compared between
    /// audit runs without making ordinary UI tests sensitive to host load.
    @discardableResult
    private func observeNavigation(
        _ description: String,
        action: () -> XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let start = ProcessInfo.processInfo.systemUptime
        let destination = action()
        let becameReady = destination.waitForExistence(timeout: Self.readinessTimeout)
        let duration = ProcessInfo.processInfo.systemUptime - start
        navigationObservations.append(
            String(
                format: "%@: %.3f seconds (readiness bound %.0f seconds)",
                description,
                duration,
                Self.readinessTimeout
            )
        )
        XCTAssertTrue(
            becameReady,
            "Expected \(description) to expose its destination within the readiness bound.",
            file: file,
            line: line
        )
        return destination
    }

    private func attachNavigationObservations() {
        guard !navigationObservations.isEmpty else { return }
        let report =
            ([
                "Screenlogger visual-audit navigation observations",
                "These timings are informational; UI correctness uses bounded semantic readiness assertions.",
                "",
            ] + navigationObservations).joined(separator: "\n") + "\n"
        let attachment = XCTAttachment(
            data: Data(report.utf8),
            uniformTypeIdentifier: "public.plain-text"
        )
        attachment.name = "ui-audit-navigation-\(safeTestName)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var safeTestName: String {
        name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()
    }

    // MARK: - Semantic queries

    @discardableResult
    private func assertWindow(
        _ title: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let window = app.windows[title]
        XCTAssertTrue(
            window.waitForExistence(timeout: Self.readinessTimeout),
            "Expected window named \(title).",
            file: file,
            line: line
        )
        return window
    }

    @discardableResult
    private func assertElement(
        _ identifier: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(
            element.waitForExistence(timeout: Self.readinessTimeout),
            "Expected element identified by \(identifier).",
            file: file,
            line: line
        )
        return element
    }

    @discardableResult
    private func assertButton(
        _ label: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let button = app.buttons[label]
        XCTAssertTrue(
            button.waitForExistence(timeout: Self.readinessTimeout),
            "Expected button named \(label).",
            file: file,
            line: line
        )
        XCTAssertTrue(
            button.isEnabled,
            "Expected \(label) to be enabled.",
            file: file,
            line: line
        )
        return button
    }

    @discardableResult
    private func assertControl(
        _ label: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let candidates = [app.radioButtons[label], app.buttons[label]]
        for candidate in candidates where candidate.waitForExistence(timeout: 0.75) {
            XCTAssertTrue(
                candidate.isEnabled,
                "Expected \(label) to be enabled.",
                file: file,
                line: line
            )
            return candidate
        }
        XCTFail("Expected control named \(label).", file: file, line: line)
        return app.descendants(matching: .any)[label]
    }

    @discardableResult
    private func assertButton(
        _ label: String,
        in element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let button = element.buttons[label]
        XCTAssertTrue(
            button.waitForExistence(timeout: Self.readinessTimeout),
            "Expected button named \(label).",
            file: file,
            line: line
        )
        XCTAssertTrue(
            button.isEnabled,
            "Expected \(label) to be enabled.",
            file: file,
            line: line
        )
        return button
    }

    private func control(
        labeled label: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        for candidate in [app.buttons[label], app.radioButtons[label]]
        where candidate.waitForExistence(timeout: 2) {
            XCTAssertTrue(candidate.isEnabled, "Expected \(label) to be enabled.", file: file, line: line)
            return candidate
        }
        XCTFail("Expected control named \(label).", file: file, line: line)
        return app.descendants(matching: .any)[label]
    }
}
