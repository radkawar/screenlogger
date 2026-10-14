import XCTest

@testable import ScreenlogCore

final class TimelineContentStateTests: XCTestCase {
    func testInitialAndActiveLoadsNeverPresentFirstRunActions() {
        for loadState in [TimelineLoadState.awaitingInitialLoad, .loading] {
            XCTAssertEqual(
                TimelineContentState.resolve(
                    hasFrames: false,
                    loadState: loadState,
                    hasTimelineIssue: false,
                    openedFromLibraryResult: false,
                    hasSelectedSession: false
                ),
                .loading
            )
        }
    }

    func testLoadedFramesRemainAvailableDuringRefreshFailure() {
        XCTAssertEqual(
            TimelineContentState.resolve(
                hasFrames: true,
                loadState: .failed,
                hasTimelineIssue: true,
                openedFromLibraryResult: false,
                hasSelectedSession: false
            ),
            .content
        )
    }

    func testSuccessfulEmptyLoadPresentsTheExistingEmptyState() {
        XCTAssertEqual(
            TimelineContentState.resolve(
                hasFrames: false,
                loadState: .ready,
                hasTimelineIssue: false,
                openedFromLibraryResult: false,
                hasSelectedSession: false
            ),
            .empty(.captureState)
        )
    }

    func testEmptyLoadedTimelinePrioritizesConcreteNavigationRecovery() {
        XCTAssertEqual(
            TimelineContentState.resolve(
                hasFrames: false,
                loadState: .ready,
                hasTimelineIssue: false,
                openedFromLibraryResult: true,
                hasSelectedSession: true
            ),
            .empty(.libraryResultUnavailable)
        )
        XCTAssertEqual(
            TimelineContentState.resolve(
                hasFrames: false,
                loadState: .ready,
                hasTimelineIssue: false,
                openedFromLibraryResult: false,
                hasSelectedSession: true
            ),
            .empty(.selectedSessionUnavailable)
        )
    }

    func testFailureWinsOnlyWhenNoUsableTimelineRemains() {
        XCTAssertEqual(
            TimelineContentState.resolve(
                hasFrames: false,
                loadState: .ready,
                hasTimelineIssue: true,
                openedFromLibraryResult: true,
                hasSelectedSession: true
            ),
            .failed
        )
    }

}
