import XCTest

final class LibrarySearchPagePresentationTests: XCTestCase {
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
