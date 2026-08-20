import AppKit
import Foundation
import XCTest

/// Focused regressions for transient layers and retained native windows.
final class CrossWindowNavigationUITests: XCTestCase {
    private static let bundleIdentifier = "dev.screenlog.app"
    private static let timeout: TimeInterval = 8

    private var app: XCUIApplication?
    private var dataDirectory: URL?
    private var preferencesSuite: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        let productIsRunning = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        ).contains { !$0.isTerminated }
        try XCTSkipIf(
            productIsRunning,
            "Quit the running Screenlogger app before running UI regression tests."
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

    func testEscapeDismissesSearchSuggestionsBeforeLibrary() throws {
        let app = try launch(route: "--open-library")
        let library = assertWindow("Library", in: app)
        let search = assertElement("library.search.field", in: app)

        search.click()
        pasteText("app:", into: search)
        let suggestions = assertElement("library.search.suggestions", in: app)

        app.typeKey(.escape, modifierFlags: [])

        waitForDisappearance(suggestions, description: "search suggestions")
        XCTAssertTrue(library.exists, "The first Escape should keep Library open.")
        XCTAssertEqual(search.value as? String, "app:", "Dismissing suggestions should preserve the query.")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(search.value as? String, "")

        app.typeKey(.escape, modifierFlags: [])
        waitForDisappearance(library, description: "Library after a third Escape")
    }

    func testLibraryClearKeepsSearchReadyForTheNextQuery() throws {
        let app = try launch(route: "--open-library")
        let search = assertElement("library.search.field", in: app)

        search.click()
        search.typeText("quarterly planning")
        clearNativeSearchField(search)
        app.typeText("navigation")

        XCTAssertEqual(
            search.value as? String,
            "navigation",
            "Clearing Library search should keep the field ready for the next query."
        )
    }

    func testStructuredSearchShowsAnOperatorOnceAndKeepsTermsEditable() throws {
        let app = try launch(route: "--open-library")
        let search = assertElement("library.search.field", in: app)

        search.click()
        pasteText("quarterly app:Text", into: search)

        XCTAssertEqual(
            search.value as? String,
            "quarterly app:Text",
            "An unfinished operator should remain ordinary editable text."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["library.search.operator.app"].exists,
            "Library must not duplicate an operator as both raw syntax and a chip."
        )

        assertElement("library.search.suggestion.app-com.apple.TextEdit", in: app).click()

        let appOperator = assertElement("library.search.operator.app", in: app)
        XCTAssertEqual(appOperator.label, "Remove Application filter: TextEdit")
        XCTAssertEqual(
            search.value as? String,
            "quarterly",
            "Committing an operator should leave only ordinary terms in the native editor."
        )
        assertElement("library.search.operators", in: app)

        search.click()
        search.typeText(" planning")
        XCTAssertEqual(search.value as? String, "quarterly planning")
        assertElement("library.result.8", in: app)

        search.typeText(" ap")
        assertElement("library.search.suggestion.op-app", in: app).click()
        XCTAssertEqual(search.value as? String, "quarterly planning app:")
        waitForDisappearance(
            appOperator,
            description: "the app chip while its replacement is being edited"
        )

        search.typeText("Saf")
        assertElement("library.search.suggestion.app-com.apple.Safari", in: app).click()
        let replacementOperator = assertElement("library.search.operator.app", in: app)
        XCTAssertEqual(
            replacementOperator.label,
            "Remove Application filter: Safari"
        )
        XCTAssertEqual(search.value as? String, "quarterly planning")

        replacementOperator.click()
        waitForDisappearance(
            replacementOperator,
            description: "the removed app search operator"
        )
        app.typeText(" notes")
        XCTAssertEqual(
            search.value as? String,
            "quarterly planning notes",
            "Removing a token must preserve terms and return typing focus to search."
        )
    }

    func testQuotedApplicationFilterCommitsOnlyAfterItsClosingQuote() throws {
        let app = try launch(route: "--open-library")
        let search = assertElement("library.search.field", in: app)

        search.click()
        pasteText(#"app:"Visual "#, into: search)

        XCTAssertEqual(search.value as? String, #"app:"Visual "#)
        XCTAssertFalse(app.descendants(matching: .any)["library.search.operator.app"].exists)

        pasteText(#"Studio Code" "#, into: search)

        let appOperator = assertElement("library.search.operator.app", in: app)
        XCTAssertEqual(
            appOperator.label,
            "Remove Application filter: Visual Studio Code"
        )
        XCTAssertEqual(search.value as? String, "")
    }

    func testBackspaceRemovesTheLastFilterAndKeepsSearchFocused() throws {
        let app = try launch(route: "--open-library")
        let search = assertElement("library.search.field", in: app)

        search.click()
        pasteText("app:TextE", into: search)
        assertElement("library.search.suggestion.app-com.apple.TextEdit", in: app).click()

        let appOperator = assertElement("library.search.operator.app", in: app)
        XCTAssertEqual(search.value as? String, "")
        app.typeKey(.delete, modifierFlags: [])

        waitForDisappearance(appOperator, description: "the last filter after Backspace")
        app.typeText("navigation")
        XCTAssertEqual(
            search.value as? String,
            "navigation",
            "Backspace should remove the last filter without moving typing focus."
        )
    }

    func testKeyboardNavigationCanTabThroughAndApplySuggestions() throws {
        let app = try launch(route: "--open-library", fullKeyboardAccess: true)
        let search = assertElement("library.search.field", in: app)

        search.click()
        pasteText("app:TextE", into: search)
        let suggestions = assertElement("library.search.suggestions", in: app)

        app.typeKey(.tab, modifierFlags: [])
        let selected = suggestions.descendants(matching: .any)
            .matching(NSPredicate(format: "value BEGINSWITH %@", "Selected,"))
            .firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: Self.timeout))

        app.typeKey(.return, modifierFlags: [])
        assertElement("library.search.operator.app", in: app)
        XCTAssertEqual(search.value as? String, "")
    }

    func testDownArrowContinuesFromFinalSuggestionIntoResults() throws {
        let app = try launch(route: "--open-library")
        let search = assertElement("library.search.field", in: app)

        search.click()
        search.typeText("navigation")
        assertElement("library.result.6", in: app)
        search.typeText(" ")

        let suggestions = assertElement("library.search.suggestions", in: app)
        let suggestionCount = suggestions.buttons.count
        XCTAssertGreaterThan(suggestionCount, 0)
        for _ in 0...suggestionCount {
            app.typeKey(.downArrow, modifierFlags: [])
        }

        waitForDisappearance(
            suggestions,
            description: "suggestions after moving keyboard focus into results"
        )
        app.typeKey(.return, modifierFlags: [])
        assertWindow("Timeline", in: app)
    }

    func testDatePickerOwnsFocusWithoutReopeningSuggestions() throws {
        let app = try launch(route: "--open-library")
        let search = assertElement("library.search.field", in: app)

        search.click()
        pasteText("date:", into: search)
        let suggestions = assertElement("library.search.suggestions", in: app)
        assertElement("library.search.suggestion.date-pick", in: app).click()

        let datePicker = app.popovers.firstMatch
        XCTAssertTrue(datePicker.waitForExistence(timeout: Self.timeout))
        assertElement("library.search.date-picker.calendar", in: app)
        waitForDisappearance(
            suggestions,
            description: "search suggestions while the date picker owns focus"
        )

        app.typeKey(.escape, modifierFlags: [])

        waitForDisappearance(
            datePicker,
            description: "date picker after Escape"
        )
        XCTAssertTrue(search.isHittable, "Escape should return focus to Library search.")
        XCTAssertFalse(
            app.descendants(matching: .any)["library.search.suggestions"].exists,
            "Returning from the calendar must not reopen stale suggestions."
        )
        XCTAssertEqual(
            search.value as? String,
            "date:",
            "Canceling the calendar must leave an unfinished date filter visible and editable."
        )
    }

    func testCompactIdleLibraryKeepsFiltersAndDatePickerReachable() throws {
        let app = try launch(route: "--open-library")
        let library = assertWindow("Library", in: app)
        let chrome = windowChromeSize(
            for: library,
            initialContentSize: CGSize(width: 1_080, height: 720)
        )
        resize(
            library,
            toContentSize: CGSize(width: 820, height: 540),
            chrome: chrome
        )

        assertElement("library.state.idle", in: app)
        let filters = assertElement("library.filters.toggle", in: app)
        assertReachable(filters, description: "Filters in an idle compact Library")
        filters.click()

        let filterPopover = assertElement("library.filters", in: app)
        assertElement("library.filter.date.choose", in: app).click()

        waitForDisappearance(
            filterPopover,
            description: "compact Filters before opening the date picker"
        )
        XCTAssertTrue(app.popovers.firstMatch.waitForExistence(timeout: Self.timeout))
        assertElement("library.search.date-picker.calendar", in: app)
    }

    func testFilterOnlySearchUsesResultsWorkspaceWithoutQueryText() throws {
        let app = try launch(route: "--open-library")
        let search = assertElement("library.search.field", in: app)
        let idle = assertElement("library.state.idle", in: app)

        assertElement("library.filter.time.today", in: app).click()

        waitForDisappearance(idle, description: "idle state after choosing a filter")
        XCTAssertEqual(search.value as? String, "", "A filter-only search should keep query text empty.")
        XCTAssertEqual(
            accessibleText(of: assertElement("library.results.title", in: app)),
            "Results"
        )
        assertElement("library.result.8", in: app)

        assertElement("library.filters.clear", in: app).click()
        assertElement("library.state.idle", in: app)
    }

    func testRetainedLibraryRestoresAutocompleteAfterTimelineBecomesKey() throws {
        let app = try launch(route: "--open-library")
        let library = assertWindow("Library", in: app)
        let search = assertElement("library.search.field", in: app)

        search.click()
        pasteText("app:", into: search)
        assertElement("library.search.suggestions", in: app)

        assertElement("navigation.library.timeline", in: app).click()
        assertWindow("Timeline", in: app)

        // Exercise native retained-window activation, not the Command-1 route
        // that explicitly calls SearchWindowController.show.
        library.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).click()
        search.click()

        XCTAssertEqual(search.value as? String, "app:")
        assertElement("library.search.suggestions", in: app)
    }

    func testCompactPreviewIsRestoredAfterTimelineHandoff() throws {
        let app = try launch(route: "--open-library")
        let library = assertWindow("Library", in: app)
        let search = assertElement("library.search.field", in: app)
        search.click()
        search.typeText("quarterly planning")
        assertElement("library.result.8", in: app)

        let chrome = windowChromeSize(
            for: library,
            initialContentSize: CGSize(width: 1_080, height: 720)
        )
        resize(
            library,
            toContentSize: CGSize(width: 820, height: 540),
            chrome: chrome
        )
        assertElement("library.workspace.compact", in: app)

        let preview = assertElement("library.result.preview.toggle", in: app)
        XCTAssertEqual(preview.label, "Show Preview")
        XCTAssertEqual(preview.value as? String, "Hidden")
        preview.click()

        assertElement("library.result.inspector.open", in: app)
        XCTAssertEqual(preview.label, "Hide Preview")
        XCTAssertEqual(preview.value as? String, "Shown")

        assertElement("library.result.inspector.open", in: app).click()
        assertWindow("Timeline", in: app)
        assertElement("navigation.timeline.back-to-search", in: app).click()
        assertWindow("Library", in: app)

        let restoredPreview = assertElement("library.result.preview.toggle", in: app)
        XCTAssertEqual(restoredPreview.label, "Hide Preview")
        XCTAssertEqual(restoredPreview.value as? String, "Shown")
        assertElement(
            "library.result.inspector.open",
            in: app
        )
    }

    func testLibraryTimelineRoundTripPreservesWorkspaceAcrossEveryReturnRoute() throws {
        let app = try launch(route: "--open-library")
        let search = assertElement("library.search.field", in: app)
        search.click()
        pasteText("navigation app:Saf", into: search)
        assertElement("library.search.suggestion.app-com.apple.Safari", in: app).click()
        search.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(search.value as? String, "navigation")
        XCTAssertEqual(
            assertElement("library.search.operator.app", in: app).label,
            "Remove Application filter: Safari"
        )

        let selectedResult = assertElement("library.result.6", in: app)
        selectedResult.click()
        XCTAssertTrue(
            selectedResult.isSelected,
            "Library should expose the selected moment before the handoff."
        )

        let preview = assertElement("library.result.preview.toggle", in: app)
        if preview.value as? String == "Shown" {
            preview.click()
        }
        XCTAssertEqual(preview.value as? String, "Hidden")

        selectedResult.doubleClick()
        assertWindow("Timeline", in: app)
        assertElement("navigation.timeline.back-to-search", in: app).click()

        assertWindow("Library", in: app)
        XCTAssertEqual(search.value as? String, "navigation")
        XCTAssertEqual(
            assertElement("library.search.operator.app", in: app).label,
            "Remove Application filter: Safari"
        )
        XCTAssertTrue(assertElement("library.result.6", in: app).isSelected)
        XCTAssertEqual(
            assertElement("library.result.preview.toggle", in: app).value as? String,
            "Hidden"
        )

        // Escape is the keyboard equivalent of the visible Back action.
        assertElement("library.result.6", in: app).doubleClick()
        assertWindow("Timeline", in: app)
        app.typeKey(.escape, modifierFlags: [])
        assertWindow("Library", in: app)
        XCTAssertEqual(search.value as? String, "navigation")
        assertElement("library.search.operator.app", in: app)
        XCTAssertTrue(assertElement("library.result.6", in: app).isSelected)

        // Closing and reopening Library must not depend on retained view-local state.
        app.typeKey("w", modifierFlags: .command)
        waitForDisappearance(
            app.windows["Library"],
            description: "Library after Command-W"
        )
        app.typeKey("1", modifierFlags: .command)
        assertWindow("Library", in: app)
        XCTAssertEqual(search.value as? String, "navigation")
        assertElement("library.search.operator.app", in: app)
        XCTAssertTrue(assertElement("library.result.6", in: app).isSelected)

        // Recreate a result handoff, then prove Command-2 replaces its stale Back path.
        assertElement("library.result.6", in: app).doubleClick()
        assertWindow("Timeline", in: app)
        assertElement("navigation.timeline.back-to-search", in: app)
        app.typeKey("2", modifierFlags: .command)
        assertWindow("Timeline", in: app)
        XCTAssertFalse(
            app.descendants(matching: .any)["navigation.timeline.back-to-search"].exists,
            "A direct Timeline route must not inherit an earlier Library Back path."
        )

        // Command-1 still restores the exact Library workspace after a direct route.
        app.typeKey("1", modifierFlags: .command)
        assertWindow("Library", in: app)
        XCTAssertEqual(search.value as? String, "navigation")
        assertElement("library.search.operator.app", in: app)
        XCTAssertTrue(assertElement("library.result.6", in: app).isSelected)
    }

    func testFirstRunKeepOffContinuesIntoLibrary() throws {
        let app = try launch(route: "", missingPermission: true)
        assertWindow("Permissions & Privacy", in: app)

        let keepOff = assertElement("setup.keep-off", in: app)
        XCTAssertEqual(keepOff.label, "Keep Off & Open Library")
        keepOff.click()

        let library = assertWindow("Library", in: app)
        XCTAssertTrue(
            library.isHittable,
            "Choosing not to capture during first run should continue into the primary workspace."
        )
        assertElement("library.state.idle", in: app)
        XCTAssertFalse(app.windows["Timeline"].exists)
    }

    func testFirstRunWaitsForDurableMomentThenOpensLibrary() throws {
        let app = try launch(route: "", firstRunFrameDelayMilliseconds: 1_500)
        assertWindow("Permissions & Privacy", in: app)

        assertElement("setup.audio", in: app)
        let audioToggle = app.checkBoxes["setup.audio.enabled"]
        XCTAssertTrue(audioToggle.waitForExistence(timeout: Self.timeout))
        XCTAssertFalse(
            app.descendants(matching: .any)["setup.audio.computer"].exists,
            "Audio sources must stay collapsed until the optional master switch is enabled."
        )
        audioToggle.click()
        assertElement("setup.audio.computer", in: app)
        assertElement("setup.audio.microphone", in: app)
        audioToggle.click()
        XCTAssertFalse(app.descendants(matching: .any)["setup.audio.computer"].exists)
        assertElement("setup.start-capture", in: app).click()
        assertElement("setup.first-value.progress", in: app)
        XCTAssertFalse(
            app.descendants(matching: .any)["setup.open-library"].exists,
            "Starting the capture loop must not claim the first moment is already searchable."
        )

        let openLibrary = assertElement("setup.open-library", in: app)
        openLibrary.click()

        assertWindow("Library", in: app)
        XCTAssertFalse(
            app.windows["Timeline"].exists,
            "First value completes in Library, not in an unrelated Timeline surface."
        )
    }

    func testSelectedLibraryResultHasAnObviousOpenRoute() throws {
        let app = try launch(route: "--open-library")
        let search = assertElement("library.search.field", in: app)
        search.click()
        search.typeText("quarterly planning")

        let inspectorOpen = app.descendants(matching: .any)["library.result.inspector.open"]
        let headerOpen = app.descendants(matching: .any)["library.result.open-selected"]
        XCTAssertTrue(
            inspectorOpen.waitForExistence(timeout: Self.timeout)
                || headerOpen.waitForExistence(timeout: Self.timeout),
            "The selected Library result should expose one visible Open in Timeline action."
        )
        let openSelected = inspectorOpen.exists ? inspectorOpen : headerOpen
        XCTAssertEqual(openSelected.label, "Open in Timeline")
        openSelected.click()

        assertWindow("Timeline", in: app)
        assertElement("navigation.timeline.back-to-search", in: app)
    }

    func testShowingMinimizedTimelinePreservesLibraryReturnPath() throws {
        let app = try launch(route: "--open-library")
        let search = assertElement("library.search.field", in: app)
        search.click()
        search.typeText("quarterly planning")
        let inspectorOpen = app.descendants(matching: .any)["library.result.inspector.open"]
        let headerOpen = app.descendants(matching: .any)["library.result.open-selected"]
        XCTAssertTrue(
            inspectorOpen.waitForExistence(timeout: Self.timeout)
                || headerOpen.waitForExistence(timeout: Self.timeout)
        )
        (inspectorOpen.exists ? inspectorOpen : headerOpen).click()

        let timeline = assertWindow("Timeline", in: app)
        assertElement("navigation.timeline.back-to-search", in: app)
        app.typeKey("m", modifierFlags: .command)
        app.typeKey("2", modifierFlags: .command)

        XCTAssertTrue(timeline.isHittable, "Show Timeline should restore the existing Timeline.")
        assertElement("navigation.timeline.back-to-search", in: app)
    }

    func testSelectedTimelineSessionCanReturnToRecentActivity() throws {
        let app = try launch(route: "--open-timeline")
        let chooser = assertElement("timeline.day.choose", in: app)
        chooser.click()

        let initiallySelectedRecent = assertElement("timeline.range.recent", in: app)
        XCTAssertTrue(
            initiallySelectedRecent.isEnabled,
            "The selected range remains focusable and can dismiss the picker idempotently."
        )
        XCTAssertTrue(initiallySelectedRecent.isSelected)
        XCTAssertEqual(initiallySelectedRecent.value as? String, "Selected")

        let sessions = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "timeline.session.")
        )
        let firstSession = sessions.firstMatch
        XCTAssertTrue(
            firstSession.waitForExistence(timeout: Self.timeout),
            "The range picker should expose recorded sessions for the selected day."
        )
        firstSession.click()
        let sessionScope = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS[c] %@", "session"),
            object: chooser
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [sessionScope], timeout: Self.timeout),
            .completed,
            "Timeline should expose its visible session scope to accessibility."
        )

        chooser.click()
        let recent = assertElement("timeline.range.recent", in: app)
        XCTAssertTrue(recent.isEnabled)
        XCTAssertFalse(recent.isSelected)
        XCTAssertEqual(recent.value as? String, "Not selected")

        let selectedSession = app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ AND value == %@",
                firstSession.identifier,
                "Selected"
            )
        ).firstMatch
        XCTAssertTrue(
            selectedSession.waitForExistence(timeout: Self.timeout),
            "The active session row should remain available and expose selected semantics."
        )
        XCTAssertTrue(selectedSession.isEnabled)
        XCTAssertTrue(selectedSession.isSelected)

        selectedSession.click()
        XCTAssertFalse(
            recent.exists,
            "Activating the current session should dismiss the picker without changing range."
        )
        XCTAssertTrue(
            (chooser.value as? String)?.localizedCaseInsensitiveContains("session") == true
        )

        chooser.click()
        let recentAfterIdempotentSelection = assertElement("timeline.range.recent", in: app)
        XCTAssertTrue(recentAfterIdempotentSelection.isEnabled)
        recentAfterIdempotentSelection.click()

        let noSessionScope = NSPredicate(format: "NOT label CONTAINS %@", "Session")
        expectation(for: noSessionScope, evaluatedWith: chooser)
        waitForExpectations(timeout: Self.timeout)
    }

    func testTimelineSessionSearchKeepsScopeVisibleAtMinimumLibraryWidth() throws {
        let app = try launch(route: "--open-timeline")
        let chooser = assertElement("timeline.day.choose", in: app)
        chooser.click()

        let firstSession = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "timeline.session.")
        ).firstMatch
        XCTAssertTrue(
            firstSession.waitForExistence(timeout: Self.timeout),
            "The Timeline range picker should expose a session for scoped search."
        )
        firstSession.click()

        app.typeKey("k", modifierFlags: .command)

        let library = assertWindow("Library", in: app)
        let chrome = windowChromeSize(
            for: library,
            initialContentSize: CGSize(width: 1_080, height: 720)
        )
        resize(
            library,
            toContentSize: CGSize(width: 820, height: 540),
            chrome: chrome
        )

        let scope = assertElement("library.search.scope.session", in: app)
        XCTAssertEqual(scope.label, "Current Session")
        XCTAssertTrue(
            (scope.value as? String ?? "").contains("Search limited"),
            "The session chip should explain that Library results are scoped."
        )
        XCTAssertTrue(
            !scope.frame.isEmpty && library.frame.intersects(scope.frame),
            "Current Session scope should remain visible at minimum Library width."
        )

        let searchAll = assertElement("library.search.scope.all-library", in: app)
        XCTAssertEqual(searchAll.label, "Search All Library")
        assertReachable(searchAll, description: "Search All Library at minimum Library width")
        searchAll.click()

        waitForDisappearance(scope, description: "Current Session scope after searching all Library")
        XCTAssertTrue(
            assertElement("library.search.field", in: app).isHittable,
            "Removing session scope should keep Library search ready."
        )
    }

    func testTimelineBareSpaceDoesNotOverrideTheRangeControl() throws {
        let app = try launch(route: "--open-timeline", fullKeyboardAccess: true)
        let chooser = assertElement("timeline.day.choose", in: app)
        let replay = assertElement("timeline.playback.toggle", in: app)
        let replayLabel = replay.label

        chooser.click()
        let recent = assertElement("timeline.range.recent", in: app)
        XCTAssertTrue(recent.isEnabled)

        // The range picker owns this interaction while its popover is open.
        // The window-wide playback shortcut must yield the Space event.
        app.typeKey(" ", modifierFlags: [])
        XCTAssertEqual(
            replay.label,
            replayLabel,
            "Space in the range picker must not toggle Timeline replay."
        )
    }

    func testCommandFFindsInLibraryFromAnotherFocusedWindow() throws {
        let app = try launch(route: "--open-setup", missingPermission: true)
        let setup = assertWindow("Permissions & Privacy", in: app)
        XCTAssertTrue(setup.isHittable)

        // Find is an app-level Edit menu command, so the familiar macOS
        // shortcut must work before Library or Timeline has ever been opened.
        app.typeKey("f", modifierFlags: .command)

        let library = assertWindow("Library", in: app)
        XCTAssertTrue(library.isHittable, "Command-F should focus Library.")
        let search = assertElement("library.search.field", in: app)
        search.typeText("project handoff")
        XCTAssertEqual(
            search.value as? String,
            "project handoff",
            "Command-F should place keyboard focus in Library search."
        )

        // A focused native search field clears its current query before the
        // next Escape dismisses the transient Library window.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(search.value as? String, "")
        app.typeKey(.escape, modifierFlags: [])
        waitForDisappearance(library, description: "Library after pressing Escape")
        XCTAssertTrue(
            setup.isHittable,
            "Dismissing Find should return keyboard focus to the initiating window."
        )
    }

    func testReopeningMinimizedSetupAdoptsTheNewLibraryReturnPath() throws {
        let app = try launch(route: "--open-setup", missingPermission: true)
        let setup = assertWindow("Permissions & Privacy", in: app)
        let originalGuidance = accessibleText(
            of: assertElement("setup.return-guidance", in: app)
        )
        XCTAssertTrue(originalGuidance.contains("Timeline"))

        app.typeKey("m", modifierFlags: .command)
        app.typeKey("k", modifierFlags: .command)
        assertWindow("Library", in: app)

        let captureStatus = app.descendants(matching: .any)["library.capture.status"]
        XCTAssertTrue(captureStatus.waitForExistence(timeout: Self.timeout))
        captureStatus.click()

        XCTAssertTrue(setup.waitForExistence(timeout: Self.timeout))
        let updatedGuidance = accessibleText(
            of: assertElement("setup.return-guidance", in: app)
        )
        XCTAssertNotEqual(
            updatedGuidance,
            originalGuidance,
            "An explicitly reopened, minimized Setup flow must not keep a stale destination."
        )
        XCTAssertTrue(
            updatedGuidance.contains("Library"),
            "Reopened Setup should explain that it returns to its new initiating surface."
        )
        let usable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: setup
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [usable], timeout: Self.timeout),
            .completed,
            "Opening Setup again should deminiaturize it and return keyboard focus."
        )

        assertElement("setup.keep-off", in: app).click()
        let library = assertWindow("Library", in: app)
        XCTAssertTrue(library.isHittable)
        XCTAssertFalse(app.windows["Timeline"].exists)
    }

    func testReopeningVisibleSetupPreservesItsActiveReturnPath() throws {
        let app = try launch(route: "--open-setup", missingPermission: true)
        let setup = assertWindow("Permissions & Privacy", in: app)
        let originalGuidance = accessibleText(
            of: assertElement("setup.return-guidance", in: app)
        )
        XCTAssertTrue(originalGuidance.contains("Timeline"))

        app.typeKey("k", modifierFlags: .command)
        assertWindow("Library", in: app)
        XCTAssertTrue(setup.exists, "The original Setup flow should remain visibly retained.")

        let captureStatus = app.descendants(matching: .any)["library.capture.status"]
        XCTAssertTrue(captureStatus.waitForExistence(timeout: Self.timeout))
        captureStatus.click()

        XCTAssertEqual(
            accessibleText(of: assertElement("setup.return-guidance", in: app)),
            originalGuidance,
            "Reopening an already-visible Setup flow must not change its active destination."
        )
    }

    func testTimelineSetupPreservesLibraryResultReturnPathWhenCaptureStaysOff() throws {
        let app = try launch(
            route: "--open-library",
            missingPermission: true,
            seedHistoryWithoutPermission: true
        )
        let search = assertElement("library.search.field", in: app)
        search.click()
        search.typeText("quarterly planning")
        search.typeKey(.return, modifierFlags: [])
        let result = assertElement("library.result.8", in: app)

        result.doubleClick()
        assertWindow("Timeline", in: app)
        assertElement("navigation.timeline.back-to-search", in: app)
        assertElement("timeline.capture.status", in: app).click()
        assertWindow("Permissions & Privacy", in: app)

        assertElement("setup.keep-off", in: app).click()

        assertWindow("Timeline", in: app)
        assertElement("navigation.timeline.back-to-search", in: app).click()
        assertWindow("Library", in: app)
        XCTAssertEqual(
            assertElement("library.search.field", in: app).value as? String,
            "quarterly planning",
            "Keeping capture off must preserve the initiating Library query through Timeline Setup."
        )

        // A directly opened Timeline still returns as a direct destination;
        // it must not inherit the earlier result handoff.
        app.typeKey("2", modifierFlags: .command)
        assertWindow("Timeline", in: app)
        assertElement("timeline.capture.status", in: app).click()
        assertWindow("Permissions & Privacy", in: app)
        assertElement("setup.keep-off", in: app).click()
        assertWindow("Timeline", in: app)
        XCTAssertFalse(
            app.descendants(matching: .any)["navigation.timeline.back-to-search"].exists,
            "Direct Timeline Setup must remain direct."
        )
    }

    func testCompletedTimelineSetupPreservesLibraryResultReturnPath() throws {
        let app = try launch(
            route: "--open-library",
            missingPermission: true,
            seedHistoryWithoutPermission: true,
            grantPermissionAfterOpeningSettings: true
        )
        let search = assertElement("library.search.field", in: app)
        search.click()
        search.typeText("quarterly planning")
        search.typeKey(.return, modifierFlags: [])
        assertElement("library.result.8", in: app).doubleClick()
        assertWindow("Timeline", in: app)
        assertElement("timeline.capture.status", in: app).click()
        assertWindow("Permissions & Privacy", in: app)

        assertElement("setup.open-screen-recording", in: app).click()
        assertElement("setup.open-screen-recording", in: app).click()
        assertElement("setup.start-capture", in: app).click()

        assertWindow("Timeline", in: app)
        assertElement("navigation.timeline.back-to-search", in: app).click()
        assertWindow("Library", in: app)
        XCTAssertEqual(
            assertElement("library.search.field", in: app).value as? String,
            "quarterly planning",
            "Completing Setup must preserve the initiating Library query."
        )
    }

    func testSetupRequiresBothPermissionsInSequenceBeforeOfferingCapture() throws {
        let app = try launch(
            route: "--open-setup",
            missingPermission: true,
            grantPermissionsSequentially: true
        )
        assertWindow("Permissions & Privacy", in: app)

        let screenRecording = assertElement("setup.open-screen-recording", in: app)
        screenRecording.click()
        assertElement("setup.open-screen-recording", in: app).click()

        assertElement("setup.open-accessibility", in: app)
        XCTAssertFalse(
            app.descendants(matching: .any)["setup.start-capture"].exists,
            "Start Capture must remain unavailable after Screen Recording alone is allowed."
        )
        XCTAssertEqual(
            assertElement("setup.progress.permission", in: app).value as? String,
            "Complete"
        )
        XCTAssertEqual(
            assertElement("setup.progress.accessibility", in: app).value as? String,
            "Current step"
        )

        assertElement("setup.open-accessibility", in: app).click()
        assertElement("setup.open-accessibility", in: app).click()
        assertElement("setup.start-capture", in: app)
    }

    func testClosingUndecidedSetupPersistsCaptureOffChoice() throws {
        let app = try launch(route: "--open-setup")
        let setup = assertWindow("Permissions & Privacy", in: app)

        app.typeKey("w", modifierFlags: .command)
        waitForDisappearance(setup, description: "Setup after Command-W")

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: Self.timeout))
        app.launchArguments = Array(app.launchArguments.dropFirst())
        app.launch()
        let appStarted = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.state == .runningForeground || app.state == .runningBackground
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [appStarted], timeout: Self.timeout),
            .completed
        )

        XCTAssertFalse(
            app.windows["Permissions & Privacy"].waitForExistence(timeout: 2),
            "Closing first-run Setup should record the decision instead of reopening next launch."
        )
        app.activate()
        app.typeKey("k", modifierFlags: .command)
        assertWindow("Library", in: app)
    }

    func testEscapeClosesGuideAndReturnsFocusToSupport() throws {
        let app = try launch(route: "--open-library")
        assertElement("navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)
        assertElement("settings.sidebar.support", in: app).click()
        assertElement("settings.support.user-guide", in: app).click()
        let guide = app.sheets.firstMatch
        XCTAssertTrue(guide.waitForExistence(timeout: Self.timeout))
        assertElement("settings.guide.detail.gettingStarted", in: app)

        app.typeKey(.escape, modifierFlags: [])

        waitForDisappearance(guide, description: "offline User Guide")
        assertReachable(
            assertElement("settings.pane.support", in: app),
            description: "Support Settings after closing the offline User Guide"
        )
    }

    func testOpeningMinimizedLibraryRestoresSearchFocus() throws {
        let app = try launch(route: "--open-library")
        let library = assertWindow("Library", in: app)
        let search = assertElement("library.search.field", in: app)
        search.typeText("quarterly")

        app.typeKey("m", modifierFlags: .command)
        app.typeKey("1", modifierFlags: .command)

        XCTAssertTrue(library.waitForExistence(timeout: Self.timeout))
        let usable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: library
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [usable], timeout: Self.timeout),
            .completed,
            "Opening Library again should deminiaturize its native window."
        )
        search.typeText(" planning")
        XCTAssertEqual(
            search.value as? String,
            "quarterly planning",
            "A restored Library should return keyboard focus to search."
        )
    }

    func testSettingsNoResultsOffersAnObviousWayBack() throws {
        let app = try launch(route: "--open-library")
        assertElement("navigation.library.settings", in: app).click()
        assertWindow("Settings", in: app)

        let search = app.searchFields["Search Settings"]
        XCTAssertTrue(search.waitForExistence(timeout: Self.timeout))
        search.click()
        search.typeText("unfindable-setting-zz")
        assertElement("settings.search.empty", in: app)

        let clearSearch = app.buttons["Clear Search"]
        XCTAssertTrue(clearSearch.waitForExistence(timeout: Self.timeout))
        clearSearch.click()

        assertElement("settings.pane.general", in: app)
        XCTAssertEqual(search.value as? String, "")
    }

    func testLibraryQualityBarLayoutsKeepCoreNavigationReachable() throws {
        let app = try launch(route: "--open-library")
        let library = assertWindow("Library", in: app)
        let chrome = windowChromeSize(
            for: library,
            initialContentSize: CGSize(width: 1_080, height: 720)
        )

        for contract in [
            LayoutSizeContract("minimum 820x540", 820, 540),
            LayoutSizeContract("standard 1060x700", 1_060, 700),
            LayoutSizeContract("large 1360x860", 1_360, 860),
        ] {
            XCTContext.runActivity(named: contract.name) { _ in
                resize(library, toContentSize: contract.contentSize, chrome: chrome)

                assertReachable(library, description: "Library destination title")
                assertReachable(
                    assertElement("library.search.field", in: app),
                    description: "Library search"
                )
                assertReachable(
                    assertElement("navigation.library.timeline", in: app),
                    description: "Timeline destination"
                )
                assertReachable(
                    assertElement("navigation.library.settings", in: app),
                    description: "Settings destination"
                )

                if contract.contentSize.width == 820 {
                    assertReachable(
                        assertElement("library.filters.toggle", in: app),
                        description: "compact Library Filters action"
                    )
                    XCTAssertFalse(
                        app.descendants(matching: .any)["library.filters.pane"].exists,
                        "The minimum Library width should use compact filter presentation."
                    )
                } else {
                    let filtersPane = assertElement("library.filters.pane", in: app)
                    XCTAssertTrue(
                        !filtersPane.frame.isEmpty && library.frame.intersects(filtersPane.frame),
                        "The expanded Library filter pane should be visible inside the window."
                    )
                    assertReachable(
                        assertElement("library.filter.time.today", in: app),
                        description: "Today filter in the expanded Library pane"
                    )
                }
            }
        }
    }

    func testTimelineQualityBarLayoutsKeepCoreNavigationReachable() throws {
        let app = try launch(route: "--open-timeline")
        let timeline = assertWindow("Timeline", in: app)
        let chrome = windowChromeSize(
            for: timeline,
            initialContentSize: CGSize(width: 1_080, height: 760)
        )

        for contract in [
            LayoutSizeContract("minimum 820x540", 820, 540),
            LayoutSizeContract("standard 1060x700", 1_060, 700),
            LayoutSizeContract("large 1360x860", 1_360, 860),
        ] {
            XCTContext.runActivity(named: contract.name) { _ in
                resize(timeline, toContentSize: contract.contentSize, chrome: chrome)

                assertReachable(timeline, description: "Timeline destination title")
                assertReachable(
                    assertElement("timeline.playback.toggle", in: app),
                    description: "Timeline playback action"
                )
                assertReachable(
                    assertElement("timeline.moment.actions", in: app),
                    description: "Timeline moment actions"
                )
                assertReachable(
                    assertElement("navigation.timeline.library", in: app),
                    description: "Library destination"
                )
                assertReachable(
                    assertElement("navigation.timeline.settings", in: app),
                    description: "Settings destination"
                )
            }
        }
    }

    func testTimelinePlaybackRestartsAndControlLimitsStayTruthful() throws {
        let app = try launch(route: "--open-timeline")
        assertWindow("Timeline", in: app)

        assertElement("timeline.navigation", in: app)
        let position = assertElement("timeline.navigation.position", in: app)
        expectation(
            for: NSPredicate(format: "value CONTAINS %@", "moment 8 of 8"),
            evaluatedWith: position
        )
        waitForExpectations(timeout: Self.timeout)

        let playback = assertElement("timeline.playback.toggle", in: app)
        playback.click()
        expectation(
            for: NSPredicate(format: "NOT (value CONTAINS %@)", "moment 8 of 8"),
            evaluatedWith: position
        )
        waitForExpectations(timeout: Self.timeout)
        XCTAssertEqual(
            playback.label,
            "Pause replay",
            "Playing from the final moment should restart at the beginning and continue."
        )
        playback.click()

        let range = assertElement("timeline.navigation.range", in: app)
        XCTAssertEqual(range.label, "Timeline range")
        XCTAssertEqual(range.value as? String, "Full Timeline range")
        range.click()
        assertElement("timeline.navigation.range.option.6", in: app).click()
        let rangeChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", "Full Timeline range"),
            object: range
        )
        XCTAssertEqual(XCTWaiter.wait(for: [rangeChanged], timeout: Self.timeout), .completed)
        XCTAssertFalse((range.value as? String ?? "").isEmpty)

        let zoomOut = assertElement("timeline.zoom.out", in: app)
        let zoomReset = assertElement("timeline.zoom.reset", in: app)
        let zoomIn = assertElement("timeline.zoom.in", in: app)
        for _ in 0..<4 {
            zoomOut.click()
        }
        XCTAssertFalse(
            zoomOut.isEnabled,
            "The minimum preview zoom should not offer a no-op Zoom Out control."
        )
        XCTAssertEqual(zoomReset.value as? String, "50 percent")

        zoomReset.click()
        XCTAssertEqual(zoomReset.value as? String, "100 percent")
        for _ in 0..<7 {
            zoomIn.click()
        }
        XCTAssertFalse(
            zoomIn.isEnabled,
            "The maximum preview zoom should not offer a no-op Zoom In control."
        )
        XCTAssertEqual(zoomReset.value as? String, "400 percent")
    }

    func testSettingsQualityBarLayoutsKeepCoreNavigationReachable() throws {
        let app = try launch(route: "--open-library")
        assertElement("navigation.library.settings", in: app).click()
        let settings = assertWindow("Settings", in: app)
        let chrome = windowChromeSize(
            for: settings,
            initialContentSize: CGSize(width: 860, height: 600)
        )

        for contract in [
            // With a full-size content view, AppKit adds the titlebar height
            // when enforcing the 820x540 content minimum. XCUI reports the
            // resulting native window frame, whose minimum height is 592.
            LayoutSizeContract("minimum 820x540 content", 820, 592),
            LayoutSizeContract("default 860x600", 860, 600),
            LayoutSizeContract("large 960x800", 960, 800),
        ] {
            XCTContext.runActivity(named: contract.name) { _ in
                resize(settings, toContentSize: contract.contentSize, chrome: chrome)

                assertReachable(
                    assertElement("settings.pane.general", in: app),
                    description: "General Settings title"
                )
                assertReachable(
                    app.searchFields["Search Settings"],
                    description: "Settings search"
                )
                assertReachable(
                    settingsNavigationElement(
                        identifier: "navigation.settings.library",
                        label: "Library",
                        in: app
                    ),
                    description: "Library destination"
                )
                assertReachable(
                    settingsNavigationElement(
                        identifier: "navigation.settings.timeline",
                        label: "Timeline",
                        in: app
                    ),
                    description: "Timeline destination"
                )
            }
        }
    }

    func testTimelineNativeLifecyclePreservesContextFocusAndFrame() throws {
        let app = try launch(route: "--open-timeline")
        let timeline = assertWindow("Timeline", in: app)
        let chrome = windowChromeSize(
            for: timeline,
            initialContentSize: CGSize(width: 1_080, height: 760)
        )
        resize(
            timeline,
            toContentSize: CGSize(width: 1_060, height: 700),
            chrome: chrome
        )
        let chosenFrame = timeline.frame
        assertElement("timeline.moment.context", in: app)

        app.typeKey("m", modifierFlags: .command)
        app.typeKey("2", modifierFlags: .command)

        assertReachable(timeline, description: "deminiaturized Timeline")
        assertFrame(timeline, approximatelyEquals: chosenFrame)
        let zoom = assertElement("timeline.zoom.reset", in: app)
        app.typeKey("-", modifierFlags: .command)
        waitForValue(zoom, toEqual: "80 percent")
        app.typeKey("0", modifierFlags: .command)
        waitForValue(zoom, toEqual: "100 percent")

        app.typeKey(.escape, modifierFlags: [])
        waitForDisappearance(timeline, description: "Timeline after Escape")
        app.typeKey("2", modifierFlags: .command)

        assertWindow("Timeline", in: app)
        assertElement("timeline.moment.context", in: app)
        assertFrame(timeline, approximatelyEquals: chosenFrame)

        relaunch(app)
        let restored = assertWindow("Timeline", in: app)
        assertFrame(restored, approximatelyEquals: chosenFrame)
    }

    func testSettingsNativeLifecyclePreservesPaneFocusAndFrame() throws {
        let app = try launch(route: "--open-library")
        let library = assertWindow("Library", in: app)
        assertElement("navigation.library.settings", in: app).click()
        let settings = assertWindow("Settings", in: app)
        assertElement("settings.sidebar.support", in: app).click()
        assertElement("settings.pane.support", in: app)
        let chrome = windowChromeSize(
            for: settings,
            initialContentSize: CGSize(width: 860, height: 600)
        )
        resize(
            settings,
            toContentSize: CGSize(width: 960, height: 680),
            chrome: chrome
        )
        let chosenFrame = settings.frame

        app.typeKey("m", modifierFlags: .command)
        app.typeKey(",", modifierFlags: .command)

        assertReachable(settings, description: "deminiaturized Settings")
        assertElement("settings.pane.support", in: app)
        assertFrame(settings, approximatelyEquals: chosenFrame)

        // Escape is not a close command for a plain macOS Settings window.
        app.typeKey(.escape, modifierFlags: [])
        assertReachable(settings, description: "Settings after Escape")

        // Command-W proves the reopened Settings window owns keyboard focus.
        app.typeKey("w", modifierFlags: .command)
        waitForDisappearance(settings, description: "Settings after Command-W")
        assertReachable(library, description: "underlying Library")

        app.typeKey(",", modifierFlags: .command)
        assertWindow("Settings", in: app)
        assertElement("settings.pane.support", in: app)
        assertFrame(settings, approximatelyEquals: chosenFrame)

        relaunch(app)
        assertWindow("Library", in: app)
        app.typeKey(",", modifierFlags: .command)
        let restored = assertWindow("Settings", in: app)
        assertFrame(restored, approximatelyEquals: chosenFrame)
    }

    private func launch(
        route: String,
        missingPermission: Bool = false,
        seedHistoryWithoutPermission: Bool = false,
        grantPermissionAfterOpeningSettings: Bool = false,
        grantPermissionsSequentially: Bool = false,
        fullKeyboardAccess: Bool = false,
        firstRunFrameDelayMilliseconds: UInt64? = nil
    ) throws -> XCUIApplication {
        let directory = try XCTUnwrap(dataDirectory)
        let token = try XCTUnwrap(UUID(uuidString: directory.lastPathComponent)).uuidString
        let application = XCUIApplication(bundleIdentifier: Self.bundleIdentifier)
        application.launchArguments = [
            route,
            "--screenlogger-ui-test-token",
            token,
        ]
        if fullKeyboardAccess {
            // NSArgumentDomain override scoped to this process; the test never
            // mutates the developer or CI machine's global keyboard settings.
            application.launchArguments.append(contentsOf: ["-AppleKeyboardUIMode", "3"])
        }
        application.launchEnvironment["SCREENLOG_DATA_DIR"] = directory.path
        application.launchEnvironment["CFFIXED_USER_HOME"] =
            directory.appendingPathComponent("home", isDirectory: true).path
        application.launchEnvironment["LANGUAGE"] = "en"
        application.launchEnvironment["LC_ALL"] = "en_US.UTF-8"
        application.launchEnvironment["SCREENLOG_UI_TEST_PREFERENCES_MODE"] = "isolated-v1"
        application.launchEnvironment["SCREENLOG_UI_TEST_FIXTURE"] =
            "deterministic-navigation-v1"
        let suite = "dev.screenlog.ui-tests.\(token)"
        preferencesSuite = suite
        application.launchEnvironment["SCREENLOG_UI_TEST_PREFERENCES_SUITE"] = suite
        if missingPermission {
            application.launchEnvironment["SCREENLOG_UI_TEST_PERMISSION_ISSUE"] =
                "screen-recording-denied"
        }
        if seedHistoryWithoutPermission {
            application.launchEnvironment["SCREENLOG_UI_TEST_SEED_HISTORY_WITHOUT_PERMISSION"] = "1"
        }
        if grantPermissionAfterOpeningSettings {
            application.launchEnvironment[
                "SCREENLOG_UI_TEST_GRANT_PERMISSION_AFTER_OPENING_SETTINGS"
            ] = "1"
        }
        if grantPermissionsSequentially {
            application.launchEnvironment[
                "SCREENLOG_UI_TEST_GRANT_PERMISSION_AFTER_OPENING_SETTINGS"
            ] = "sequential"
        }
        if let firstRunFrameDelayMilliseconds {
            application.launchEnvironment["SCREENLOG_UI_TEST_FIRST_RUN_FRAME_DELAY_MS"] =
                String(firstRunFrameDelayMilliseconds)
        }
        application.launch()
        app = application

        XCTAssertTrue(application.wait(for: .runningForeground, timeout: Self.timeout))
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
        let result = XCTWaiter.wait(for: [ready], timeout: Self.timeout)
        if result != .completed {
            let errorURL = directory.appendingPathComponent("ui-fixture-error")
            let detail =
                (try? String(contentsOf: errorURL, encoding: .utf8))
                ?? "No fixture error was written."
            XCTFail("The deterministic UI fixture did not become ready. \(detail)")
        }
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

    private func accessibleText(of element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        return element.value as? String ?? ""
    }

    private func settingsNavigationElement(
        identifier: String,
        label: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        let identified = app.descendants(matching: .any)[identifier]
        if identified.exists { return identified }
        return app.buttons[label]
    }

    @discardableResult
    private func assertWindow(
        _ title: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let window = app.windows[title]
        XCTAssertTrue(
            window.waitForExistence(timeout: Self.timeout),
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
            element.waitForExistence(timeout: Self.timeout),
            "Expected element identified by \(identifier).",
            file: file,
            line: line
        )
        return element
    }

    private func waitForDisappearance(
        _ element: XCUIElement,
        description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [gone], timeout: Self.timeout),
            .completed,
            "Expected \(description) to disappear.",
            file: file,
            line: line
        )
    }

    private func relaunch(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        app.terminate()
        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: Self.timeout),
            "Expected Screenlogger to terminate before relaunch.",
            file: file,
            line: line
        )
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: Self.timeout),
            "Expected Screenlogger to return to the foreground.",
            file: file,
            line: line
        )
    }

    private func assertFrame(
        _ window: XCUIElement,
        approximatelyEquals expected: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reachedFrame = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                let actual = element.frame
                return abs(actual.minX - expected.minX) <= 5
                    && abs(actual.minY - expected.minY) <= 5
                    && abs(actual.width - expected.width) <= 5
                    && abs(actual.height - expected.height) <= 5
            },
            object: window
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [reachedFrame], timeout: Self.timeout),
            .completed,
            "Expected saved window frame \(expected); found \(window.frame).",
            file: file,
            line: line
        )
    }

    private func waitForValue(
        _ element: XCUIElement,
        toEqual expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [changed], timeout: Self.timeout),
            .completed,
            "Expected \(element.identifier) value to equal \(expected).",
            file: file,
            line: line
        )
    }

    private func windowChromeSize(
        for window: XCUIElement,
        initialContentSize: CGSize
    ) -> CGSize {
        CGSize(
            width: max(0, window.frame.width - initialContentSize.width),
            height: max(0, window.frame.height - initialContentSize.height)
        )
    }

    private func resize(
        _ window: XCUIElement,
        toContentSize contentSize: CGSize,
        chrome: CGSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let targetFrameSize = CGSize(
            width: contentSize.width + chrome.width,
            height: contentSize.height + chrome.height
        )
        let currentFrame = window.frame
        // A normalized (1, 1) coordinate resolves to frame.maxX/maxY. Those
        // far edges are outside NSRect's half-open bounds, so macOS can deliver
        // the drag without ever beginning a native window-resize session.
        // Start just inside AppKit's resize hit region instead. Keeping the
        // destination as a relative size delta preserves the requested frame.
        let resizeHandle = window.coordinate(
            withNormalizedOffset: CGVector(dx: 1, dy: 1)
        )
        .withOffset(CGVector(dx: -2, dy: -2))
        let destination = resizeHandle.withOffset(
            CGVector(
                dx: targetFrameSize.width - currentFrame.width,
                dy: targetFrameSize.height - currentFrame.height
            )
        )
        resizeHandle.click(forDuration: 0.1, thenDragTo: destination)

        let reachedSize = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return abs(element.frame.width - targetFrameSize.width) <= 5
                    && abs(element.frame.height - targetFrameSize.height) <= 5
            },
            object: window
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [reachedSize], timeout: Self.timeout),
            .completed,
            "Expected content size approximately \(Int(contentSize.width))x\(Int(contentSize.height)); "
                + "window frame was \(window.frame).",
            file: file,
            line: line
        )
    }

    private func assertReachable(
        _ element: XCUIElement,
        description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: Self.timeout),
            "Expected \(description) to exist.",
            file: file,
            line: line
        )
        let reachable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [reachable], timeout: Self.timeout),
            .completed,
            "Expected \(description) to remain reachable.",
            file: file,
            line: line
        )
    }

    private struct LayoutSizeContract {
        let name: String
        let contentSize: CGSize

        init(_ name: String, _ width: CGFloat, _ height: CGFloat) {
            self.name = name
            contentSize = CGSize(width: width, height: height)
        }
    }
}
