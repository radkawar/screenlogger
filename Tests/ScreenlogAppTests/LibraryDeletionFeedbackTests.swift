import Foundation
import ScreenlogCore
import XCTest

final class LibraryDeletionFeedbackTests: XCTestCase {
    /// A deletion raised from a window must confirm in that window. Settings is
    /// the only origin that renders its own result panel.
    func testWindowOriginsReportThroughTheNoticeChannel() {
        XCTAssertEqual(LibraryDeletionOrigin.timeline.feedbackSurface, .notice)
        XCTAssertEqual(LibraryDeletionOrigin.library.feedbackSurface, .notice)
        XCTAssertEqual(LibraryDeletionOrigin.storage.feedbackSurface, .settingsPanel)
    }

    /// Regression guard: a Library deletion previously fell into the Settings
    /// branch, so finding a moment and deleting it confirmed nowhere.
    func testLibraryDeletionDoesNotRelyOnTheSettingsPanel() {
        XCTAssertNotEqual(LibraryDeletionOrigin.library.feedbackSurface, .settingsPanel)
    }

    func testIssueOriginSurvivesEveryFailureKind() {
        let request = LibraryDeletionRequest(
            selection: .moment(frameID: 7),
            origin: .library,
            title: "Delete This Moment?",
            detail: "Safari at 10:00."
        )
        let issues: [LibraryDeletionIssue] = [
            .preparationFailed(request),
            .nothingToDelete(request),
            .reviewExpired(request),
            .captureCouldNotPause(request),
        ]
        for issue in issues {
            XCTAssertEqual(
                issue.origin,
                .library,
                "a Library failure must stay on the Library surface"
            )
        }
    }
}
