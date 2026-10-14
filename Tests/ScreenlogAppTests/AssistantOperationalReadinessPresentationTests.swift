import ScreenlogCore
import XCTest

final class AssistantOperationalReadinessPresentationTests: XCTestCase {
    func testAbsentHostNeverLooksInstalledOrActionable() {
        let presentation = AssistantOperationalReadinessPresentation.make(
            readiness: .blocked(.assistantHost(.notDetected)),
            target: .codex
        )

        XCTAssertEqual(presentation.tone, .neutral)
        XCTAssertEqual(presentation.primaryAction, .none)
        XCTAssertNil(presentation.actionTitle)
    }

    func testCurrentFilesWithMissingCommandRoutesToCommandSetup() {
        let presentation = AssistantOperationalReadinessPresentation.make(
            readiness: .blocked(.managedCLI(.notInstalled)),
            target: .claude
        )

        XCTAssertEqual(presentation.primaryAction, .openLocalTools)
        XCTAssertFalse(presentation.detail.contains("ready"))
    }

    func testShadowedCommandExplainsTheExactProblem() {
        let presentation = AssistantOperationalReadinessPresentation.make(
            readiness: .blocked(
                .shellCommand(
                    .shadowed(
                        expectedPath: "/managed/screenlog",
                        resolvedPath: "/other/screenlog"
                    )
                )
            ),
            target: .cursor
        )

        XCTAssertTrue(presentation.detail.contains("different"))
        XCTAssertEqual(presentation.primaryAction, .openLocalTools)
    }

    func testProtocolMismatchAndAppUnavailableHaveDifferentRecoveryCopy() {
        let protocolMismatch = AssistantOperationalReadinessPresentation.make(
            readiness: .blocked(.liveVerification(.failed(.protocolMismatch))),
            target: .openclaw
        )
        let appUnavailable = AssistantOperationalReadinessPresentation.make(
            readiness: .blocked(.liveVerification(.failed(.appUnavailable))),
            target: .openclaw
        )

        XCTAssertNotEqual(protocolMismatch.detail, appUnavailable.detail)
    }

    func testVerifiedConnectionExplicitlyDisclaimsHostSpecificTest() {
        let presentation = AssistantOperationalReadinessPresentation.make(
            readiness: .localConnectionVerified,
            target: .codex
        )

        XCTAssertEqual(presentation.tone, .success)
        XCTAssertTrue(presentation.detail.contains("Terminal command"))
        XCTAssertTrue(presentation.detail.contains("has not tested a search inside Codex"))
        XCTAssertFalse(presentation.detail.contains("Ready to use"))
    }

    func testLiveVerificationRoutesToTheSingleCommandSetupAction() {
        let notRun = AssistantOperationalReadinessPresentation.make(
            readiness: .blocked(.liveVerification(.notRun)),
            target: .codex
        )

        XCTAssertEqual(notRun.primaryAction, .openLocalTools)
    }
}
