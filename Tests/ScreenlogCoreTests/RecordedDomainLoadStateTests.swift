import XCTest

@testable import ScreenlogCore

final class RecordedDomainLoadStateTests: XCTestCase {
    func testIssuesExposeStablePrivacySafeCopyAndRetryRecovery() {
        for issue in RecordedDomainLoadIssue.allCases {
            XCTAssertEqual(issue.recoveryAction, .retry)
            XCTAssertFalse(issue.message.contains("/Users/"))
            XCTAssertFalse(issue.message.contains("SQLite"))
        }
    }

    func testLoadStateExposesOnlyTypedFailureIssues() {
        XCTAssertTrue(RecordedDomainLoadState.loading.isLoading)
        XCTAssertNil(RecordedDomainLoadState.loading.issue)
        XCTAssertFalse(RecordedDomainLoadState.loaded.isLoading)
        XCTAssertNil(RecordedDomainLoadState.loaded.issue)

        let state = RecordedDomainLoadState.failed(.queryFailed)
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.issue, .queryFailed)
    }
}
