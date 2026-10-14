import Foundation
import ScreenlogCore
import XCTest

@testable import ScreenlogCLI

final class CLIInteroperabilityTests: XCTestCase {
    func testStatusDocumentUsesStableTypedHealthCodes() {
        let status = DaemonStatus(
            version: "1.2.3",
            recording: false,
            pauseReason: .lowDiskSpace,
            connections: 1,
            totalFrames: nil,
            unfinalizedFrames: nil,
            screenRecording: false,
            accessibility: false,
            dataRoot: nil
        )

        let document = CLIStatusDocument(status: status)

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.health, .degraded)
        XCTAssertEqual(
            document.issues,
            [
                .dataRootUnavailable,
                .frameStatisticsUnavailable,
                .screenRecordingUnavailable,
                .accessibilityUnavailable,
                .lowDiskSpace,
            ]
        )
        XCTAssertTrue(document.warnings.isEmpty)
    }

    func testMissingRequiredAccessibilityDegradesStatus() {
        let status = DaemonStatus(
            version: "1.2.3",
            recording: true,
            connections: 1,
            totalFrames: 42,
            unfinalizedFrames: 0,
            screenRecording: true,
            accessibility: false,
            dataRoot: "/private/library"
        )

        let document = CLIStatusDocument(status: status)

        XCTAssertEqual(document.health, .degraded)
        XCTAssertEqual(document.issues, [.accessibilityUnavailable])
        XCTAssertTrue(document.warnings.isEmpty)
    }

    func testStatusJSONDoesNotSerializeLibraryPath() throws {
        let privateRoot = "/Users/private/Library/Application Support/dev.screenlog"
        let document = CLIStatusDocument(
            status: DaemonStatus(
                version: "1.2.3",
                recording: true,
                connections: 1,
                totalFrames: 42,
                unfinalizedFrames: 0,
                screenRecording: true,
                accessibility: true,
                dataRoot: privateRoot
            ))

        let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        XCTAssertFalse(json.contains(privateRoot))
        XCTAssertFalse(json.contains("dataRoot"))
        XCTAssertTrue(object["minTimestampMs"] is NSNull)
        XCTAssertTrue(object["maxTimestampMs"] is NSNull)
    }

    func testDoctorJSONDoesNotSerializePrivateFilesystemPaths() throws {
        let expectedRoot = URL(fileURLWithPath: "/Users/private/Library/Screenlogger")
        let status = DaemonStatus(
            version: "1.2.3",
            recording: true,
            connections: 1,
            totalFrames: 42,
            unfinalizedFrames: 0,
            screenRecording: true,
            accessibility: true,
            dataRoot: expectedRoot.path
        )
        let document = CLIDoctorDocument(
            root: expectedRoot,
            socketPresent: true,
            ping: "pong 1.2.3",
            status: status,
            cliVersion: "1.2.3"
        )

        let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)

        XCTAssertEqual(document.health, .ok)
        XCTAssertTrue(document.issues.isEmpty)
        XCTAssertFalse(json.contains(expectedRoot.path))
        XCTAssertFalse(json.contains("cli.sock"))
    }

    func testDoctorTreatsCompatibleProductVersionDifferenceAsWarning() throws {
        let root = URL(fileURLWithPath: "/expected")
        let report = CLIDoctorDocument(
            root: root,
            socketPresent: true,
            ping: "pong 2.0.0",
            status: DaemonStatus(
                version: "2.0.0",
                recording: true,
                connections: 1,
                totalFrames: 42,
                unfinalizedFrames: 0,
                screenRecording: true,
                accessibility: true,
                dataRoot: root.path
            ),
            cliVersion: "1.9.0"
        )

        XCTAssertEqual(report.health, .ok)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(report.warnings, [.productVersionDifference])
        XCTAssertEqual(
            ScreenlogCLIMain.doctorWarningDescription(.productVersionDifference),
            "Screenlogger.app and the screenlog command have different product versions, but their local protocol is compatible"
        )
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertTrue(json.contains(#""product_version_difference""#))
        XCTAssertFalse(json.contains("version_mismatch"))
    }

    func testDoctorSeparatesRootPermissionAndStatisticsFailures() {
        let report = CLIDoctorDocument(
            root: URL(fileURLWithPath: "/expected"),
            socketPresent: false,
            ping: "unexpected",
            status: DaemonStatus(
                version: "old",
                recording: false,
                pauseReason: .lowDiskSpace,
                connections: 0,
                totalFrames: nil,
                screenRecording: nil,
                accessibility: nil,
                dataRoot: "/different"
            ),
            cliVersion: "new"
        )

        XCTAssertEqual(report.health, .degraded)
        XCTAssertEqual(
            report.issues,
            [
                .socketUnavailable,
                .unexpectedPing,
                .dataRootMismatch,
                .screenRecordingUnavailable,
                .accessibilityUnavailable,
                .lowDiskSpace,
                .frameStatisticsUnavailable,
            ]
        )
        XCTAssertEqual(
            report.warnings,
            [.productVersionDifference]
        )
        XCTAssertFalse(report.socketPresent)
    }

    func testDoctorConnectionFailureIsTypedAndContainsNoRawError() throws {
        let report = CLIDoctorDocument(
            connectionUnavailableWithSocketPresent: false,
            cliVersion: "1.2.3"
        )
        let data = try JSONEncoder().encode(report)
        let json = String(decoding: data, as: UTF8.self)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(report.health, .degraded)
        XCTAssertEqual(report.issues, [.socketUnavailable, .bridgeUnavailable])
        XCTAssertFalse(report.bridgeConnected)
        XCTAssertNil(report.appVersion)
        XCTAssertFalse(json.contains("NSPOSIXErrorDomain"))
        XCTAssertFalse(json.contains("/Users/"))
        XCTAssertTrue(object["appVersion"] is NSNull)
        XCTAssertTrue(object["recording"] is NSNull)
    }

    func testDoctorReportsProtocolIncompatibilityWithoutRawPeerDetails() throws {
        let report = CLIDoctorDocument(
            connectionFailure: .incompatibleProtocol(
                "untrusted peer detail at /Users/private"
            ),
            socketPresent: true,
            cliVersion: "1.2.3"
        )
        let json = String(
            decoding: try JSONEncoder().encode(report),
            as: UTF8.self
        )

        XCTAssertEqual(report.health, .degraded)
        XCTAssertEqual(report.issues, [.incompatibleProtocol])
        XCTAssertFalse(report.bridgeConnected)
        XCTAssertTrue(json.contains(#""incompatible_protocol""#))
        XCTAssertFalse(json.contains("/Users/"))
        XCTAssertFalse(json.contains("untrusted peer detail"))
    }

    func testSkillLifecycleFailureCopyDoesNotExposeErrorPaths() {
        let failure = SkillInstaller.lifecycleFailureDescription(
            AssistantIntegrationError.replacementFailed(
                path: "/Users/private/.agents/skills/screenlog-cli-skill",
                reason: "NSPOSIXErrorDomain /Users/private secret"
            )
        )

        XCTAssertFalse(failure.contains("/Users/"))
        XCTAssertFalse(failure.contains("NSPOSIXErrorDomain"))
    }

    func testRemoteBridgeErrorDoesNotExposeServerDetails() {
        let error = XPCClientError.remote(
            "SQLite failed at /Users/private/Library/Application Support/dev.screenlog"
        )

        XCTAssertFalse(error.description.contains("/Users/"))
        XCTAssertFalse(error.description.contains("SQLite"))

        let protocolError = XPCClientError.incompatibleProtocol(
            "untrusted peer detail at /Users/private"
        )
        XCTAssertFalse(protocolError.description.contains("/Users/"))

    }

    func testBlockedSkillStatusNeverRecommendsIneffectiveUpgrade() {
        let remediation = SkillInstaller.statusRemediation(
            for: .blocked(.conflict),
            target: .codex
        )

        XCTAssertTrue(remediation.contains("install codex --force"))
        XCTAssertFalse(remediation.contains("skill upgrade"))
    }

    func testSkillStatusJSONUsesVersionedTypedReadyContract() throws {
        let privateDestination = URL(
            fileURLWithPath: "/Users/private/.agents/skills/screenlog-cli-skill"
        )
        let target = SkillInstaller.StatusDocument.TargetStatus(
            inspection: AssistantIntegrationInspection(
                target: .codex,
                destination: privateDestination,
                state: .currentLink,
                isRegistered: nil
            )
        )
        let document = SkillInstaller.StatusDocument(
            requestedTarget: .codex,
            targets: [target]
        )
        let data = try JSONEncoder().encode(document)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.health, .ok)
        XCTAssertEqual(document.requestedTarget, .codex)
        XCTAssertEqual(target.target, .codex)
        XCTAssertEqual(target.readiness, .ready)
        XCTAssertEqual(target.state, .currentLink)
        XCTAssertEqual(target.registration, .notRequired)
        XCTAssertEqual(target.remediation.action, .none)
        XCTAssertFalse(target.remediation.requiresConfirmation)
        XCTAssertTrue(target.issues.isEmpty)
        XCTAssertFalse(json.contains(privateDestination.path))
        XCTAssertFalse(json.contains("destination"))
    }

    func testSkillStatusJSONStripsAssociatedPathsAndUsesActionableRemediation() throws {
        let privateLink = "/Users/private/old-screenlogger-skill"
        let stale = SkillInstaller.StatusDocument.TargetStatus(
            inspection: AssistantIntegrationInspection(
                target: .claude,
                destination: URL(fileURLWithPath: "/Users/private/.claude/skills/skill"),
                state: .staleLink(privateLink),
                isRegistered: nil
            )
        )
        let blocked = SkillInstaller.StatusDocument.TargetStatus(
            inspection: AssistantIntegrationInspection(
                target: .cursor,
                destination: URL(fileURLWithPath: "/Users/private/.cursor/skills/skill"),
                state: .brokenLink("/Users/private/missing"),
                isRegistered: nil
            )
        )
        let unregistered = SkillInstaller.StatusDocument.TargetStatus(
            inspection: AssistantIntegrationInspection(
                target: .openclaw,
                destination: URL(fileURLWithPath: "/Users/private/Library/skill"),
                state: .currentCopy,
                isRegistered: false
            )
        )
        let document = SkillInstaller.StatusDocument(
            requestedTarget: .all,
            targets: [stale, blocked, unregistered]
        )
        let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)

        XCTAssertEqual(document.health, .degraded)
        XCTAssertEqual(document.remediation.action, .reviewTargets)
        XCTAssertEqual(stale.readiness, .updateAvailable)
        XCTAssertEqual(stale.state, .staleLink)
        XCTAssertEqual(stale.remediation.action, .upgrade)
        XCTAssertFalse(stale.remediation.requiresConfirmation)
        XCTAssertEqual(blocked.readiness, .blocked)
        XCTAssertEqual(blocked.state, .brokenLink)
        XCTAssertEqual(blocked.remediation.action, .forceInstall)
        XCTAssertTrue(blocked.remediation.requiresConfirmation)
        XCTAssertEqual(unregistered.readiness, .setupIncomplete)
        XCTAssertEqual(unregistered.registration, .notRegistered)
        XCTAssertEqual(unregistered.remediation.action, .upgrade)
        XCTAssertFalse(json.contains(privateLink))
        XCTAssertFalse(json.contains("/Users/private"))
    }

    func testSkillStatusInspectionFailureUsesPrivacySafeCodes() throws {
        let rawError = AssistantIntegrationError.malformedConfiguration(
            "invalid at /Users/private/.openclaw/openclaw.json"
        )
        let issue = SkillInstaller.statusIssue(for: rawError)
        let target = SkillInstaller.StatusDocument.TargetStatus(
            target: .openclaw,
            issue: issue
        )
        let document = SkillInstaller.StatusDocument(
            requestedTarget: .openclaw,
            targets: [target]
        )
        let json = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)

        XCTAssertEqual(issue, .configurationInvalid)
        XCTAssertEqual(document.health, .degraded)
        XCTAssertEqual(target.readiness, .unavailable)
        XCTAssertEqual(target.state, .unavailable)
        XCTAssertEqual(target.registration, .unknown)
        XCTAssertEqual(target.remediation.action, .reviewConfiguration)
        XCTAssertTrue(target.remediation.requiresConfirmation)
        XCTAssertEqual(target.issues, [.configurationInvalid])
        XCTAssertFalse(json.contains("/Users/private"))
        XCTAssertFalse(json.contains("invalid at"))
    }

    func testSkillStatusExternalPrerequisitesNeverRecommendIneffectiveInstall() throws {
        let configurationUnavailable = SkillInstaller.StatusDocument.TargetStatus(
            target: .openclaw,
            issue: .configurationUnavailable
        )
        let noTargets = SkillInstaller.StatusDocument(
            requestedTarget: .all,
            targets: [],
            issues: [.noTargetsDetected]
        )
        let json = String(decoding: try JSONEncoder().encode(noTargets), as: UTF8.self)

        XCTAssertEqual(
            configurationUnavailable.remediation.action,
            .installOrOpenAssistant
        )
        XCTAssertFalse(configurationUnavailable.remediation.requiresConfirmation)
        XCTAssertEqual(noTargets.health, .degraded)
        XCTAssertEqual(noTargets.remediation.action, .selectTarget)
        XCTAssertFalse(noTargets.remediation.requiresConfirmation)
        XCTAssertTrue(json.contains(#""action":"select_target""#))
        XCTAssertFalse(json.contains(#""action":"install""#))
    }
}
