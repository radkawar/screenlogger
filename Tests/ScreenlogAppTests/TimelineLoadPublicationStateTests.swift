import XCTest

final class TimelineLoadPublicationStateTests: XCTestCase {
    func testOlderSessionReadCannotReplaceNewerMomentNavigationOrFinishItsLoadingState() {
        var state = TimelineLoadPublicationState()
        let session = state.beginLoad()
        let moment = state.beginLoad()

        XCTAssertFalse(state.allowsLoad(session))
        XCTAssertFalse(state.finishLoad(session))
        XCTAssertNil(state.backgroundSnapshot)
        XCTAssertTrue(state.allowsLoad(moment))
        XCTAssertTrue(state.finishLoad(moment))
        XCTAssertNotNil(state.backgroundSnapshot)
    }

    func testCapturedFrameRefreshCannotPullSelectionBackAfterScrubbing() {
        var state = TimelineLoadPublicationState()
        let refresh = state.backgroundSnapshot
        XCTAssertTrue(state.allowsBackgroundRefresh(refresh))

        state.selectionDidChange()

        XCTAssertFalse(state.allowsBackgroundRefresh(refresh))
        XCTAssertTrue(state.allowsBackgroundRefresh(state.backgroundSnapshot))
    }

    func testBackgroundReadCannotReplaceNewSessionEvenAfterNavigationFinishes() {
        var state = TimelineLoadPublicationState()
        let refresh = state.backgroundSnapshot
        let session = state.beginLoad()

        XCTAssertFalse(state.allowsBackgroundRefresh(refresh))
        XCTAssertNil(state.backgroundSnapshot)
        state.finishLoad(session)
        XCTAssertFalse(state.allowsBackgroundRefresh(refresh))
    }

    func testRefreshStartedDuringNavigationNeverOwnsTheLoadedWindow() {
        var state = TimelineLoadPublicationState()
        let moment = state.beginLoad()
        let refresh = state.backgroundSnapshot
        state.finishLoad(moment)

        XCTAssertFalse(state.allowsBackgroundRefresh(refresh))
        XCTAssertTrue(state.allowsBackgroundRefresh(state.backgroundSnapshot))
    }

    func testLibraryReplacementInvalidatesOldNavigationAndRefreshes() {
        var state = TimelineLoadPublicationState()
        let refresh = state.backgroundSnapshot
        let moment = state.beginLoad()

        state.invalidate()

        XCTAssertFalse(state.allowsLoad(moment))
        XCTAssertFalse(state.finishLoad(moment))
        XCTAssertFalse(state.allowsBackgroundRefresh(refresh))
        XCTAssertNotNil(state.backgroundSnapshot)
    }
}
