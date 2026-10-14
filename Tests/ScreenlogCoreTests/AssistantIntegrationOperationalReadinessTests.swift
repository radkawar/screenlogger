import XCTest

@testable import ScreenlogCore

final class AssistantIntegrationOperationalReadinessTests: XCTestCase {
    private let evaluator = AssistantIntegrationOperationalReadinessEvaluator()
    private let managedCommandPath = "/Users/example/.local/bin/screenlog"

    func testAbsentOrUnusableHostIsTheFirstBlocker() {
        var inputs = readyInputs()
        inputs = replacing(inputs, host: .notDetected)

        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(.assistantHost(.notDetected))
        )

        inputs = replacing(inputs, host: .notUsable)
        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(.assistantHost(.notUsable))
        )

        let everyStageBlocked = AssistantIntegrationOperationalInputs(
            host: .notDetected,
            integrationFiles: .notInstalled,
            managedCLI: .notInstalled,
            shellCommand: .missing,
            bridge: .disabled,
            liveVerification: .notRun
        )
        XCTAssertEqual(
            evaluator.evaluate(everyStageBlocked),
            .blocked(.assistantHost(.notDetected))
        )
    }

    func testIntegrationFilesMustBeCurrentBeforeLocalToolChecks() {
        var inputs = readyInputs()
        inputs = replacing(
            inputs,
            integrationFiles: .notInstalled,
            managedCLI: .notInstalled
        )
        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(.integrationFiles(.notInstalled))
        )

        inputs = replacing(inputs, integrationFiles: .setupIncomplete)
        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(.integrationFiles(.setupIncomplete))
        )

        inputs = replacing(inputs, integrationFiles: .updateAvailable)
        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(.integrationFiles(.updateAvailable))
        )
    }

    func testSkillOnlySetupStopsAtMissingManagedCLI() {
        let inputs = replacing(readyInputs(), managedCLI: .notInstalled)

        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(.managedCLI(.notInstalled))
        )
    }

    func testOutdatedOrUnverifiableManagedCLIIsNotOperational() {
        var inputs = replacing(
            readyInputs(),
            managedCLI: .updateAvailable(path: managedCommandPath)
        )
        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(.managedCLI(.updateAvailable))
        )

        inputs = replacing(
            inputs,
            managedCLI: .verificationUnavailable(path: managedCommandPath)
        )
        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(.managedCLI(.verificationUnavailable))
        )
    }

    func testMissingShellCommandIncludesExpectedManagedPath() {
        let inputs = replacing(readyInputs(), shellCommand: .missing)

        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(
                .shellCommand(.missing(expectedPath: managedCommandPath))
            )
        )
    }

    func testFailedShellCheckIsDistinctFromAMissingCommand() {
        let inputs = replacing(readyInputs(), shellCommand: .checkFailed)

        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(
                .shellCommand(.checkFailed(expectedPath: managedCommandPath))
            )
        )
    }

    func testShadowedShellCommandIncludesExpectedAndResolvedPaths() {
        let shadowPath = "/opt/homebrew/bin/screenlog"
        let inputs = replacing(
            readyInputs(),
            shellCommand: .resolved(path: shadowPath)
        )

        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(
                .shellCommand(
                    .shadowed(
                        expectedPath: managedCommandPath,
                        resolvedPath: shadowPath
                    )
                )
            )
        )
    }

    func testEquivalentStandardizedShellPathIsAccepted() {
        let inputs = replacing(
            readyInputs(),
            shellCommand: .resolved(
                path: "/Users/example/.local/bin/../bin/screenlog"
            )
        )

        XCTAssertEqual(evaluator.evaluate(inputs), .localConnectionVerified)
    }

    func testDisabledAndUnavailableBridgeRemainDistinct() {
        var inputs = replacing(readyInputs(), bridge: .disabled)
        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(.bridge(.disabled))
        )

        inputs = replacing(inputs, bridge: .unavailable(.notListening))
        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(.bridge(.unavailable(.notListening)))
        )
    }

    func testVerificationFailureAndVersionMismatchRemainDistinct() {
        var inputs = replacing(
            readyInputs(),
            liveVerification: .failed(.commandFailed)
        )
        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(.liveVerification(.failed(.commandFailed)))
        )

        inputs = replacing(
            inputs,
            liveVerification: .failed(.versionMismatch)
        )
        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(.liveVerification(.failed(.versionMismatch)))
        )

        inputs = replacing(
            inputs,
            liveVerification: .failed(.protocolMismatch)
        )
        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(.liveVerification(.failed(.protocolMismatch)))
        )
    }

    func testLiveVerificationMustActuallyRun() {
        let inputs = replacing(readyInputs(), liveVerification: .notRun)

        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(.liveVerification(.notRun))
        )
    }

    func testEverySatisfiedLocalRequirementAllowsReviewedHandoff() {
        let readiness = evaluator.evaluate(readyInputs())

        XCTAssertEqual(readiness, .localConnectionVerified)
        XCTAssertTrue(readiness.canOfferReviewedHandoff)
        XCTAssertNil(readiness.blocker)
    }

    func testAbsentHostStillAllowsConflictRecovery() {
        let inputs = replacing(
            readyInputs(),
            host: .notDetected,
            integrationFiles: .blocked(.conflict)
        )
        XCTAssertEqual(
            evaluator.evaluate(inputs),
            .blocked(.integrationFiles(.blocked(.conflict)))
        )
    }

    private func readyInputs() -> AssistantIntegrationOperationalInputs {
        AssistantIntegrationOperationalInputs(
            host: .usable,
            integrationFiles: .ready,
            managedCLI: .ready(path: managedCommandPath),
            shellCommand: .resolved(path: managedCommandPath),
            bridge: .available(socketPath: "/tmp/screenlog/cli.sock"),
            liveVerification: .succeeded
        )
    }

    private func replacing(
        _ inputs: AssistantIntegrationOperationalInputs,
        host: AssistantIntegrationHostState? = nil,
        integrationFiles: AssistantIntegrationReadiness? = nil,
        managedCLI: CLIInstallState? = nil,
        shellCommand: AssistantIntegrationShellCommandResolution? = nil,
        bridge: CLIConnectionState? = nil,
        liveVerification: AssistantIntegrationLiveVerificationState? = nil
    ) -> AssistantIntegrationOperationalInputs {
        AssistantIntegrationOperationalInputs(
            host: host ?? inputs.host,
            integrationFiles: integrationFiles ?? inputs.integrationFiles,
            managedCLI: managedCLI ?? inputs.managedCLI,
            shellCommand: shellCommand ?? inputs.shellCommand,
            bridge: bridge ?? inputs.bridge,
            liveVerification: liveVerification ?? inputs.liveVerification
        )
    }
}
