import AppKit
import XCTest

/// High-value UI contracts for Screenlogger's routed macOS surfaces.
///
/// These tests use either an empty temporary library or an explicitly gated,
/// deterministic fixture. They never start ScreenCaptureKit, mutate macOS
/// privacy grants, or read the user's Screenlogger data and preferences.
final class ScreenlogAppUITests: XCTestCase {
    private static let bundleIdentifier = "dev.screenlog.app"
    private static let routeTimeout: TimeInterval = 8

    private enum AssistantFixtureTarget: String {
        case claude
        case cursor
        case codex
        case grok
        case openclaw
    }

    private enum AssistantFixtureRouting {
        case automatic
        case askEveryTime
        case preferred(AssistantFixtureTarget)

        var persistedValue: String {
            switch self {
            case .automatic: return "automatic"
            case .askEveryTime: return "ask-every-time"
            case .preferred(let target): return "preferred:\(target.rawValue)"
            }
        }
    }

    private var app: XCUIApplication?
    private var dataDirectory: URL?
    private var preferencesSuite: String?
    private var ownsApplicationProcess = false

    override func setUpWithError() throws {
        continueAfterFailure = false

        // UI automation must never take over or terminate someone's active
        // Screenlogger session. The script performs the same guard before the
        // build starts; this also protects tests launched directly from Xcode.
        let runningProduct = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        ).contains { !$0.isTerminated }
        try XCTSkipIf(
            runningProduct,
            "Quit the running Screenlogger app before running UI regression tests."
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlogger-ui-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
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
        if ownsApplicationProcess {
            app?.terminate()
            _ = app?.wait(for: .notRunning, timeout: 4)
        }
        app = nil
        ownsApplicationProcess = false

        if let preferencesSuite {
            UserDefaults.standard.removePersistentDomain(forName: preferencesSuite)
        }
        preferencesSuite = nil

        if let dataDirectory {
            try? FileManager.default.removeItem(at: dataDirectory)
        }
        dataDirectory = nil
    }

    func testDirectLibraryRouteAndTimelineNavigation() throws {
        let app = try launch(route: "--open-library")
        assertWindow("Library", in: app)
        let searchField = assertElement(identifier: "library.search.field", in: app)
        assertElement(identifier: "navigation.library.settings", in: app)

        searchField.click()
        searchField.typeText("quarterly planning")
        clearNativeSearchField(searchField)

        let timelineButton = assertElement(identifier: "navigation.library.timeline", in: app)
        timelineButton.click()

        assertWindow("Timeline", in: app)
        assertElement(identifier: "navigation.timeline.library", in: app)
        assertElement(identifier: "navigation.timeline.settings", in: app)
        assertElement(identifier: "timeline.capture.status", in: app)
    }

    func testPlainTextSearchKeepsAdvancedSuggestionsOutOfTheWay() throws {
        let app = try launch(route: "--open-library", fixture: true)
        let library = assertWindow("Library", in: app)
        let searchField = assertElement(identifier: "library.search.field", in: app)

        searchField.click()
        searchField.typeText("navigation")

        let resultsHeader = assertElement(identifier: "library.results.count", in: app)
        let twoResults = NSPredicate(format: "value == %@", "2 results")
        expectation(for: twoResults, evaluatedWith: resultsHeader)
        waitForExpectations(timeout: Self.routeTimeout)
        let resultsWorkspace = assertElement(
            identifier: "library.results.workspace",
            in: app
        )
        let resultsFrameBeforeSuggestions = resultsWorkspace.frame
        assertElementDoesNotExist(
            identifier: "library.search.suggestions",
            in: app,
            description: "advanced suggestions over an ordinary text search"
        )

        searchField.typeText(" ")
        assertElement(identifier: "library.search.suggestions", in: app)
        XCTAssertEqual(
            resultsWorkspace.frame,
            resultsFrameBeforeSuggestions,
            "Search suggestions must float without moving or resizing Library results."
        )
        app.typeKey(.escape, modifierFlags: [])
        assertElementDoesNotExist(
            identifier: "library.search.suggestions",
            in: app,
            description: "advanced suggestions after pressing Escape"
        )
        XCTAssertTrue(library.exists, "Escape should dismiss suggestions before closing Library.")
    }

    func testMinimizedLibraryPreservesExplicitSessionFilterChoice() throws {
        let app = try launch(
            route: "--open-library",
            fixture: true,
            selectSessionAfterLoad: true
        )
        let library = assertWindow("Library", in: app)
        let sessionFilter = assertElement(identifier: "library.filter.session", in: app)
        XCTAssertEqual(sessionFilter.value as? String, "Not selected")

        app.typeKey("m", modifierFlags: .command)
        app.typeKey("1", modifierFlags: .command)

        XCTAssertTrue(library.waitForExistence(timeout: Self.routeTimeout))
        let restoredFilter = assertElement(identifier: "library.filter.session", in: app)
        XCTAssertTrue(restoredFilter.isHittable, "Command-1 should restore the minimized Library.")
        XCTAssertEqual(
            restoredFilter.value as? String,
            "Not selected",
            "Restoring a minimized Library must not silently reapply its selected-session filter."
        )
    }

    func testGlobalLibraryReopenDoesNotRestoreTimelineSessionScope() throws {
        let app = try launch(
            route: "--open-timeline",
            fixture: true,
            selectSessionAfterLoad: true
        )
        assertWindow("Timeline", in: app)

        // Command-K from Timeline is explicitly contextual and may offer the
        // selected session as the starting search scope.
        app.typeKey("k", modifierFlags: .command)
        let library = assertWindow("Library", in: app)
        let sessionFilter = assertElement(identifier: "library.filter.session", in: app)
        XCTAssertEqual(sessionFilter.value as? String, "Selected")

        // Once the user opts back into their full Library, closing and using
        // the global Show Library command must not silently undo that choice.
        sessionFilter.click()
        XCTAssertEqual(sessionFilter.value as? String, "Not selected")
        app.typeKey("w", modifierFlags: .command)
        assertElementDoesNotExist(
            library,
            description: "Library after pressing Command-W"
        )

        app.typeKey("1", modifierFlags: .command)
        assertWindow("Library", in: app)
        XCTAssertEqual(
            assertElement(identifier: "library.filter.session", in: app).value as? String,
            "Not selected"
        )
    }

    func testFindInLibrarySelectsTheExistingQueryForReplacement() throws {
        let app = try launch(route: "--open-library", fixture: true)
        let search = assertElement(identifier: "library.search.field", in: app)
        search.typeText("quarterly planning")

        app.typeKey("2", modifierFlags: .command)
        assertWindow("Timeline", in: app)
        app.typeKey("f", modifierFlags: .command)

        assertWindow("Library", in: app)
        let focusedSearch = assertElement(identifier: "library.search.field", in: app)
        focusedSearch.typeText("replacement query")
        XCTAssertEqual(
            focusedSearch.value as? String,
            "replacement query",
            "Find should select the retained query so typing starts a new search."
        )
    }

    func testSearchSuggestionsSupportArrowAndReturnCompletion() throws {
        let app = try launch(route: "--open-library", fixture: true)
        let searchField = assertElement(identifier: "library.search.field", in: app)

        searchField.click()
        pasteText("app:TextE", into: searchField)
        let suggestions = assertElement(identifier: "library.search.suggestions", in: app)

        app.typeKey(.downArrow, modifierFlags: [])
        let selected = suggestions.descendants(matching: .any)
            .matching(NSPredicate(format: "value BEGINSWITH %@", "Selected,"))
            .firstMatch
        XCTAssertTrue(
            selected.waitForExistence(timeout: Self.routeTimeout),
            "Down Arrow should visibly and accessibly select the first matching suggestion."
        )

        app.typeKey(.return, modifierFlags: [])
        assertElement(identifier: "library.search.operator.app", in: app)
        XCTAssertEqual(
            searchField.value as? String,
            "",
            "Return should present the app refinement once as a filter chip."
        )
    }

    func testCommandReturnOpensReviewedAssistantHandoff() throws {
        let app = try launch(route: "--open-library", fixture: true)
        let searchField = assertElement(identifier: "library.search.field", in: app)

        searchField.click()
        searchField.typeText("Find the design review I was reading")
        app.typeKey(.return, modifierFlags: .command)

        assertElement(identifier: "library.assistant.sheet", in: app)
        assertButton("Open Assistant Settings", in: app)
    }

    func testCommandReturnReviewsSingleReadyAssistantBeforeHandoff() throws {
        let app = try launch(
            route: "--open-library",
            fixture: true,
            assistantReady: [.codex]
        )
        let searchField = assertElement(identifier: "library.search.field", in: app)

        searchField.click()
        searchField.typeText("Find the design review I was reading")
        app.typeKey(.return, modifierFlags: .command)

        assertElement(identifier: "library.assistant.sheet", in: app)
        assertElement(identifier: "library.assistant.cancel", in: app)
        let codex = assertElement(identifier: "library.assistant.target.codex", in: app)
        XCTAssertEqual(codex.label, "Codex")
        let continueButton = assertElement(identifier: "library.assistant.continue", in: app)
        XCTAssertEqual(continueButton.label, "Open in Codex")
        XCTAssertFalse(
            app.buttons["Claude"].exists,
            "A single-assistant fixture must not inherit another provider from this Mac."
        )
    }

    func testCommandReturnAsksForProviderWhenSeveralAreReady() throws {
        let app = try launch(
            route: "--open-library",
            fixture: true,
            assistantReady: [.codex, .grok]
        )
        let searchField = assertElement(identifier: "library.search.field", in: app)

        searchField.click()
        searchField.typeText("Find the design review I was reading")
        app.typeKey(.return, modifierFlags: .command)

        assertElement(identifier: "library.assistant.sheet", in: app)
        let grok = assertElement(identifier: "library.assistant.target.grok", in: app)
        XCTAssertEqual(grok.label, "Grok Build")
        let codex = assertElement(identifier: "library.assistant.target.codex", in: app)
        XCTAssertEqual(codex.label, "Codex")
        XCTAssertFalse(
            app.buttons["Open in Codex"].exists || app.buttons["Open in Grok Build"].exists,
            "Automatic routing must ask before choosing between several ready assistants."
        )

        codex.click()
        XCTAssertTrue(codex.isSelected, "The chosen assistant must expose selected state.")
        let continueButton = assertElement(identifier: "library.assistant.continue", in: app)
        XCTAssertEqual(continueButton.label, "Open in Codex")
    }

    func testCommandReturnRecoversWhenPreferredAssistantIsUnavailable() throws {
        let app = try launch(
            route: "--open-library",
            fixture: true,
            assistantDetected: [.codex, .grok],
            assistantReady: [.codex],
            assistantRouting: .preferred(.grok)
        )
        let searchField = assertElement(identifier: "library.search.field", in: app)

        searchField.click()
        searchField.typeText("Find the design review I was reading")
        app.typeKey(.return, modifierFlags: .command)

        assertElement(identifier: "library.assistant.sheet", in: app)
        assertElement(identifier: "library.assistant.settings", in: app)
        let codex = assertElement(identifier: "library.assistant.target.codex", in: app)
        XCTAssertEqual(codex.label, "Codex")
        XCTAssertFalse(
            app.buttons["Grok Build"].exists,
            "A detected but unready preferred assistant must not be offered as a destination."
        )
        XCTAssertFalse(
            app.buttons["Open in Codex"].exists,
            "Recovery must require an explicit ready-assistant choice."
        )

        codex.click()
        let continueButton = assertElement(identifier: "library.assistant.continue", in: app)
        XCTAssertEqual(continueButton.label, "Open in Codex")
    }

    func testDirectTimelineRouteAndLibraryNavigation() throws {
        let app = try launch(route: "--open-timeline")
        assertWindow("Timeline", in: app)
        assertElement(identifier: "navigation.timeline.settings", in: app)
        assertElement(identifier: "timeline.capture.status", in: app)
        assertElement(identifier: "timeline.empty.primary-action", in: app)
        assertElement(identifier: "timeline.empty.settings", in: app)

        let libraryButton = assertElement(identifier: "navigation.timeline.library", in: app)
        libraryButton.click()

        assertWindow("Library", in: app)
        assertElement(identifier: "library.search.field", in: app)
        assertElement(identifier: "navigation.library.timeline", in: app)
    }

    func testStatusMenuProvidesPrimaryNavigationAndHelp() throws {
        let app = try launch(route: "--open-library", fixture: true)
        assertWindow("Library", in: app)

        let statusItem = app.statusItems["status-menu.button"]
        XCTAssertTrue(
            statusItem.waitForExistence(timeout: Self.routeTimeout),
            "The menu-bar item should remain an accessible way back into Screenlogger."
        )
        statusItem.click()

        let captureStatus = assertElement(identifier: "status-menu.capture-status", in: app)
        XCTAssertEqual(captureStatus.label, "Capture Off - Start Capture")
        XCTAssertEqual(assertElement(identifier: "status-menu.library", in: app).label, "Show Library")
        XCTAssertEqual(assertElement(identifier: "status-menu.timeline", in: app).label, "Show Timeline")
        XCTAssertEqual(assertElement(identifier: "status-menu.capture-once", in: app).label, "Capture Now")
        assertElement(identifier: "status-menu.permissions", in: app)
        assertElement(identifier: "status-menu.settings", in: app)
        assertElement(identifier: "status-menu.help", in: app)
        assertElement(identifier: "status-menu.about", in: app)
        assertElement(identifier: "status-menu.quit", in: app)

        assertElement(identifier: "status-menu.timeline", in: app).click()
        assertWindow("Timeline", in: app)

        statusItem.click()
        assertElement(identifier: "status-menu.help", in: app).click()
        assertWindow("Settings", in: app)
        assertElement(identifier: "settings.pane.support", in: app)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: Self.routeTimeout))
        assertElement(identifier: "settings.guide.detail.gettingStarted", in: app)
    }

    func testStatusMenuPrioritizesCaptureSetupAndReturnsToLibrary() throws {
        let app = try launch(
            route: "--open-library",
            fixture: true,
            simulatedMissingPermission: true
        )
        let library = assertWindow("Library", in: app)
        let statusItem = app.statusItems["status-menu.button"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: Self.routeTimeout))
        statusItem.click()

        let setup = assertElement(identifier: "status-menu.capture-status", in: app)
        XCTAssertEqual(setup.label, "Setup Required - Set Up...")
        XCTAssertFalse(
            app.descendants(matching: .any)["status-menu.capture-once"].exists,
            "Capture Now should not appear usable before Screen Recording is allowed."
        )
        setup.click()

        assertWindow("Permissions & Privacy", in: app)
        assertElement(identifier: "setup.keep-off", in: app).click()
        XCTAssertTrue(
            library.waitForExistence(timeout: Self.routeTimeout) && library.isHittable,
            "Closing menu-bar Setup should return to the workspace that was already open."
        )
    }

    func testCaptureStatusMeaningStaysConsistentAcrossPrimarySurfaces() throws {
        let app = try launch(route: "--open-library", fixture: true)

        let libraryStatus = assertElement(identifier: "library.capture.status", in: app)
        XCTAssertEqual(libraryStatus.label, "Start Capture")
        XCTAssertEqual(libraryStatus.value as? String, "Capture Off")
        assertElement(identifier: "navigation.library.timeline", in: app).click()

        let timelineStatus = assertElement(identifier: "timeline.capture.status", in: app)
        XCTAssertEqual(timelineStatus.label, "Start Capture")
        XCTAssertEqual(timelineStatus.value as? String, "Capture Off")
        assertElement(identifier: "navigation.timeline.settings", in: app).click()

        let sidebarStatus = assertElement(
            identifier: "settings.sidebar.capture-state",
            in: app
        )
        XCTAssertEqual(sidebarStatus.label, "Capture Off")
        sidebarStatus.click()

        let settingsStatus = assertElement(identifier: "capture.status.summary", in: app)
        XCTAssertEqual(settingsStatus.value as? String, "Capture Off")
    }

    func testMissingPermissionPrimaryActionsOpenGuidedSetup() throws {
        let app = try launch(
            route: "--open-library",
            fixture: true,
            simulatedMissingPermission: true
        )
        assertWindow("Library", in: app)
        let libraryEmptyState = assertElement(identifier: "library.state.idle", in: app)
        assertElementDoesNotExist(
            identifier: "library.results.title",
            in: app,
            description: "a redundant Search heading above the empty Library guidance"
        )
        let librarySetup = libraryEmptyState.buttons["Allow Screen Recording"]
        XCTAssertTrue(
            librarySetup.waitForExistence(timeout: Self.routeTimeout),
            "The empty Library should offer guided capture setup when permission is missing."
        )
        librarySetup.click()
        assertWindow("Permissions & Privacy", in: app)
        assertElement(identifier: "setup.open-screen-recording", in: app)

        assertElement(identifier: "setup.keep-off", in: app).click()
        let library = assertWindow("Library", in: app)
        XCTAssertTrue(library.isHittable, "Keep Capture Off should return keyboard focus to Library.")

        // Setup is a temporary detour. Reopening it from the Library toolbar
        // must not recreate the retained workspace or discard the query.
        let searchField = assertElement(identifier: "library.search.field", in: app)
        searchField.click()
        searchField.typeText("draft query")
        let captureStatus = app.buttons.matching(
            NSPredicate(format: "label == %@", "Capture status")
        ).firstMatch
        XCTAssertTrue(captureStatus.waitForExistence(timeout: Self.routeTimeout))
        captureStatus.click()
        assertWindow("Permissions & Privacy", in: app)
        assertElement(identifier: "setup.keep-off", in: app).click()
        XCTAssertEqual(
            assertElement(identifier: "library.search.field", in: app).value as? String,
            "draft query",
            "Returning from Setup should preserve the initiating Library query."
        )
        clearNativeSearchField(assertElement(identifier: "library.search.field", in: app))
        assertElement(identifier: "navigation.library.timeline", in: app).click()

        assertWindow("Timeline", in: app)
        let timelineSetup = assertElement(identifier: "timeline.empty.primary-action", in: app)
        XCTAssertEqual(timelineSetup.label, "Allow Screen Recording")
        timelineSetup.click()
        assertWindow("Permissions & Privacy", in: app)
        assertElement(identifier: "setup.open-screen-recording", in: app)
        app.typeKey(.escape, modifierFlags: [])

        let timeline = assertWindow("Timeline", in: app)
        XCTAssertTrue(timeline.isHittable, "Escape should return keyboard focus to Timeline.")
        XCTAssertEqual(
            assertElement(identifier: "timeline.empty.primary-action", in: app).label,
            "Allow Screen Recording"
        )
    }

    func testMissingAccessibilityPrimaryActionsContinueGuidedSetup() throws {
        let app = try launch(
            route: "--open-library",
            fixture: true,
            simulatedMissingAccessibilityPermission: true
        )
        assertWindow("Library", in: app)

        let librarySetup = assertElement(identifier: "library.state.idle", in: app)
            .buttons["Allow Accessibility"]
        XCTAssertTrue(
            librarySetup.waitForExistence(timeout: Self.routeTimeout),
            "The Library must not offer Start Capture while Accessibility is missing."
        )
        librarySetup.click()

        assertWindow("Permissions & Privacy", in: app)
        assertElement(identifier: "setup.open-accessibility", in: app)
        assertElementDoesNotExist(
            identifier: "setup.start-capture",
            in: app,
            description: "Start Capture before both required permissions are available"
        )
        assertElement(identifier: "setup.keep-off", in: app).click()

        assertElement(identifier: "navigation.library.timeline", in: app).click()
        assertWindow("Timeline", in: app)
        let timelineSetup = assertElement(identifier: "timeline.empty.primary-action", in: app)
        XCTAssertEqual(timelineSetup.label, "Allow Accessibility")
        timelineSetup.click()

        assertWindow("Permissions & Privacy", in: app)
        assertElement(identifier: "setup.open-accessibility", in: app)
    }

    func testLibrarySearchFailureIsScopedPrivacySafeAndRetryable() throws {
        let app = try launch(
            route: "--open-library",
            fixture: true,
            simulatedSearchIssue: true
        )
        assertWindow("Library", in: app)
        let captureStatus = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Capture status"))
            .firstMatch
        XCTAssertTrue(captureStatus.waitForExistence(timeout: Self.routeTimeout))
        let captureStatusBeforeSearch = String(describing: captureStatus.value)
        let searchField = assertElement(identifier: "library.search.field", in: app)
        searchField.click()
        searchField.typeText("quarterly planning")
        searchField.typeKey(.return, modifierFlags: [])

        assertElement(identifier: "library.state.error", in: app)
        assertElement(label: "Couldn't search your Library", in: app)
        assertElement(
            label: "Your saved history is still on this Mac. Try the search again.",
            in: app
        )
        assertElementDoesNotExist(
            identifier: "capture.issue.library",
            in: app,
            description: "a capture failure for a Library query error"
        )
        XCTAssertEqual(
            String(describing: captureStatus.value),
            captureStatusBeforeSearch,
            "A Library query error must not replace the app-wide capture status."
        )

        assertElement(identifier: "library.retrySearch", in: app).click()
        assertElement(identifier: "library.state.error", in: app)

        assertElement(identifier: "library.error.clear", in: app).click()
        assertElement(identifier: "library.state.idle", in: app)
    }

    func testCorruptLibraryShowsRecoveryInsteadOfPermissionOnboarding() throws {
        let dataDirectory = try XCTUnwrap(dataDirectory)
        try Data("not a sqlite database".utf8).write(
            to: dataDirectory.appendingPathComponent("db.sqlite3"),
            options: .atomic
        )

        let app = try launch(route: "--open-library")
        assertWindow("Library", in: app)
        assertElement(identifier: "library.startup-recovery", in: app)
        assertElement(identifier: "library.startup-recovery.retry", in: app)
        assertElement(identifier: "library.startup-recovery.reveal-library", in: app)
        assertElement(identifier: "library.startup-recovery.diagnostics", in: app)
        XCTAssertFalse(
            app.windows["Permissions & Privacy"].exists,
            "A Library failure must not be presented as permission onboarding."
        )
        assertElementDoesNotExist(
            identifier: "library.state.idle",
            in: app,
            description: "the ordinary empty Library state while bootstrap is blocked"
        )

        assertElement(identifier: "navigation.library.timeline", in: app).click()
        assertWindow("Timeline", in: app)
        assertElement(identifier: "timeline.startup-recovery", in: app)
        assertElement(identifier: "timeline.startup-recovery.retry", in: app)
        assertElementDoesNotExist(
            identifier: "timeline.empty.primary-action",
            in: app,
            description: "permission or capture onboarding while the Library is unavailable"
        )

        let status = assertElement(identifier: "timeline.capture.status", in: app)
        XCTAssertEqual(status.label, "Capture Unavailable")
        XCTAssertEqual(status.value as? String, "Library Unavailable")

        assertElement(identifier: "navigation.timeline.settings", in: app).click()
        assertWindow("Settings", in: app)
        assertElement(identifier: "settings.sidebar.capture", in: app).click()
        let captureStatus = assertElement(identifier: "capture.status.summary", in: app)
        XCTAssertEqual(captureStatus.value as? String, "Library Unavailable")
        assertElement(identifier: "capture.library.retry", in: app)
        let captureOnce = assertElement(identifier: "capture.manual.start", in: app)
        XCTAssertFalse(captureOnce.isEnabled)
    }

    func testTimelineCommandKFocusesSearchAndEscapeReturnsToTimeline() throws {
        let app = try launch(route: "--open-timeline")
        let timelineWindow = assertWindow("Timeline", in: app)

        app.typeKey("k", modifierFlags: .command)

        let libraryWindow = assertWindow("Library", in: app)
        let searchField = assertElement(identifier: "library.search.field", in: app)

        // Command-K promises focus, so the field must accept typing without an
        // additional click.
        searchField.typeText("keyboard navigation")
        XCTAssertEqual(searchField.value as? String, "keyboard navigation")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(searchField.value as? String, "")
        app.typeKey(.escape, modifierFlags: [])
        assertElementDoesNotExist(
            libraryWindow,
            description: "Library window after pressing Escape"
        )
        XCTAssertTrue(timelineWindow.exists, "Timeline should remain open after dismissing Library.")

        // Reopening an ordered-out Library must reuse it and re-arm focus.
        app.typeKey("k", modifierFlags: .command)
        assertWindow("Library", in: app)
        let reopenedSearch = assertElement(identifier: "library.search.field", in: app)
        XCTAssertEqual(reopenedSearch.value as? String, "")
        reopenedSearch.typeText("restored")
        XCTAssertEqual(reopenedSearch.value as? String, "restored")

        // The red-close / Command-W path uses the same retained native window,
        // preserves the query, and can still restore keyboard focus.
        app.typeKey("w", modifierFlags: .command)
        assertElementDoesNotExist(
            app.windows["Library"],
            description: "Library window after pressing Command-W"
        )
        app.typeKey("k", modifierFlags: .command)
        assertWindow("Library", in: app)
        let reopenedAfterClose = assertElement(identifier: "library.search.field", in: app)
        XCTAssertEqual(reopenedAfterClose.value as? String, "restored")
        reopenedAfterClose.typeText(" again")
        XCTAssertEqual(
            reopenedAfterClose.value as? String,
            "restored again"
        )
    }

    func testCommandKOpensLibraryFromSetupAndFocusesSearch() throws {
        let app = try launch(route: "--open-setup", fixture: true)
        assertWindow("Permissions & Privacy", in: app)

        // Command-K is an app menu command, so it must work even when Timeline
        // and its local shortcut monitor have never been created.
        app.typeKey("k", modifierFlags: .command)

        assertWindow("Library", in: app)
        let searchField = assertElement(identifier: "library.search.field", in: app)
        searchField.typeText("menu navigation")
        XCTAssertEqual(searchField.value as? String, "menu navigation")
    }

    func testPrimaryWindowShortcutsRouteFromEveryFocusedSurface() throws {
        let app = try launch(route: "--open-library", fixture: true)
        let library = assertWindow("Library", in: app)

        app.typeKey("2", modifierFlags: .command)
        let timeline = assertWindow("Timeline", in: app)
        XCTAssertTrue(timeline.isHittable, "Command-2 should focus Timeline.")

        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(library.isHittable, "Command-1 should focus Library.")
        let search = assertElement(identifier: "library.search.field", in: app)
        search.typeText("shortcut route")
        XCTAssertEqual(search.value as? String, "shortcut route")

        app.typeKey(",", modifierFlags: .command)
        let settings = assertWindow("Settings", in: app)
        XCTAssertTrue(settings.isHittable, "Command-comma should focus Settings.")

        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(
            timeline.isHittable,
            "Primary destination shortcuts should still work while Settings is focused."
        )
    }

    func testKeyboardShortcutEditorRejectsConflictsAndAppliesAReplacement() throws {
        let app = try launch(route: "--open-library", fixture: true)
        assertElement(identifier: "navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)
        assertElement(identifier: "settings.sidebar.shortcuts", in: app).click()
        assertElement(identifier: "settings.shortcuts", in: app)

        let recorder = assertElement(
            identifier: "settings.shortcuts.navigation.timeline.recorder",
            in: app
        )
        recorder.click()
        app.typeKey("1", modifierFlags: .command)
        assertElement(
            identifier: "settings.shortcuts.navigation.timeline.feedback",
            in: app
        )

        // Keep recording after rejected input, then apply a non-conflicting
        // replacement and exercise it from a different focused surface.
        app.typeKey("t", modifierFlags: [.control, .option])
        assertElement(identifier: "navigation.settings.library", in: app).click()
        assertWindow("Library", in: app)

        app.typeKey("t", modifierFlags: [.control, .option])
        assertWindow("Timeline", in: app)
    }

    func testSettingsSidebarAndPrivacyLinksNavigateToRealPanes() throws {
        let app = try launch(route: "--open-library")
        assertElement(identifier: "navigation.library.settings", in: app).click()

        assertWindow("Settings", in: app)
        assertElement(identifier: "settings.pane.general", in: app)
        let heading = assertElement(
            identifier: "settings.pane.general.heading",
            in: app
        )
        XCTAssertEqual(heading.label, "General")
        XCTAssertEqual(heading.value as? String, "Startup and app behavior")
        assertElement(identifier: "navigation.settings.library", in: app)
        assertElement(identifier: "navigation.settings.timeline", in: app)

        let privacy = assertElement(identifier: "settings.sidebar.privacy", in: app)
        privacy.click()

        assertElement(identifier: "settings.pane.privacy", in: app)
        assertButton("Capture Settings...", in: app)
        assertButton("Manage Exclusions...", in: app)
        assertButton("Storage Settings...", in: app)

        assertButton("Capture Settings...", in: app).click()
        assertElement(identifier: "settings.pane.capture", in: app)
        let captureDestination = assertElement(
            identifier: "settings.destination.capture-timing",
            in: app
        )
        XCTAssertEqual(captureDestination.label, "Capture timing")
        let captureInterval = assertElement(identifier: "capture.interval.slider", in: app)
        XCTAssertTrue(
            captureInterval.isHittable,
            "A cross-pane route should scroll the requested Capture control into view."
        )

        privacy.click()
        assertElement(identifier: "settings.pane.privacy", in: app)
        assertButton("Manage Exclusions...", in: app).click()
        assertElement(identifier: "settings.pane.exclusions", in: app)
        let exclusionsDestination = assertElement(
            identifier: "settings.destination.exclusions-applications",
            in: app
        )
        XCTAssertEqual(exclusionsDestination.label, "Excluded applications")
        let applicationSearch = assertElement(identifier: "exclusions.applications.search", in: app)
        XCTAssertTrue(
            applicationSearch.isHittable,
            "An exact Exclusions route should select Applications and keep its input reachable."
        )
    }

    func testSettingsSearchOpensTheWebsiteExclusionsFlow() throws {
        let app = try launch(route: "--open-library")
        assertElement(identifier: "navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)

        let search = app.searchFields["Search Settings"]
        XCTAssertTrue(search.waitForExistence(timeout: Self.routeTimeout))
        search.click()
        search.typeText("Excluded websites")
        assertElement(
            identifier: "settings.search-result.exclusions-websites",
            in: app
        ).click()

        assertElement(identifier: "settings.pane.exclusions", in: app)
        let destination = assertElement(
            identifier: "settings.destination.exclusions-websites",
            in: app
        )
        XCTAssertEqual(destination.label, "Excluded websites")
        XCTAssertTrue(
            assertElement(identifier: "exclusions.websites.search", in: app).isHittable,
            "A Settings search route should select Websites and keep its input reachable."
        )
    }

    func testCaptureDisplayCoverageIsSearchableAndSelectable() throws {
        let app = try launch(route: "--open-library", fixture: true)
        assertElement(identifier: "navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)

        let search = app.searchFields["Search Settings"]
        XCTAssertTrue(search.waitForExistence(timeout: Self.routeTimeout))
        search.click()
        search.typeText("multiple monitors")
        assertElement(
            identifier: "settings.search-result.capture-displays",
            in: app
        ).click()

        let destination = assertElement(
            identifier: "settings.destination.capture-displays",
            in: app
        )
        XCTAssertEqual(destination.label, "Capture displays")

        let picker = assertElement(identifier: "capture.displays.picker", in: app)
        XCTAssertTrue(picker.isHittable)
        XCTAssertEqual(picker.value as? String, "Active display")

        let allDisplays = assertControl(label: "All displays", in: app)
        allDisplays.click()
        XCTAssertEqual(picker.value as? String, "All displays")
        assertElement(identifier: "capture.displays.privacy-note", in: app)
    }

    func testSettingsSearchReturnOpensTheFirstResultAndEscapeClearsTheQuery() throws {
        let app = try launch(route: "--open-library")
        assertElement(identifier: "navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)

        let search = app.searchFields["Search Settings"]
        XCTAssertTrue(search.waitForExistence(timeout: Self.routeTimeout))
        search.click()
        search.typeText("Excluded websites")
        search.typeKey(.return, modifierFlags: [])

        assertElement(identifier: "settings.pane.exclusions", in: app)
        assertElement(identifier: "settings.destination.exclusions-websites", in: app)
        XCTAssertEqual(search.value as? String, "Excluded websites")

        search.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(search.value as? String, "")
        assertElement(identifier: "settings.sidebar.general", in: app)
        assertElement(identifier: "settings.sidebar.exclusions", in: app)
    }

    func testSettingsCanReturnToPrimarySurfaces() throws {
        let app = try launch(route: "--open-library")
        assertElement(identifier: "navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)

        assertElement(identifier: "navigation.settings.timeline", in: app).click()
        assertWindow("Timeline", in: app)

        assertElement(identifier: "navigation.timeline.library", in: app).click()
        assertWindow("Library", in: app)
        assertElement(identifier: "library.search.field", in: app)
    }

    func testSettingsReopensAfterCommandWAndPreservesItsPane() throws {
        let app = try launch(route: "--open-library", fixture: true)
        assertElement(identifier: "navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)
        assertElement(identifier: "settings.sidebar.support", in: app).click()
        assertElement(identifier: "settings.pane.support", in: app)

        app.typeKey("w", modifierFlags: .command)
        assertElementDoesNotExist(
            app.windows["Settings"],
            description: "Settings window after pressing Command-W"
        )

        app.typeKey(",", modifierFlags: .command)
        assertWindow("Settings", in: app)
        assertElement(identifier: "settings.pane.support", in: app)
        XCTAssertEqual(
            app.windows.matching(identifier: "Settings").count,
            1,
            "Settings should reopen as one retained native window."
        )
    }

    func testSettingsSearchFindsSupportAndDiagnostics() throws {
        let app = try launch(route: "--open-library")
        assertElement(identifier: "navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)

        let search = app.searchFields["Search Settings"]
        XCTAssertTrue(
            search.waitForExistence(timeout: Self.routeTimeout),
            "Expected native Settings search in the sidebar."
        )
        search.click()
        search.typeText("diagnostics")

        XCTAssertEqual(search.value as? String, "diagnostics")
        assertElement(identifier: "settings.pane.general", in: app)
        assertElement(identifier: "settings.search-result.support-diagnostics", in: app).click()
        assertElement(identifier: "settings.pane.support", in: app)
        assertElement(identifier: "settings.diagnostics.contents", in: app)
        assertElement(identifier: "settings.diagnostics.export", in: app)
        assertButton("Review...", in: app).click()
        assertElement(identifier: "settings.pane.privacy", in: app)
    }

    func testSettingsSearchKeepsSelectionVisibleAndExplainsNoMatches() throws {
        let app = try launch(route: "--open-library")
        assertElement(identifier: "navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)

        let search = app.searchFields["Search Settings"]
        XCTAssertTrue(
            search.waitForExistence(timeout: Self.routeTimeout),
            "Expected native Settings search in the sidebar."
        )
        search.click()
        search.typeText("local")

        assertElement(identifier: "settings.search.summary", in: app)
        assertElement(identifier: "settings.search-result.privacy-local-data", in: app)
        assertElement(identifier: "settings.search-result.section.storage", in: app)
        assertElement(identifier: "settings.search-result.integrations-local-tools", in: app)
        assertElement(identifier: "settings.sidebar.capture-state", in: app)
        assertElement(identifier: "settings.pane.general", in: app)
        XCTAssertEqual(search.value as? String, "local")

        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        search.typeText("unfindable-setting-zz")
        assertElement(identifier: "settings.search.empty", in: app)
        assertElement(identifier: "navigation.settings.library", in: app)

        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        assertElement(identifier: "settings.pane.general", in: app)
    }

    func testSettingsUseProgressiveDisclosureForToolsStorageAndSupport() throws {
        let app = try launch(route: "--open-library", fixture: true)
        assertElement(identifier: "navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)

        let captureState = assertElement(identifier: "settings.sidebar.capture-state", in: app)
        XCTAssertEqual(captureState.label, "Capture Off")
        XCTAssertEqual(captureState.value as? String, "Review Capture settings")
        captureState.click()
        assertElement(identifier: "settings.pane.capture", in: app)

        let settingsSearch = app.searchFields["Search Settings"]
        XCTAssertTrue(settingsSearch.waitForExistence(timeout: Self.routeTimeout))
        settingsSearch.click()
        settingsSearch.typeText("terminal command")
        XCTAssertEqual(settingsSearch.value as? String, "terminal command")
        assertElement(identifier: "settings.pane.capture", in: app)
        assertElement(
            identifier: "settings.search-result.integrations-local-tools",
            in: app
        ).click()
        assertElement(identifier: "settings.pane.integrations", in: app)
        assertElement(
            identifier: "settings.destination.integrations-local-tools",
            in: app
        )
        assertElement(identifier: "settings.integrations.readiness", in: app)
        assertElement(
            identifier: "settings.integrations.assistant-readiness",
            in: app
        )
        assertControl(label: "How local tool access works", in: app).click()
        assertElement(
            label: "Screenlogger handles searches inside the app. Terminal and assistants connect "
                + "through a private local connection only while Screenlogger is running.",
            in: app
        )

        // Integrations is already selected; changing to an assistant search
        // must still issue a distinct anchor/focus event within the same pane.
        settingsSearch.click()
        settingsSearch.typeKey("a", modifierFlags: .command)
        settingsSearch.typeKey(.delete, modifierFlags: [])
        settingsSearch.typeText("Claude")
        XCTAssertEqual(settingsSearch.value as? String, "Claude")
        assertElement(
            identifier: "settings.search-result.integrations-assistant-connections",
            in: app
        ).click()
        assertElement(
            identifier: "settings.destination.integrations-assistant-connections",
            in: app
        )

        settingsSearch.click()
        settingsSearch.typeKey("a", modifierFlags: .command)
        settingsSearch.typeKey(.delete, modifierFlags: [])
        assertElement(identifier: "settings.sidebar.appearance", in: app).click()
        assertElement(identifier: "settings.appearance.theme", in: app)
        assertElement(identifier: "settings.appearance.timeline-controls", in: app)
        assertElement(identifier: "settings.appearance.timeline.detected-text", in: app)

        assertElement(identifier: "settings.sidebar.storage", in: app).click()
        assertElement(identifier: "settings.storage.summary", in: app)
        assertElement(identifier: "settings.storage.export", in: app)
        assertElement(identifier: "settings.storage.compress-now", in: app)
        assertElementDoesNotExist(
            identifier: "settings.storage.delete-history",
            in: app,
            description: "destructive storage actions before Advanced storage actions is expanded"
        )
        assertControl(label: "Advanced storage actions", in: app).click()
        assertElement(identifier: "settings.storage.delete-history", in: app)

        assertElement(identifier: "settings.sidebar.support", in: app).click()
        assertControl(label: "Review bundle contents", in: app).click()
        assertElement(label: "Never included", in: app)

        assertElement(identifier: "settings.support.user-guide", in: app).click()
        let guide = app.sheets.firstMatch
        XCTAssertTrue(guide.waitForExistence(timeout: Self.routeTimeout))
        assertElement(identifier: "settings.guide.offline", in: app)
        assertElement(identifier: "settings.guide.detail.gettingStarted", in: app)
        assertElement(identifier: "settings.guide.action.gettingStarted", in: app)
        assertElement(identifier: "settings.guide.topic.timeline", in: app).click()
        assertElement(identifier: "settings.guide.detail.timeline", in: app)
        assertElement(identifier: "settings.guide.done", in: app).click()
        XCTAssertTrue(
            guide.waitForNonExistence(timeout: Self.routeTimeout),
            "The offline User Guide should close after choosing Done."
        )
    }

    func testSettingsCaptureStateRoutesMissingPermissionToSetup() throws {
        let app = try launch(
            route: "--open-library",
            fixture: true,
            simulatedMissingPermission: true
        )
        assertElement(identifier: "navigation.library.settings", in: app).click()
        let settings = assertWindow("Settings", in: app)
        assertElement(identifier: "settings.sidebar.privacy", in: app).click()
        assertElement(identifier: "settings.pane.privacy", in: app)

        let captureState = assertElement(identifier: "settings.sidebar.capture-state", in: app)
        XCTAssertEqual(captureState.label, "Setup Required")
        XCTAssertEqual(captureState.value as? String, "Allow Screen Recording")
        captureState.click()

        assertWindow("Permissions & Privacy", in: app)
        assertElement(identifier: "setup.open-screen-recording", in: app)
        assertElement(identifier: "setup.keep-off", in: app).click()

        XCTAssertTrue(settings.isHittable, "Cancelling Setup should return keyboard focus to Settings.")
        assertElement(identifier: "settings.pane.privacy", in: app)
        XCTAssertFalse(
            app.windows["Timeline"].exists,
            "Cancelling Settings-owned Setup must not open Timeline."
        )
    }

    func testAccessibilitySettingsRowTargetsAccessibilityWhenBothPermissionsAreMissing() throws {
        let app = try launch(
            route: "--open-library",
            fixture: true,
            simulatedMissingPermission: true
        )
        assertElement(identifier: "navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)
        assertElement(identifier: "settings.sidebar.privacy", in: app).click()

        let accessibilityRow = assertElement(
            identifier: "privacy.permission.accessibility",
            in: app
        )
        let reviewAccessibility = accessibilityRow.buttons.matching(
            NSPredicate(format: "label == %@", "Review Accessibility setup")
        ).firstMatch
        XCTAssertTrue(
            reviewAccessibility.waitForExistence(timeout: Self.routeTimeout),
            "The Accessibility row should expose its own setup route."
        )
        reviewAccessibility.click()

        assertWindow("Permissions & Privacy", in: app)
        assertElement(identifier: "setup.open-accessibility", in: app)
        assertElementDoesNotExist(
            identifier: "setup.open-screen-recording",
            in: app,
            description: "the generic Screen Recording route after selecting Accessibility"
        )
        XCTAssertEqual(
            assertElement(identifier: "setup.progress.permission", in: app).value as? String,
            "Not started"
        )
        XCTAssertEqual(
            assertElement(identifier: "setup.progress.accessibility", in: app).value as? String,
            "Current step"
        )
        assertElementDoesNotExist(
            identifier: "setup.start-capture",
            in: app,
            description: "Start Capture before both required permissions are available"
        )
    }

    func testStartingCaptureFromSettingsReturnsToRetainedGuide() throws {
        let app = try launch(route: "--open-library", fixture: true)
        assertElement(identifier: "navigation.library.settings", in: app).click()
        let settings = assertWindow("Settings", in: app)
        assertElement(identifier: "settings.sidebar.support", in: app).click()
        assertElement(identifier: "settings.support.user-guide", in: app).click()
        let guide = app.sheets.firstMatch
        XCTAssertTrue(guide.waitForExistence(timeout: Self.routeTimeout))
        assertElement(identifier: "settings.guide.detail.gettingStarted", in: app)
        assertElement(identifier: "settings.guide.action.gettingStarted", in: app).click()

        assertWindow("Permissions & Privacy", in: app)
        let guidance = assertElement(identifier: "setup.return-guidance", in: app)
        XCTAssertTrue(
            guidance.label.contains("Settings"),
            "Setup should explain where its primary action returns."
        )
        assertElement(identifier: "setup.start-capture", in: app).click()

        XCTAssertTrue(settings.isHittable, "Starting capture should return keyboard focus to Settings.")
        XCTAssertTrue(
            guide.exists,
            "Returning from Setup should preserve the initiating Settings sheet and navigation state."
        )
        XCTAssertFalse(
            app.windows["Timeline"].exists,
            "Settings-owned Setup should not redirect a successful start to Timeline."
        )
    }

    func testSettingsCaptureStateRoutesFailureToCaptureRecovery() throws {
        let app = try launch(
            route: "--open-library",
            fixture: true,
            simulatedCaptureIssue: true
        )
        assertElement(identifier: "navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)

        let captureState = assertElement(identifier: "settings.sidebar.capture-state", in: app)
        XCTAssertEqual(captureState.label, "Capture Couldn't Start")
        XCTAssertEqual(captureState.value as? String, "Review Capture settings")
        captureState.click()

        assertElement(identifier: "settings.pane.capture", in: app)
        assertElement(identifier: "capture.issue.settings", in: app)
    }

    func testOpenAtLoginFailureKeepsSwitchOffAndOffersRecovery() throws {
        let app = try launch(
            route: "--open-library",
            fixture: true,
            simulatedLoginItemIssue: true
        )
        assertElement(identifier: "navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)
        assertElement(identifier: "settings.pane.general", in: app)

        let toggle = assertElement(
            identifier: "settings.general.open-at-login.toggle",
            in: app
        )
        toggle.click()

        XCTAssertEqual(
            String(describing: toggle.value ?? ""),
            "0",
            "A rejected registration must leave Open at Login visibly off."
        )
        assertElement(identifier: "settings.general.open-at-login.issue", in: app)
        let retry = assertElement(
            identifier: "settings.general.open-at-login.retry",
            in: app
        )
        XCTAssertEqual(retry.label, "Try Again")
        assertElement(
            identifier: "settings.general.open-at-login.system-settings",
            in: app
        )

        retry.click()
        assertElement(identifier: "settings.general.open-at-login.issue", in: app)
        XCTAssertEqual(
            String(describing: toggle.value ?? ""),
            "0",
            "Retrying a rejected registration must not imply success."
        )
    }

    func testOpenAtLoginApprovalCanBeExplicitlyKeptOff() throws {
        let app = try launch(
            route: "--open-library",
            fixture: true,
            simulatedLoginItemApproval: true
        )
        assertElement(identifier: "navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)

        let toggle = assertElement(
            identifier: "settings.general.open-at-login.toggle",
            in: app
        )
        XCTAssertEqual(String(describing: toggle.value ?? ""), "0")
        assertElement(identifier: "settings.general.open-at-login.issue", in: app)
        assertElement(
            identifier: "settings.general.open-at-login.system-settings",
            in: app
        )

        assertElement(identifier: "settings.general.open-at-login.keep-off", in: app).click()
        assertElementDoesNotExist(
            identifier: "settings.general.open-at-login.issue",
            in: app,
            description: "the pending Login Items approval after choosing Keep Off"
        )
        XCTAssertEqual(String(describing: toggle.value ?? ""), "0")
    }

    func testDirectSetupRouteShowsPermissionChoices() throws {
        let app = try launch(
            route: "--open-setup",
            fixture: true,
            simulatedMissingPermission: true
        )
        assertWindow("Permissions & Privacy", in: app)
        let progress = assertElement(identifier: "setup.progress", in: app)
        assertElement(identifier: "setup.privacy-summary", in: app).click()
        assertElement(identifier: "setup.privacy.local", in: app)
        assertElement(identifier: "setup.privacy.no-sensors", in: app)
        assertElement(identifier: "setup.privacy.control", in: app)
        assertElement(identifier: "setup.permission.screen-recording", in: app)
        assertElement(identifier: "setup.permission.accessibility", in: app)
        assertElement(identifier: "setup.return-guidance", in: app)
        XCTAssertEqual(progress.value as? String, "Step 1 of 3")
        XCTAssertEqual(
            assertElement(identifier: "setup.progress.permission", in: app).value as? String,
            "Current step"
        )
        XCTAssertEqual(
            assertElement(identifier: "setup.progress.accessibility", in: app).value as? String,
            "Not started"
        )
        XCTAssertEqual(
            assertElement(identifier: "setup.progress.capture", in: app).value as? String,
            "Not started"
        )
        assertElement(identifier: "setup.next-action", in: app)
        assertElement(identifier: "setup.open-screen-recording", in: app)
        assertElementDoesNotExist(
            identifier: "setup.refresh",
            in: app,
            description: "a redundant permission refresh before System Settings has opened"
        )
    }

    func testConfiguredSetupOffersCaptureChoiceAndStartsIntoTimeline() throws {
        let app = try launch(route: "--open-setup", fixture: true)
        assertWindow("Permissions & Privacy", in: app)
        let progress = assertElement(identifier: "setup.progress", in: app)
        XCTAssertEqual(progress.value as? String, "Step 3 of 3")
        XCTAssertEqual(
            assertElement(identifier: "setup.progress.permission", in: app).value as? String,
            "Complete"
        )
        XCTAssertEqual(
            assertElement(identifier: "setup.progress.accessibility", in: app).value as? String,
            "Complete"
        )
        XCTAssertEqual(
            assertElement(identifier: "setup.progress.capture", in: app).value as? String,
            "Current step"
        )
        assertElement(identifier: "setup.privacy-summary", in: app)
        let state = assertElement(identifier: "setup.current-state", in: app)
        XCTAssertEqual(state.label, "Ready to start")
        XCTAssertTrue(
            (state.value as? String ?? "").contains("will not start until you choose Start Capture")
        )
        assertElementDoesNotExist(
            identifier: "setup.next-action",
            in: app,
            description: "duplicate setup instructions after the required permission is already allowed"
        )
        assertElement(identifier: "setup.return-guidance", in: app)
        assertElement(identifier: "setup.keep-off", in: app)
        assertElement(identifier: "setup.start-capture", in: app)
        app.typeKey(.return, modifierFlags: [])

        assertWindow("Timeline", in: app)
        let captureStatus = assertElement(identifier: "timeline.capture.status", in: app)
        let capturing = NSPredicate(format: "value == %@", "Capture On")
        expectation(for: capturing, evaluatedWith: captureStatus)
        waitForExpectations(timeout: Self.routeTimeout)
    }

    func testCaptureSettingsLeadWithStateAndLocalProcessing() throws {
        let app = try launch(route: "--open-library", fixture: true)
        assertElement(identifier: "navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)
        assertElement(identifier: "settings.sidebar.capture", in: app).click()

        assertElement(identifier: "capture.status.overview", in: app)
        let status = assertElement(identifier: "capture.status.summary", in: app)
        XCTAssertEqual(status.value as? String, "Capture Off")
        assertElement(identifier: "capture.status.local-processing", in: app)
        assertElement(identifier: "capture.manual.card", in: app)
        assertElement(identifier: "capture.manual.start", in: app)
    }

    func testConfiguredSetupCanKeepCaptureOff() throws {
        let app = try launch(route: "--open-setup", fixture: true)
        let setupWindow = assertWindow("Permissions & Privacy", in: app)
        assertElement(identifier: "setup.keep-off", in: app).click()

        assertElementDoesNotExist(
            setupWindow,
            description: "Setup after choosing to keep capture off"
        )
        XCTAssertFalse(
            app.windows["Timeline"].exists,
            "Keeping capture off must not open Timeline or start a capture flow."
        )
    }

    func testConfiguredSetupEscapeKeepsCaptureOff() throws {
        let app = try launch(route: "--open-setup", fixture: true)
        let setupWindow = assertWindow("Permissions & Privacy", in: app)
        assertElement(identifier: "setup.keep-off", in: app)

        app.typeKey(.escape, modifierFlags: [])

        assertElementDoesNotExist(
            setupWindow,
            description: "Setup after choosing Keep Capture Off with Escape"
        )
        XCTAssertFalse(
            app.windows["Timeline"].exists,
            "Escape must use the explicit Keep Capture Off path rather than starting capture."
        )
    }

    func testCaptureStatusStartsFixtureCaptureWithoutScreenCaptureKit() throws {
        let app = try launch(route: "--open-timeline", fixture: true)
        assertWindow("Timeline", in: app)

        let captureStatus = app.buttons["timeline.capture.status"]
        XCTAssertTrue(captureStatus.waitForExistence(timeout: Self.routeTimeout))
        XCTAssertEqual(captureStatus.label, "Start Capture")
        let captureOff = NSPredicate(format: "value == %@", "Capture Off")
        expectation(for: captureOff, evaluatedWith: captureStatus)
        waitForExpectations(timeout: Self.routeTimeout)
        captureStatus.click()

        let updatedStatus = app.descendants(matching: .any)["timeline.capture.status"]
        let capturing = NSPredicate(format: "value == %@", "Capture On")
        expectation(for: capturing, evaluatedWith: updatedStatus)
        waitForExpectations(timeout: Self.routeTimeout)
        XCTAssertEqual(updatedStatus.label, "Stop Capture")
    }

    func testTimelineControlsAndUnreadablePreviewOfferClearRecovery() throws {
        let app = try launch(
            route: "--open-timeline",
            fixture: true,
            simulatedUnreadablePreview: true
        )
        assertWindow("Timeline", in: app)

        assertElement(identifier: "timeline.day.choose", in: app)
        let timelineNavigation = assertElement(identifier: "timeline.navigation", in: app)
        let navigationValue = timelineNavigation.value as? String ?? ""
        XCTAssertTrue(navigationValue.contains("TextEdit"))
        XCTAssertTrue(navigationValue.contains("moment 8 of 8"))
        let scrubContext = assertElement(identifier: "timeline.navigation.context", in: app)
        XCTAssertEqual(scrubContext.label, "Selected moment")
        XCTAssertTrue((scrubContext.value as? String ?? "").contains("TextEdit"))
        assertElement(identifier: "timeline.day.previous", in: app)
        assertElement(identifier: "timeline.day.next", in: app)
        let range = assertElement(identifier: "timeline.navigation.range", in: app)
        XCTAssertEqual(range.label, "Timeline range")
        XCTAssertFalse((range.value as? String ?? "").isEmpty)
        let playback = assertElement(identifier: "timeline.playback.toggle", in: app)
        XCTAssertEqual(playback.label, "Play through moments")
        assertElement(identifier: "timeline.segment.previous", in: app)
        assertElement(identifier: "timeline.segment.next", in: app)
        assertElement(identifier: "timeline.zoom.reset", in: app)
        let momentActions = assertElement(identifier: "timeline.moment.actions", in: app)
        let liveText = assertElement(identifier: "timeline.live-text", in: app)
        XCTAssertTrue(
            ["Shown", "Hidden"].contains(liveText.value as? String ?? ""),
            "Detected text control should expose its state to VoiceOver."
        )

        momentActions.click()
        let copyImage = assertElement(identifier: "timeline.moment.actions.copy-image", in: app)
        XCTAssertFalse(
            copyImage.isEnabled,
            "An unreadable preview must not offer a copy action that cannot succeed."
        )
        let copyText = assertElement(identifier: "timeline.moment.actions.copy-text", in: app)
        XCTAssertTrue(copyText.isEnabled)
        copyText.click()
        assertElement(identifier: "timeline.notice", in: app)
        let noticeMessage = assertElement(identifier: "timeline.notice.message", in: app)
        XCTAssertEqual(noticeMessage.value as? String, "Text copied")

        assertElement(identifier: "timeline.preview.issue", in: app)
        assertElementDoesNotExist(
            identifier: "timeline.preview.unavailable",
            in: app,
            description: "the intentional media-retention state for an unreadable preview"
        )
        let retry = assertElement(identifier: "timeline.preview.retry", in: app)
        XCTAssertEqual(retry.label, "Try Again")
        retry.click()

        // The deterministic fixture remains intentionally unreadable. A retry
        // must return to the same honest, recoverable state instead of claiming
        // that retention deliberately removed the media.
        assertElement(identifier: "timeline.preview.retry", in: app)
        assertElementDoesNotExist(
            identifier: "timeline.preview.unavailable",
            in: app,
            description: "the intentional media-retention state after retrying unreadable media"
        )
    }

    func testTimelineGroupsMultipleDisplaysIntoOneNavigableMoment() throws {
        let app = try launch(
            route: "--open-timeline",
            fixture: true,
            multipleDisplays: true
        )
        assertWindow("Timeline", in: app)

        assertElement(identifier: "timeline.display.switcher", in: app)
        let picker = assertElement(identifier: "timeline.display.picker", in: app)
        XCTAssertEqual(picker.value as? String, "Display 2")
        let navigationValue =
            assertElement(identifier: "timeline.navigation.position", in: app).value as? String ?? ""
        XCTAssertTrue(
            navigationValue.contains("moment 8 of 8"),
            "Unexpected Timeline navigation value: \(navigationValue)"
        )
        assertElement(identifier: "timeline.moment", in: app)

        assertControl(label: "Main Display", in: app).click()
        XCTAssertEqual(picker.value as? String, "Main Display")

        assertControl(label: "Display 2", in: app).click()
        assertElement(identifier: "timeline.playback.previous", in: app).click()
        assertElementDoesNotExist(
            identifier: "timeline.display.switcher",
            in: app,
            description: "display switcher on a single-display moment"
        )
        assertElement(identifier: "timeline.playback.previous", in: app).click()
        XCTAssertEqual(
            assertElement(identifier: "timeline.display.picker", in: app).value as? String,
            "Display 2"
        )
        assertElement(identifier: "timeline.playback.next", in: app).click()
        assertElementDoesNotExist(
            identifier: "timeline.display.switcher",
            in: app,
            description: "display switcher after returning to a single-display moment"
        )
        assertElement(identifier: "timeline.playback.next", in: app).click()
        XCTAssertEqual(
            assertElement(identifier: "timeline.display.picker", in: app).value as? String,
            "Display 2"
        )
    }

    func testCaptureFailureOffersScopedRetryAndClearsAfterRecovery() throws {
        let app = try launch(
            route: "--open-timeline",
            fixture: true,
            simulatedCaptureIssue: true
        )
        assertWindow("Timeline", in: app)
        assertElement(identifier: "capture.issue.timeline", in: app)

        assertElement(identifier: "capture.issue.timeline.retry", in: app).click()

        assertElementDoesNotExist(
            identifier: "capture.issue.timeline",
            in: app,
            description: "capture issue after a successful retry"
        )
        let captureStatus = assertElement(identifier: "timeline.capture.status", in: app)
        let capturing = NSPredicate(format: "value == %@", "Capture On")
        expectation(for: capturing, evaluatedWith: captureStatus)
        waitForExpectations(timeout: Self.routeTimeout)
    }

    func testFixtureSearchResultOpensInTimeline() throws {
        let app = try launch(route: "--open-library", fixture: true)
        assertElement(identifier: "library.location", in: app)
        let searchField = assertElement(identifier: "library.search.field", in: app)

        searchField.click()
        searchField.typeText("quarterly planning")
        searchField.typeKey(.return, modifierFlags: [])

        let result = assertElement(identifier: "library.result.8", in: app)
        let resultsHeader = assertElement(identifier: "library.results.count", in: app)
        XCTAssertEqual(resultsHeader.value as? String, "1 result")
        assertElement(identifier: "library.workspace.expanded", in: app)
        let filtersPane = assertElement(identifier: "library.filters.pane", in: app)
        let resultsPane = assertElement(identifier: "library.results.workspace", in: app)
        assertElement(identifier: "library.inspector.pane", in: app)
        assertElement(identifier: "library.result.inspector.selection.8", in: app)
        let inspectorPane = assertElement(identifier: "library.inspector.pane", in: app)
        XCTAssertLessThanOrEqual(
            filtersPane.frame.maxX,
            resultsPane.frame.minX + 1,
            "The native filter pane must not cover Library results."
        )
        XCTAssertLessThanOrEqual(
            resultsPane.frame.maxX,
            inspectorPane.frame.minX + 1,
            "The native preview pane must not cover Library results."
        )

        let previewToggle = assertElement(identifier: "library.result.preview.toggle", in: app)
        XCTAssertEqual(previewToggle.value as? String, "Shown")
        previewToggle.click()
        assertElementDoesNotExist(
            identifier: "library.inspector.pane",
            in: app,
            description: "the preview pane after choosing Hide Preview"
        )
        XCTAssertEqual(previewToggle.value as? String, "Hidden")
        previewToggle.click()
        assertElement(identifier: "library.inspector.pane", in: app)

        let filtersToggle = assertElement(identifier: "library.filters.toggle", in: app)
        XCTAssertEqual(filtersToggle.value as? String, "Shown")
        filtersToggle.click()
        assertElementDoesNotExist(
            identifier: "library.filters.pane",
            in: app,
            description: "the filter pane after choosing Hide Filters"
        )
        XCTAssertEqual(filtersToggle.value as? String, "Hidden")
        filtersToggle.click()
        assertElement(identifier: "library.filters.pane", in: app)

        let inspectorOpen = assertElement(identifier: "library.result.inspector.open", in: app)
        XCTAssertEqual(inspectorOpen.label, "Open in Timeline")
        searchField.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])

        assertWindow("Timeline", in: app)
        assertElement(identifier: "timeline.location", in: app)
        let topChrome = assertElement(identifier: "timeline.chrome.top", in: app)
        let moment = assertElement(identifier: "timeline.moment", in: app)
        let bottomChrome = assertElement(identifier: "timeline.chrome.bottom", in: app)
        XCTAssertLessThanOrEqual(topChrome.frame.maxY, moment.frame.minY + 1)
        XCTAssertLessThanOrEqual(moment.frame.maxY, bottomChrome.frame.minY + 1)
        let backToSearch = assertElement(
            identifier: "navigation.timeline.back-to-search",
            in: app
        )
        XCTAssertFalse(
            app.windows["Library"].exists,
            "Opening a result should hand off from Library to Timeline."
        )

        backToSearch.click()
        assertWindow("Library", in: app)
        let restoredSearch = assertElement(identifier: "library.search.field", in: app)
        XCTAssertEqual(restoredSearch.value as? String, "quarterly planning")

        // The standard macOS back gesture is Escape when the Timeline was
        // opened from a Library result. It must preserve the same query too.
        result.doubleClick()
        assertWindow("Timeline", in: app)
        app.typeKey(.escape, modifierFlags: [])
        assertWindow("Library", in: app)
        let searchAfterEscape = assertElement(identifier: "library.search.field", in: app)
        XCTAssertEqual(searchAfterEscape.value as? String, "quarterly planning")

        // The Library toolbar destination becomes Back to Search while a
        // result handoff is active and preserves the same query.
        result.doubleClick()
        assertWindow("Timeline", in: app)
        assertElement(identifier: "navigation.timeline.back-to-search", in: app).click()
        assertWindow("Library", in: app)
        let searchAfterLibraryNavigation = assertElement(
            identifier: "library.search.field",
            in: app
        )
        XCTAssertEqual(searchAfterLibraryNavigation.value as? String, "quarterly planning")

        // A later direct Timeline route must not inherit the consumed result
        // handoff or offer a stale Back to Library action.
        app.typeKey("2", modifierFlags: .command)
        assertWindow("Timeline", in: app)
        assertElementDoesNotExist(
            identifier: "navigation.timeline.back-to-search",
            in: app,
            description: "Back to Library after a direct Timeline route"
        )
        app.typeKey(.escape, modifierFlags: [])
        assertElementDoesNotExist(
            app.windows["Timeline"],
            description: "directly opened Timeline after pressing Escape"
        )
        assertWindow("Library", in: app)
    }

    func testLibraryInspectorReportsAnUnreadablePreviewTruthfully() throws {
        let app = try launch(
            route: "--open-library",
            fixture: true,
            simulatedUnreadablePreview: true
        )
        let search = assertElement(identifier: "library.search.field", in: app)

        search.click()
        search.typeText("quarterly planning")
        search.typeKey(.return, modifierFlags: [])

        assertElement(identifier: "library.result.8", in: app)
        let status = assertElement(
            identifier: "library.result.inspector.preview-status",
            in: app
        )
        XCTAssertEqual(
            status.label,
            "Preview unavailable. The captured image could not be loaded."
        )
        assertElement(identifier: "library.result.inspector.open", in: app)
    }

    func testLibraryInspectorRendersACompactedSearchScreenshot() throws {
        let app = try launch(
            route: "--open-library",
            fixture: true,
            compactHistory: true
        )
        let search = assertElement(identifier: "library.search.field", in: app)

        search.click()
        search.typeText("navigation")
        search.typeKey(.return, modifierFlags: [])

        assertElement(identifier: "library.result.6", in: app)
        let preview = assertElement(
            identifier: "library.result.inspector.preview-status",
            in: app
        )
        expectation(
            for: NSPredicate(format: "label == %@", "Captured screenshot"),
            evaluatedWith: preview
        )
        waitForExpectations(timeout: Self.routeTimeout)
        XCTAssertEqual(preview.label, "Captured screenshot")
    }

    func testLibraryResultSingleClickSelectsAndDoubleClickOpens() throws {
        let app = try launch(route: "--open-library", fixture: true)
        let search = assertElement(identifier: "library.search.field", in: app)

        search.click()
        search.typeText("navigation")
        search.typeKey(.return, modifierFlags: [])

        let firstResult = assertElement(identifier: "library.result.5", in: app)
        assertElement(identifier: "library.result.6", in: app)
        assertElement(identifier: "library.result.inspector.selection.6", in: app)

        firstResult.click()

        assertWindow("Library", in: app)
        assertElement(identifier: "library.result.inspector.selection.5", in: app)

        firstResult.doubleClick()

        assertWindow("Timeline", in: app)
        assertElement(identifier: "timeline.location", in: app)
    }

    func testWebsiteExclusionCanBeAddedAndRemovedInIsolatedPreferences() throws {
        let app = try launch(route: "--open-library", fixture: true)
        assertElement(identifier: "navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)

        assertElement(identifier: "settings.sidebar.exclusions", in: app).click()
        assertElement(identifier: "settings.pane.exclusions", in: app)
        assertElement(identifier: "exclusions.scope-summary", in: app)
        assertElement(identifier: "exclusions.type", in: app)
        assertControl(label: "Websites", in: app).click()
        assertElement(identifier: "exclusions.websites.scope", in: app)

        let websiteField = app.textFields["exclusions.websites.search"]
        XCTAssertTrue(
            websiteField.waitForExistence(timeout: Self.routeTimeout),
            "Expected the website exclusion field."
        )
        websiteField.click()
        websiteField.typeText("privacy-fixture.example")
        assertButton("Exclude Website", in: app).click()

        let feedback = assertElement(identifier: "exclusions.website.feedback", in: app)
        XCTAssertEqual(feedback.label, "Excluded privacy-fixture.example")

        let exclusion = app.checkBoxes["Exclude privacy-fixture.example"]
        XCTAssertTrue(
            exclusion.waitForExistence(timeout: Self.routeTimeout),
            "Expected the newly excluded website to be listed."
        )
        XCTAssertEqual(exclusion.value as? String, "On")
        exclusion.click()
        assertElementDoesNotExist(
            exclusion,
            description: "privacy-fixture.example after removing its exclusion"
        )
    }

    func testApplicationDiscoveryFailureOffersAccessibleRetry() throws {
        let app = try launch(
            route: "--open-library",
            fixture: true,
            simulatedApplicationDiscoveryIssue: true
        )
        assertElement(identifier: "navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)
        assertElement(identifier: "settings.sidebar.exclusions", in: app).click()

        let error = app.descendants(matching: .any)["exclusions.applications.error"]
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<5 where !error.exists {
            scrollView.swipeUp()
        }
        XCTAssertTrue(
            error.waitForExistence(timeout: Self.routeTimeout),
            "Expected an application discovery error instead of an empty catalog."
        )
        XCTAssertEqual(error.label, "Applications couldn't be loaded")

        let retry = app.buttons["exclusions.applications.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: Self.routeTimeout))
        XCTAssertTrue(retry.isEnabled)
        retry.click()
        XCTAssertTrue(
            error.waitForExistence(timeout: Self.routeTimeout),
            "The deterministic failure should remain retryable."
        )
    }

    // MARK: - Launch isolation

    private func launch(
        route: String,
        fixture: Bool = false,
        simulatedCaptureIssue: Bool = false,
        simulatedSearchIssue: Bool = false,
        simulatedApplicationDiscoveryIssue: Bool = false,
        simulatedLoginItemIssue: Bool = false,
        simulatedLoginItemApproval: Bool = false,
        simulatedMissingPermission: Bool = false,
        simulatedMissingAccessibilityPermission: Bool = false,
        simulatedUnreadablePreview: Bool = false,
        selectSessionAfterLoad: Bool = false,
        multipleDisplays: Bool = false,
        compactHistory: Bool = false,
        assistantDetected: [AssistantFixtureTarget] = [],
        assistantReady: [AssistantFixtureTarget] = [],
        assistantRouting: AssistantFixtureRouting = .automatic
    ) throws -> XCUIApplication {
        let dataDirectory = try XCTUnwrap(dataDirectory)
        let token = try XCTUnwrap(UUID(uuidString: dataDirectory.lastPathComponent)).uuidString
        let application = XCUIApplication(bundleIdentifier: Self.bundleIdentifier)
        application.launchEnvironment["SCREENLOG_DATA_DIR"] = dataDirectory.path
        application.launchEnvironment["CFFIXED_USER_HOME"] =
            dataDirectory
            .appendingPathComponent("home", isDirectory: true)
            .path
        application.launchEnvironment["LANGUAGE"] = "en"
        application.launchEnvironment["LC_ALL"] = "en_US.UTF-8"
        application.launchArguments = [
            route,
            "--screenlogger-ui-test-token",
            token,
        ]
        let suite = "dev.screenlog.ui-tests.\(token)"
        preferencesSuite = suite
        application.launchEnvironment["SCREENLOG_UI_TEST_PREFERENCES_MODE"] = "isolated-v1"
        application.launchEnvironment["SCREENLOG_UI_TEST_PREFERENCES_SUITE"] = suite
        if fixture {
            application.launchEnvironment["SCREENLOG_UI_TEST_FIXTURE"] =
                "deterministic-navigation-v1"
            if simulatedCaptureIssue {
                application.launchEnvironment["SCREENLOG_UI_TEST_CAPTURE_ISSUE"] = "start-failed"
            }
            if simulatedSearchIssue {
                application.launchEnvironment["SCREENLOG_UI_TEST_SEARCH_ISSUE"] = "query-failed"
            }
            if simulatedUnreadablePreview {
                application.launchEnvironment["SCREENLOG_UI_TEST_PREVIEW_ISSUE"] = "media-unreadable"
            }
            if simulatedApplicationDiscoveryIssue {
                application.launchEnvironment["SCREENLOG_UI_TEST_APPLICATION_DISCOVERY_ISSUE"] =
                    "catalog-unavailable"
            }
            if simulatedLoginItemIssue {
                application.launchEnvironment["SCREENLOG_UI_TEST_LOGIN_ITEM_ISSUE"] =
                    "registration-failed"
            } else if simulatedLoginItemApproval {
                application.launchEnvironment["SCREENLOG_UI_TEST_LOGIN_ITEM_ISSUE"] =
                    "approval-required"
            }
            if simulatedMissingPermission {
                application.launchEnvironment["SCREENLOG_UI_TEST_PERMISSION_ISSUE"] =
                    "screen-recording-denied"
            } else if simulatedMissingAccessibilityPermission {
                application.launchEnvironment["SCREENLOG_UI_TEST_PERMISSION_ISSUE"] =
                    "accessibility-denied"
            }
            if selectSessionAfterLoad {
                application.launchEnvironment["SCREENLOG_UI_TEST_SELECT_SESSION_AFTER_LOAD"] = "1"
            }
            if multipleDisplays {
                application.launchEnvironment["SCREENLOG_UI_TEST_MULTIPLE_DISPLAYS"] = "1"
            }
            if compactHistory {
                application.launchEnvironment["SCREENLOG_UI_TEST_COMPACT_HISTORY"] = "1"
            }
            application.launchEnvironment["SCREENLOG_UI_TEST_DETECTED_ASSISTANTS"] =
                assistantDetected.map(\.rawValue).joined(separator: ",")
            application.launchEnvironment["SCREENLOG_UI_TEST_READY_ASSISTANTS"] =
                assistantReady.map(\.rawValue).joined(separator: ",")
            application.launchEnvironment["SCREENLOG_UI_TEST_ASSISTANT_ROUTING"] =
                assistantRouting.persistedValue
        }
        application.launch()
        application.activate()

        app = application
        ownsApplicationProcess = true
        XCTAssertTrue(
            application.wait(for: .runningForeground, timeout: Self.routeTimeout),
            "Screenlogger did not become foreground after launching with \(route)."
        )
        if fixture {
            try waitForFixture(in: dataDirectory)
        }
        return application
    }

    private func waitForFixture(in directory: URL) throws {
        let marker = directory.appendingPathComponent("ui-fixture-ready")
        let predicate = NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: marker.path)
        }
        let fixtureReady = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter.wait(for: [fixtureReady], timeout: Self.routeTimeout)
        if result != .completed {
            let errorURL = directory.appendingPathComponent("ui-fixture-error")
            let bootstrapURL = directory.appendingPathComponent("bootstrap.log")
            let detail: String
            if let fixtureError = try? String(contentsOf: errorURL, encoding: .utf8) {
                detail = fixtureError
            } else if let bootstrap = try? String(contentsOf: bootstrapURL, encoding: .utf8) {
                detail = "No fixture error was written. Bootstrap log:\n\(bootstrap)"
            } else {
                detail = "No fixture error or bootstrap log was written."
            }
            XCTFail("The deterministic UI fixture did not become ready. \(detail)")
        }
    }

    // MARK: - Semantic assertions

    @discardableResult
    private func assertWindow(
        _ title: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let window = app.windows[title]
        XCTAssertTrue(
            window.waitForExistence(timeout: Self.routeTimeout),
            "Expected window named \(title). Available hierarchy:\n\(app.debugDescription)",
            file: file,
            line: line
        )
        return window
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
            button.waitForExistence(timeout: Self.routeTimeout),
            "Expected button named \(label).",
            file: file,
            line: line
        )
        XCTAssertTrue(button.isEnabled, "Expected \(label) to be enabled.", file: file, line: line)
        return button
    }

    @discardableResult
    private func assertControl(
        label: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let candidates = [app.buttons[label], app.radioButtons[label]]
        for candidate in candidates where candidate.waitForExistence(timeout: 2) {
            XCTAssertTrue(candidate.isEnabled, "Expected \(label) to be enabled.", file: file, line: line)
            return candidate
        }
        XCTFail("Expected control named \(label).", file: file, line: line)
        return app.descendants(matching: .any)[label]
    }

    @discardableResult
    private func assertElement(
        label: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let predicate = NSPredicate(format: "label == %@", label)
        let element = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: Self.routeTimeout),
            "Expected accessible element named \(label).",
            file: file,
            line: line
        )
        return element
    }

    @discardableResult
    private func assertElement(
        identifier: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(
            element.waitForExistence(timeout: Self.routeTimeout),
            "Expected accessible element identified by \(identifier).",
            file: file,
            line: line
        )
        return element
    }

    private func assertElementDoesNotExist(
        identifier: String,
        in app: XCUIApplication,
        description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertElementDoesNotExist(
            app.descendants(matching: .any)[identifier],
            description: description,
            file: file,
            line: line
        )
    }

    private func assertElementDoesNotExist(
        _ element: XCUIElement,
        description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: element
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: Self.routeTimeout)
        XCTAssertEqual(
            result,
            .completed,
            "Expected \(description) to disappear.",
            file: file,
            line: line
        )
    }

    private func clearNativeSearchField(_ search: XCUIElement) {
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(search.value as? String, "")
    }

    /// XCUITest drops shift-produced punctuation when `typeText` targets an
    /// AppKit NSSearchField on current macOS runners. Paste exercises the same
    /// native edit notification path while preserving structured query syntax.
    private func pasteText(_ text: String, into search: XCUIElement) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        search.typeKey("v", modifierFlags: .command)
    }

}
