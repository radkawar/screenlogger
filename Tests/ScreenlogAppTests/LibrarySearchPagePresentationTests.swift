import ScreenlogCore
import XCTest

final class LibrarySearchPagePresentationTests: XCTestCase {
    func testClickedAppAndWebsiteRemainCombinedAndToggleIndependently() {
        var query = "diagram"
        var app: String?
        var domain: String?
        LibrarySearchFilterRules.selectingApp("com.apple.Safari", name: "Safari", query: &query, selected: &app)
        LibrarySearchFilterRules.selectingDomain("https://docs.example.com/page", query: &query, selected: &domain)
        XCTAssertEqual(app, "com.apple.Safari")
        XCTAssertEqual(domain, "docs.example.com")
        XCTAssertEqual(query, "diagram")

        LibrarySearchFilterRules.selectingApp("com.google.Chrome", name: "Chrome", query: &query, selected: &app)
        XCTAssertEqual(app, "com.google.Chrome")
        XCTAssertEqual(domain, "docs.example.com")
        LibrarySearchFilterRules.selectingDomain("docs.example.com", query: &query, selected: &domain)
        XCTAssertNil(domain)
        XCTAssertEqual(app, "com.google.Chrome")
    }

    func testFacetsChosenBeforeTypingSurviveProseAndOperatorRemoval() {
        var query = ""
        var app: String?
        var domain: String?
        LibrarySearchFilterRules.selectingApp("com.apple.Safari", name: "Safari", query: &query, selected: &app)
        LibrarySearchFilterRules.selectingDomain("docs.example.com", query: &query, selected: &domain)
        for nextQuery in ["diagram", "diagram app:Safari", "diagram", ""] {
            LibrarySearchFilterRules.reconcileQueryFacets(
                from: SearchOperatorParser.parse(query), to: SearchOperatorParser.parse(nextQuery),
                appName: "Safari", app: &app, domain: &domain
            )
            query = nextQuery
            XCTAssertEqual(app, "com.apple.Safari")
            XCTAssertEqual(domain, "docs.example.com")
        }
    }

    func testClickedFacetReplacesOnlyItsConflictingTypedOperator() {
        var query = "diagram app:Safari site:example.com since:2026-04-01"
        var app: String?
        var domain: String?
        LibrarySearchFilterRules.selectingApp("com.google.Chrome", name: "Chrome", query: &query, selected: &app)
        var parsed = SearchOperatorParser.parse(query)
        XCTAssertNil(parsed.appFilter)
        XCTAssertEqual(parsed.siteFilter, "example.com")
        XCTAssertNotNil(parsed.sinceMs)

        LibrarySearchFilterRules.selectingDomain("other.example.org", query: &query, selected: &domain)
        parsed = SearchOperatorParser.parse(query)
        XCTAssertNil(parsed.siteFilter)
        XCTAssertEqual(parsed.ftsText, "diagram")
        XCTAssertNotNil(parsed.sinceMs)
        XCTAssertEqual(app, "com.google.Chrome")
        XCTAssertEqual(domain, "other.example.org")
    }

    func testCompatibleFuzzyAppAndParentWebsiteOperatorsSurviveFacetSelection() {
        var query = "diagram app:Safari site:example.com"
        var app: String?
        var domain: String?
        LibrarySearchFilterRules.selectingApp("com.apple.Safari", name: "Safari", query: &query, selected: &app)
        LibrarySearchFilterRules.selectingDomain("docs.example.com", query: &query, selected: &domain)
        XCTAssertEqual(query, "diagram app:Safari site:example.com")
        XCTAssertEqual(app, "com.apple.Safari")
        XCTAssertEqual(domain, "docs.example.com")
        XCTAssertTrue(LibrarySearchFilterRules.siteFilterConflicts("example.com", domain: "notexample.com"))
    }

    func testNewTypedOperatorWinsOnlyOverTheConflictingFacet() {
        var app: String? = "com.apple.Safari"
        var domain: String? = "docs.example.com"
        let original = SearchOperatorParser.parse("diagram")
        let appQuery = SearchOperatorParser.parse("diagram app:Chrome")
        LibrarySearchFilterRules.reconcileQueryFacets(
            from: original, to: appQuery, appName: "Safari", app: &app, domain: &domain
        )
        XCTAssertNil(app)
        XCTAssertEqual(domain, "docs.example.com")
        let siteQuery = SearchOperatorParser.parse("diagram app:Chrome site:other.org")
        LibrarySearchFilterRules.reconcileQueryFacets(
            from: appQuery, to: siteQuery, appName: nil, app: &app, domain: &domain
        )
        XCTAssertNil(domain)
    }

    func testCompatibleAndIncompleteTypedOperatorsPreserveClickedFacets() {
        for query in ["diagram app:", "diagram site:", "diagram app:Safari site:example.com"] {
            var app: String? = "com.apple.Safari"
            var domain: String? = "docs.example.com"
            LibrarySearchFilterRules.reconcileQueryFacets(
                from: SearchOperatorParser.parse("diagram"), to: SearchOperatorParser.parse(query),
                appName: "Safari", app: &app, domain: &domain
            )
            XCTAssertEqual(app, "com.apple.Safari", query)
            XCTAssertEqual(domain, "docs.example.com", query)
        }
    }

    func testChosenSessionOrPresetRemovesOnlyDisjointDateOperators() throws {
        let chosen = SearchOperatorParser.sqlTimeBounds(from: SearchOperatorParser.parse("date:2026-04-10"))
        let lower = try XCTUnwrap(chosen.fromTimestampMs)
        let upper = try XCTUnwrap(chosen.toTimestampMs)
        let query = LibrarySearchFilterRules.removingConflictingTimeOperators(
            from: "diagram app:Safari site:example.com since:2026-04-01 before:2026-04-05",
            lower: lower, upper: upper
        )
        let parsed = SearchOperatorParser.parse(query)
        XCTAssertNil(parsed.beforeMs)
        XCTAssertNotNil(parsed.sinceMs)
        XCTAssertEqual(parsed.appFilter, "Safari")
        XCTAssertEqual(parsed.siteFilter, "example.com")
        XCTAssertEqual(parsed.ftsText, "diagram")

        let compatible = "diagram since:2026-04-01 before:2026-04-20"
        XCTAssertEqual(
            LibrarySearchFilterRules.removingConflictingTimeOperators(from: compatible, lower: lower, upper: upper),
            compatible
        )
        let replaced = LibrarySearchFilterRules.removingConflictingTimeOperators(
            from: "diagram date:2026-03-01", lower: lower, upper: upper
        )
        XCTAssertNil(SearchOperatorParser.parse(replaced).dayStartMs)
    }

    func testDateAndSessionScopesConflictOnlyWhenTheirInclusiveBoundsDoNotOverlap() {
        XCTAssertTrue(LibrarySearchFilterRules.timeRangesOverlap(from: 100, to: 200, otherFrom: 200, otherTo: 300))
        XCTAssertTrue(LibrarySearchFilterRules.timeRangesOverlap(from: nil, to: 200, otherFrom: 100, otherTo: 300))
        XCTAssertFalse(LibrarySearchFilterRules.timeRangesOverlap(from: 100, to: 199, otherFrom: 200, otherTo: 300))
    }

    func testTimeRangeValidationRejectsAnEmptyIntersection() {
        let lower = SemanticSearchPresentation.lowerBound(100, 300)
        let upper = SemanticSearchPresentation.upperBound(200, 400)
        XCTAssertFalse(LibrarySearchFilterRules.timeRangeIsValid(from: lower, to: upper))
        XCTAssertTrue(LibrarySearchFilterRules.timeRangeIsValid(from: 200, to: 200))
        XCTAssertTrue(LibrarySearchFilterRules.timeRangeIsValid(from: nil, to: 200))
        XCTAssertTrue(LibrarySearchFilterRules.timeRangeIsValid(from: 200, to: nil))
    }

    func testChoosingASingleDateReplacesThePriorRange() {
        let query = LibrarySearchFilterRules.replacingTimeOperator(
            .date, value: "2026-04-10", in: "diagram since:2026-03-01 before:2026-03-20"
        )
        let parsed = SearchOperatorParser.parse(query)
        XCTAssertEqual(parsed.ftsText, "diagram")
        XCTAssertNotNil(parsed.dayStartMs)
        XCTAssertNil(parsed.sinceMs)
        XCTAssertNil(parsed.beforeMs)
        XCTAssertNil(parsed.validationIssue)
    }

    func testChoosingARangeBoundaryReplacesASingleDateAndConflictingBoundary() {
        let query = LibrarySearchFilterRules.replacingTimeOperator(
            .since, value: "2026-04-10", in: "diagram date:2026-03-05 before:2026-03-20"
        )
        let parsed = SearchOperatorParser.parse(query)
        XCTAssertEqual(parsed.ftsText, "diagram")
        XCTAssertNil(parsed.dayStartMs)
        XCTAssertNotNil(parsed.sinceMs)
        XCTAssertNil(parsed.beforeMs)
        XCTAssertNil(parsed.validationIssue)
    }

    func testChoosingARangeBoundaryPreservesACompatibleOppositeBoundary() {
        let query = LibrarySearchFilterRules.replacingTimeOperator(
            .before, value: "2026-04-10", in: "diagram since:2026-04-01"
        )
        let parsed = SearchOperatorParser.parse(query)
        XCTAssertNotNil(parsed.sinceMs)
        XCTAssertNotNil(parsed.beforeMs)
        XCTAssertNil(parsed.validationIssue)
    }

    func testLibrarySearchInteractionBudgetsStayBounded() {
        XCTAssertEqual(
            LibrarySearchInteractionPolicy.inputAcknowledgementBudgetMilliseconds,
            100
        )
        XCTAssertEqual(LibrarySearchInteractionPolicy.pageSize, 80)
    }

    func testRetainedResultsRemainInteractiveDuringRefresh() {
        XCTAssertTrue(
            LibrarySearchInteractionPolicy.resultsRemainInteractive(
                visibleCount: 80,
                state: .loading
            )
        )
        XCTAssertFalse(
            LibrarySearchInteractionPolicy.resultsRemainInteractive(
                visibleCount: 0,
                state: .loading
            )
        )
    }

    func testOnlyCurrentUncancelledSearchGenerationCanPublish() {
        XCTAssertTrue(
            LibrarySearchPublicationPolicy.allowsPublication(
                requestGeneration: 7,
                currentGeneration: 7,
                isCancelled: false
            )
        )
        XCTAssertFalse(
            LibrarySearchPublicationPolicy.allowsPublication(
                requestGeneration: 6,
                currentGeneration: 7,
                isCancelled: false
            )
        )
        XCTAssertFalse(
            LibrarySearchPublicationPolicy.allowsPublication(
                requestGeneration: 7,
                currentGeneration: 7,
                isCancelled: true
            )
        )
    }

    func testLibraryWorkspaceSelectionCarriesItsRestorationAnchor() {
        var state = LibraryWorkspaceNavigationState()

        state.selectResult(42)

        XCTAssertEqual(state.selectedResultID, 42)
        XCTAssertEqual(state.resultViewportAnchorID, 42)
    }

    func testShowInSessionsPreservesResultAndRestorationAnchor() {
        var navigation = LibraryWorkspaceNavigationState()
        navigation.selectResult(42)
        let request = navigation

        XCTAssertTrue(navigation.showSelectedResult(inSession: 1_234, ifUnchangedSince: request))
        XCTAssertEqual(navigation.contentMode, .sessions)
        XCTAssertEqual(navigation.selectedSessionStartMs, 1_234)
        XCTAssertEqual(navigation.selectedResultID, 42)
        XCTAssertEqual(navigation.resultViewportAnchorID, 42)
        navigation.contentMode = .search
        XCTAssertEqual(navigation.selectedResultID, 42)
        XCTAssertEqual(navigation.selectedSessionStartMs, 1_234)
    }

    func testLateShowInSessionsLookupCannotReplaceNewerSessionChoice() {
        var navigation = LibraryWorkspaceNavigationState()
        navigation.selectResult(42)
        let request = navigation
        navigation.contentMode = .sessions
        navigation.selectedSessionStartMs = 9_999

        XCTAssertFalse(navigation.showSelectedResult(inSession: 1_234, ifUnchangedSince: request))
        XCTAssertEqual(navigation.selectedSessionStartMs, 9_999)
        XCTAssertEqual(navigation.selectedResultID, 42)
    }

    func testLateShowInSessionsLookupCannotReplaceNewerSearchSelection() {
        var navigation = LibraryWorkspaceNavigationState()
        navigation.selectResult(42)
        let request = navigation
        navigation.selectResult(7)

        XCTAssertFalse(navigation.showSelectedResult(inSession: 1_234, ifUnchangedSince: request))
        XCTAssertEqual(navigation.contentMode, .search)
        XCTAssertNil(navigation.selectedSessionStartMs)
        XCTAssertEqual(navigation.selectedResultID, 7)
        XCTAssertEqual(navigation.resultViewportAnchorID, 7)
    }

    func testPassiveSearchFocusPreservesSessionsAfterTimelineReturn() {
        var navigation = LibraryWorkspaceNavigationState()
        navigation.selectResult(42)
        navigation.contentMode = .sessions
        navigation.selectedSessionStartMs = 1_234
        let retained = navigation

        XCTAssertFalse(navigation.prepareSearchFocus(selectingExistingQuery: false))
        XCTAssertFalse(navigation.acceptsSearchFocus)
        XCTAssertEqual(navigation, retained)
    }

    func testFindSelectsSearchButItsDelayedFocusCannotUndoNewerSessionsNavigation() {
        var navigation = LibraryWorkspaceNavigationState()
        navigation.selectResult(42)
        navigation.contentMode = .sessions
        navigation.selectedSessionStartMs = 1_234

        XCTAssertTrue(navigation.prepareSearchFocus(selectingExistingQuery: true))
        XCTAssertTrue(navigation.acceptsSearchFocus)
        XCTAssertEqual(navigation.contentMode, .search)
        XCTAssertEqual(navigation.selectedResultID, 42)
        XCTAssertEqual(navigation.selectedSessionStartMs, 1_234)

        navigation.contentMode = .sessions
        XCTAssertFalse(navigation.acceptsSearchFocus)
        XCTAssertEqual(navigation.selectedResultID, 42)
        XCTAssertEqual(navigation.selectedSessionStartMs, 1_234)
    }

    func testLibraryWorkspaceStartsInSearchAndKeepsSessionNavigationSeparate() {
        var state = LibraryWorkspaceNavigationState()

        XCTAssertEqual(state.contentMode, .search)
        XCTAssertNil(state.selectedSessionStartMs)

        state.contentMode = .sessions
        state.selectedSessionStartMs = 1_234
        state.selectResult(42)

        XCTAssertEqual(state.contentMode, .sessions)
        XCTAssertEqual(state.selectedSessionStartMs, 1_234)
        XCTAssertEqual(state.selectedResultID, 42)
    }

    func testLibraryWorkspaceKeepsExactSelectionAcrossAStableResultSet() {
        var state = LibraryWorkspaceNavigationState()
        state.selectResult(6)

        state.reconcileSelection(
            currentResultIDs: [2, 4, 6, 8],
            previousResultIDs: [2, 4, 6, 8]
        )

        XCTAssertEqual(state.selectedResultID, 6)
        XCTAssertEqual(state.resultViewportAnchorID, 6)
    }

    func testLibraryWorkspaceChoosesNearestSurvivingResultAfterFiltering() {
        var state = LibraryWorkspaceNavigationState()
        state.selectResult(6)

        state.reconcileSelection(
            currentResultIDs: [2, 8],
            previousResultIDs: [2, 4, 6, 8, 10]
        )

        XCTAssertEqual(state.selectedResultID, 8)
        XCTAssertEqual(state.resultViewportAnchorID, 8)
    }

    func testLibraryWorkspaceClearsSelectionAndAnchorWithResults() {
        var state = LibraryWorkspaceNavigationState()
        state.selectResult(6)

        state.reconcileSelection(
            currentResultIDs: [],
            previousResultIDs: [4, 6, 8]
        )

        XCTAssertNil(state.selectedResultID)
        XCTAssertNil(state.resultViewportAnchorID)
    }

    func testExactAndTruncatedCountLabelsAreTruthful() {
        XCTAssertEqual(
            LibrarySearchPagePresentation(visibleCount: 1, isTruncated: false).countLabel,
            "1 result"
        )
        XCTAssertEqual(
            LibrarySearchPagePresentation(visibleCount: 80, isTruncated: false).countLabel,
            "80 results"
        )
        XCTAssertEqual(
            LibrarySearchPagePresentation(visibleCount: 80, isTruncated: true).countLabel,
            "80+ results"
        )
    }

    func testLoadMoreRequiresAnActualNextPageCursor() {
        XCTAssertFalse(
            LibrarySearchPagePresentation(
                visibleCount: 80,
                isTruncated: true,
                hasNextPage: false
            ).canLoadMore
        )
        XCTAssertTrue(
            LibrarySearchPagePresentation(
                visibleCount: 80,
                isTruncated: true,
                hasNextPage: true
            ).canLoadMore
        )
        XCTAssertFalse(
            LibrarySearchPagePresentation(
                visibleCount: LibrarySearchPagePresentation.maximumVisibleResults,
                isTruncated: true,
                hasNextPage: true
            ).canLoadMore
        )
    }
}
