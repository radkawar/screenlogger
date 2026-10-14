@testable import ScreenlogCore
import XCTest

final class AssistantIntegrationActionNoticeTests: XCTestCase {
    func testNoticeSeverityIsExplicitForEveryActionOutcome() {
        XCTAssertEqual(AssistantIntegrationActionNotice.installed(.claude).severity, .success)
        XCTAssertEqual(AssistantIntegrationActionNotice.verified(.cursor).severity, .success)
        XCTAssertEqual(AssistantIntegrationActionNotice.removed(.codex).severity, .success)
        XCTAssertEqual(AssistantIntegrationActionNotice.alreadyRemoved(.claude).severity, .information)
        XCTAssertEqual(AssistantIntegrationActionNotice.inspectionUnchanged(.cursor).severity, .information)
        XCTAssertEqual(AssistantIntegrationActionNotice.inspectionUnavailable(.codex).severity, .failure)
        XCTAssertEqual(
            AssistantIntegrationActionNotice.failed(.replacementFailed).severity,
            .failure
        )
    }

    func testSuccessfulNoticesUseStablePrivacySafeCopy() {
        let notices: [AssistantIntegrationActionNotice] = [
            .installed(.claude),
            .verified(.cursor),
            .removed(.codex),
            .alreadyRemoved(.claude),
            .inspectionAvailableAgain(.cursor),
            .inspectionCurrent(.codex),
            .inspectionUnchanged(.openclaw),
        ]
        for notice in notices {
            XCTAssertFalse(notice.message.contains("/Users/"))
        }
    }

    func testTypedIntegrationErrorsMapToStableFailureCopy() {
        XCTAssertEqual(
            AssistantIntegrationActionFailure(.sourceMissing("private path")),
            .resourcesUnavailable
        )
        XCTAssertEqual(
            AssistantIntegrationActionFailure(.destinationNotOwned("private path")),
            .destinationConflict
        )
        XCTAssertEqual(
            AssistantIntegrationActionFailure(.replacementFailed(path: "private", reason: "details")),
            .replacementFailed
        )
        for failure in [
            AssistantIntegrationActionFailure.resourcesUnavailable,
            .configurationUnavailable,
            .malformedConfiguration,
            .updateRequired,
            .destinationConflict,
            .unsafeDestination,
            .replacementFailed,
            .unknown,
        ] {
            XCTAssertFalse(failure.message.contains("private"))
        }
    }

}
