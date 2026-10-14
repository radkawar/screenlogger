import Foundation
@testable import ScreenlogCore
import XCTest

final class AssistantIntegrationServiceTests: XCTestCase {
    func testAutomaticMaintenanceOnlySelectsOwnedStaleOrIncompleteIntegrations() {
        let destination = URL(fileURLWithPath: "/tmp/screenlog-cli-skill", isDirectory: true)
        let inspection: (AssistantIntegrationState, Bool?) -> AssistantIntegrationInspection = {
            state, registered in
            AssistantIntegrationInspection(
                target: .codex,
                destination: destination,
                state: state,
                isRegistered: registered
            )
        }

        XCTAssertTrue(inspection(.staleCopy, nil).needsAutomaticMaintenance)
        XCTAssertTrue(inspection(.currentCopy, false).needsAutomaticMaintenance)
        XCTAssertFalse(inspection(.currentCopy, nil).needsAutomaticMaintenance)
        XCTAssertFalse(inspection(.missing, nil).needsAutomaticMaintenance)
        XCTAssertFalse(inspection(.brokenLink("missing"), nil).needsAutomaticMaintenance)
        XCTAssertFalse(inspection(.conflict, nil).needsAutomaticMaintenance)
    }

    func testSupportedTargetsAndDestinationsAreCanonical() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let service = AssistantIntegrationService(homeDirectory: home, environment: [:])

        XCTAssertEqual(
            try service.destination(for: .claude).path,
            "/Users/example/.claude/skills/screenlog-cli-skill"
        )
        XCTAssertEqual(
            try service.destination(for: .cursor).path,
            "/Users/example/.cursor/skills/screenlog-cli-skill"
        )
        XCTAssertEqual(
            try service.destination(for: .codex).path,
            "/Users/example/.agents/skills/screenlog-cli-skill"
        )
        XCTAssertEqual(
            try service.destination(for: .grok).path,
            "/Users/example/.grok/skills/screenlog-cli-skill"
        )
        XCTAssertEqual(
            try AssistantIntegrationService(
                homeDirectory: home,
                environment: ["GROK_HOME": "/Volumes/Agent Data/Grok"]
            ).destination(for: .grok).path,
            "/Volumes/Agent Data/Grok/skills/screenlog-cli-skill"
        )
        XCTAssertEqual(
            try service.destination(for: .openclaw).path,
            "/Users/example/Library/Application Support/dev.screenlog/skill/screenlog-cli-skill"
        )
        XCTAssertEqual(
            Set(AssistantIntegrationTarget.allCases.map(\.rawValue)),
            ["claude", "cursor", "codex", "grok", "openclaw"]
        )
    }

    func testInvalidGrokHomeIsRejectedWithoutAWriteFallback() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let service = AssistantIntegrationService(
            homeDirectory: home,
            environment: ["GROK_HOME": "relative/path"]
        )
        XCTAssertThrowsError(try service.destination(for: .grok)) { error in
            guard case AssistantIntegrationError.unsafeDestination = error else {
                return XCTFail("Expected unsafeDestination, got \(error)")
            }
        }
    }

    func testStateDistinguishesCurrentStaleBrokenAndConflict() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service

        XCTAssertEqual(
            service.installationState(at: fixture.destination, source: fixture.source),
            .missing
        )
        try FileManager.default.copyItem(at: fixture.source, to: fixture.destination)
        XCTAssertEqual(
            service.installationState(at: fixture.destination, source: fixture.source),
            .currentCopy
        )
        try fixture.writeManifest("stale", at: fixture.destination)
        XCTAssertEqual(
            service.installationState(at: fixture.destination, source: fixture.source),
            .staleCopy
        )

        try FileManager.default.removeItem(at: fixture.destination)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.destination.path,
            withDestinationPath: fixture.root.appendingPathComponent("missing").path
        )
        guard
            case .brokenLink = service.installationState(
                at: fixture.destination,
                source: fixture.source
            )
        else { return XCTFail("Expected broken link") }

        try FileManager.default.removeItem(at: fixture.destination)
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(
            to: fixture.destination.appendingPathComponent("README.md")
        )
        XCTAssertEqual(
            service.installationState(at: fixture.destination, source: fixture.source),
            .conflict
        )
    }

    func testInstallUpgradeAndReinstallHaveExplicitOwnershipRules() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let installed = try fixture.service.install(
            target: .codex,
            source: fixture.source,
            mode: .install,
            skillsDirectoryOverride: fixture.skills
        )
        XCTAssertTrue(installed.changed)
        XCTAssertTrue(installed.inspection.isCurrent)
        XCTAssertEqual(installed.inspection.state, .currentCopy)
        XCTAssertThrowsError(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.destination.path
            )
        )

        try FileManager.default.removeItem(at: fixture.destination)
        try FileManager.default.copyItem(at: fixture.source, to: fixture.destination)
        try fixture.writeManifest("stale", at: fixture.destination)
        XCTAssertThrowsError(
            try fixture.service.install(
                target: .codex,
                source: fixture.source,
                mode: .install,
                skillsDirectoryOverride: fixture.skills
            )
        ) { error in
            guard case AssistantIntegrationError.destinationNeedsUpgrade = error else {
                return XCTFail("Expected destinationNeedsUpgrade, got \(error)")
            }
        }

        let upgraded = try fixture.service.install(
            target: .codex,
            source: fixture.source,
            mode: .upgrade,
            skillsDirectoryOverride: fixture.skills
        )
        XCTAssertTrue(upgraded.changed)
        XCTAssertTrue(upgraded.inspection.isCurrent)

        let reinstalled = try fixture.service.install(
            target: .codex,
            source: fixture.source,
            mode: .reinstallOwned,
            skillsDirectoryOverride: fixture.skills
        )
        XCTAssertTrue(reinstalled.changed)
        XCTAssertTrue(reinstalled.inspection.isCurrent)
    }

    func testConflictIsPreservedUnlessForceIsExplicit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        let unrelated = fixture.destination.appendingPathComponent("README.md")
        try Data("keep me".utf8).write(to: unrelated)

        XCTAssertThrowsError(
            try fixture.service.install(
                target: .codex,
                source: fixture.source,
                mode: .reinstallOwned,
                skillsDirectoryOverride: fixture.skills
            )
        ) { error in
            guard case AssistantIntegrationError.destinationNotOwned = error else {
                return XCTFail("Expected destinationNotOwned, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep me".utf8))

        let forced = try fixture.service.install(
            target: .codex,
            source: fixture.source,
            mode: .force,
            skillsDirectoryOverride: fixture.skills
        )
        XCTAssertTrue(forced.inspection.isCurrent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testRemoveAllowsOwnedStaleContentButRefusesBrokenLink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.copyItem(at: fixture.source, to: fixture.destination)
        try fixture.writeManifest("stale", at: fixture.destination)

        let removed = try fixture.service.remove(
            target: .codex,
            source: fixture.source,
            skillsDirectoryOverride: fixture.skills
        )
        XCTAssertTrue(removed.changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))

        try FileManager.default.createSymbolicLink(
            atPath: fixture.destination.path,
            withDestinationPath: fixture.root.appendingPathComponent("missing").path
        )
        XCTAssertThrowsError(
            try fixture.service.remove(
                target: .codex,
                source: fixture.source,
                skillsDirectoryOverride: fixture.skills
            )
        )
        XCTAssertNoThrow(
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.path)
        )
    }

    func testSourceValidationRejectsSymlinkedOrUnboundedTreesBeforePublication() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let externalManifest = fixture.root.appendingPathComponent("external-SKILL.md")
        try Data(
            "---\nname: \(AssistantIntegrationService.skillFolderName)\n---\nuntrusted".utf8
        ).write(to: externalManifest)
        try FileManager.default.removeItem(
            at: fixture.source.appendingPathComponent("SKILL.md")
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appendingPathComponent("SKILL.md"),
            withDestinationURL: externalManifest
        )

        XCTAssertThrowsError(
            try fixture.service.install(
                target: .codex,
                source: fixture.source,
                mode: .install,
                skillsDirectoryOverride: fixture.skills
            )
        ) { error in
            guard case AssistantIntegrationError.sourceMissing = error else {
                return XCTFail("Expected an invalid-source failure, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))

        try FileManager.default.removeItem(
            at: fixture.source.appendingPathComponent("SKILL.md")
        )
        try fixture.writeManifest("current", at: fixture.source)
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appendingPathComponent("linked-reference"),
            withDestinationURL: externalManifest
        )
        XCTAssertThrowsError(try fixture.service.verifiedSkillSource(fixture.source))
    }

    func testReplacementRejectsSourceDestinationAncestryBeforeStaging() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let nestedDestination = fixture.source
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(
                AssistantIntegrationService.skillFolderName,
                isDirectory: true
            )

        XCTAssertThrowsError(
            try fixture.service.replaceSkill(
                at: nestedDestination,
                source: fixture.source,
                removeExisting: false,
                preferCopy: true
            )
        ) { error in
            guard case AssistantIntegrationError.unsafeDestination = error else {
                return XCTFail("Expected an unsafe-destination failure, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.source.appendingPathComponent("skills").path
            )
        )

        XCTAssertThrowsError(
            try fixture.service.replaceSkill(
                at: fixture.root,
                source: fixture.source,
                removeExisting: true,
                preferCopy: true,
                allowUnowned: true
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testManifestSymlinkNeverAuthenticatesDestinationOwnership() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let externalManifest = fixture.root.appendingPathComponent("external-SKILL.md")
        try Data(
            "---\nname: \(AssistantIntegrationService.skillFolderName)\n---\nstale".utf8
        ).write(to: externalManifest)
        try FileManager.default.createDirectory(
            at: fixture.destination,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.destination.appendingPathComponent("SKILL.md"),
            withDestinationURL: externalManifest
        )

        XCTAssertEqual(
            fixture.service.installationState(
                at: fixture.destination,
                source: fixture.source
            ),
            .conflict
        )
        XCTAssertThrowsError(
            try fixture.service.remove(
                target: .codex,
                source: fixture.source,
                skillsDirectoryOverride: fixture.skills
            )
        )
        XCTAssertNoThrow(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.destination.appendingPathComponent("SKILL.md").path
            )
        )
    }

    func testOpenClawInstallAndRemovePreserveUnrelatedConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service
        let config = service.openClawConfigURL()
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(
            withJSONObject: ["unrelated": ["enabled": true]]
        ).write(to: config)

        let installed = try service.install(
            target: .openclaw,
            source: fixture.source,
            mode: .install
        )
        XCTAssertTrue(installed.inspection.isCurrent)
        XCTAssertEqual(installed.changedURLs.count, 2)

        let registered = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
        )
        XCTAssertNotNil(registered["unrelated"])

        let removed = try service.remove(target: .openclaw, source: fixture.source)
        XCTAssertEqual(removed.changedURLs.count, 2)
        XCTAssertFalse(
            try service.openClawRegistration(
                configURL: config,
                skillHome: service.openClawSkillHome()
            )
        )
    }

    func testOpenClawRegistrationRollsBackWhenSkillMutationFails() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = fixture.service
        let config = service.openClawConfigURL()
        let skillHome = service.openClawSkillHome()
        let destination = try service.destination(for: .openclaw)
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"unrelated":true}"#.utf8).write(to: config)
        try FileManager.default.createDirectory(
            at: skillHome,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: skillHome.path
            )
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: skillHome.path
        )
        XCTAssertThrowsError(
            try service.install(
                target: .openclaw,
                source: fixture.source,
                mode: .install
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: skillHome.path
        )
        XCTAssertFalse(
            try service.openClawRegistration(
                configURL: config,
                skillHome: skillHome
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        _ = try service.install(
            target: .openclaw,
            source: fixture.source,
            mode: .install
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: skillHome.path
        )
        XCTAssertThrowsError(
            try service.remove(target: .openclaw, source: fixture.source)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: skillHome.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(
            try service.openClawRegistration(
                configURL: config,
                skillHome: skillHome
            )
        )
    }

    func testMalformedOpenClawConfigCannotPartiallyInstall() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let config = fixture.service.openClawConfigURL()
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data(#"{"skills":"unexpected","unrelated":true}"#.utf8)
        try original.write(to: config)

        XCTAssertThrowsError(
            try fixture.service.install(
                target: .openclaw,
                source: fixture.source,
                mode: .install
            )
        )
        XCTAssertEqual(try Data(contentsOf: config), original)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try fixture.service.destination(for: .openclaw).path
            )
        )
    }

    func testSymlinkedOpenClawConfigurationIsRejectedAndLeftUnchanged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let config = fixture.service.openClawConfigURL()
        let externalConfig = fixture.root.appendingPathComponent("external-openclaw.json")
        let original = Data(#"{"unrelated":true}"#.utf8)
        try original.write(to: externalConfig)
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: config,
            withDestinationURL: externalConfig
        )

        XCTAssertThrowsError(
            try fixture.service.install(
                target: .openclaw,
                source: fixture.source,
                mode: .install
            )
        ) { error in
            guard case AssistantIntegrationError.malformedConfiguration = error else {
                return XCTFail("Expected a configuration safety failure, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: externalConfig), original)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try fixture.service.destination(for: .openclaw).path
            )
        )
    }

    func testCodexInstallIgnoresAndPreservesFormerIntegrationLocation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let formerLocation = fixture.home
            .appendingPathComponent(".codex/skills/screenlog-cli-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: formerLocation, withIntermediateDirectories: true)
        let unrelated = formerLocation.appendingPathComponent("README.md")
        try Data("keep me".utf8).write(to: unrelated)

        let before = try fixture.service.inspect(target: .codex, source: fixture.source)
        XCTAssertEqual(before.state, .missing)
        XCTAssertEqual(before.readiness, .notInstalled)
        XCTAssertFalse(before.isOwned)

        let change = try fixture.service.install(
            target: .codex,
            source: fixture.source,
            mode: .install
        )
        let canonical = try fixture.service.destination(for: .codex)
        XCTAssertTrue(change.inspection.isCurrent)
        XCTAssertEqual(change.inspection.readiness, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonical.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep me".utf8))
        XCTAssertEqual(change.changedURLs, [canonical])
    }

    func testTypedReadinessSeparatesSetupUpdateAndBlockedStates() {
        let destination = URL(fileURLWithPath: "/tmp/screenlog-integration")
        XCTAssertEqual(
            AssistantIntegrationInspection(
                target: .openclaw,
                destination: destination,
                state: .currentCopy,
                isRegistered: false
            ).readiness,
            .setupIncomplete
        )
        XCTAssertEqual(
            AssistantIntegrationInspection(
                target: .codex,
                destination: destination,
                state: .staleCopy,
                isRegistered: nil
            ).readiness,
            .updateAvailable
        )
        XCTAssertEqual(
            AssistantIntegrationInspection(
                target: .cursor,
                destination: destination,
                state: .conflict,
                isRegistered: nil
            ).readiness,
            .blocked(.conflict)
        )
    }

    func testTypedCLIStatesExposeOnlyRelevantDerivedValues() {
        let socket = CLIConnectionState.available(socketPath: "/tmp/screenlog/cli.sock")
        XCTAssertTrue(socket.isAvailable)
        XCTAssertNil(socket.failure)
        XCTAssertEqual(
            CLIConnectionState.unavailable(.notListening).failure,
            .notListening
        )

        let ready = CLIInstallState.ready(path: "/tmp/bin/screenlog")
        XCTAssertEqual(ready.commandPath, "/tmp/bin/screenlog")
        XCTAssertTrue(ready.isReady)
        XCTAssertTrue(ready.canRemove)
        XCTAssertFalse(ready.isInstalling)
        XCTAssertFalse(ready.isBusy)
        XCTAssertTrue(CLIInstallState.installing.isBusy)
        XCTAssertTrue(CLIInstallState.removing.isBusy)
        XCTAssertFalse(
            CLIInstallState.updateAvailable(path: "/tmp/bin/screenlog").isReady
        )
        XCTAssertTrue(
            CLIInstallState.updateAvailable(path: "/tmp/bin/screenlog").canRemove
        )
        XCTAssertTrue(
            CLIInstallState.verificationUnavailable(path: "/tmp/bin/screenlog").canRemove
        )
        XCTAssertEqual(
            CLIInstallState.failed(.artifactsUnavailable).failure,
            .artifactsUnavailable
        )
        XCTAssertEqual(
            CLIInstallState.failed(.artifactsInvalid).failure,
            .artifactsInvalid
        )
        XCTAssertEqual(
            CLIInstallState.failed(.removalFailed).failure,
            .removalFailed
        )
        XCTAssertFalse(CLIInstallFailure.installationFailed.localizedDescription.contains("/"))
        let conflict = CLIArtifactConflict.unrecognized(existing: ["/tmp/bin/screenlog"])
        XCTAssertEqual(CLIInstallState.conflict(conflict).conflict, conflict)
        XCTAssertNil(CLIInstallState.conflict(conflict).failure)
    }

    func testCLIArtifactInspectionMapsToTruthfulReadiness() {
        let path = "/tmp/bin/screenlog"

        XCTAssertEqual(
            CLIInstallState(
                inspection: .current,
                commandPath: path,
                bundledArtifactsAvailable: true
            ),
            .ready(path: path)
        )
        XCTAssertEqual(
            CLIInstallState(
                inspection: .managed,
                commandPath: path,
                bundledArtifactsAvailable: true
            ),
            .updateAvailable(path: path)
        )
        XCTAssertEqual(
            CLIInstallState(
                inspection: .managed,
                commandPath: path,
                bundledArtifactsAvailable: false
            ),
            .verificationUnavailable(path: path)
        )
        let conflict = CLIArtifactConflict.invalidReceipt("/tmp/receipt")
        XCTAssertEqual(
            CLIInstallState(
                inspection: .conflict(conflict),
                commandPath: path,
                bundledArtifactsAvailable: true
            ),
            .conflict(conflict)
        )
    }

    func testIntegrationErrorsDoNotExposePathsOrSystemDetails() {
        let errors: [AssistantIntegrationError] = [
            .sourceMissing("/Users/private/source"),
            .configMissing("/Users/private/.openclaw/openclaw.json"),
            .malformedConfiguration("NSCocoaErrorDomain /Users/private"),
            .destinationNeedsUpgrade("/Users/private/.agents/skills"),
            .destinationNotOwned("/Users/private/.agents/skills"),
            .unsafeDestination("/Users/private"),
            .replacementFailed(
                path: "/Users/private/.agents/skills",
                reason: "NSPOSIXErrorDomain secret"
            ),
        ]

        for error in errors {
            XCTAssertFalse(error.localizedDescription.contains("/Users/"))
            XCTAssertFalse(error.localizedDescription.contains("NSPOSIXErrorDomain"))
            XCTAssertFalse(error.localizedDescription.contains("NSCocoaErrorDomain"))
        }

        XCTAssertFalse(
            AssistantIntegrationState.staleLink("/Users/private/old-skill")
                .statusDescription.contains("/Users/")
        )
        XCTAssertFalse(
            AssistantIntegrationState.brokenLink("/Users/private/missing")
                .statusDescription.contains("/Users/")
        )
    }

    func testWorkRegistryRejectsDuplicateInspectionAndMutationForSameTarget() {
        let inspectionToken = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let mutationToken = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var registry = AssistantIntegrationWorkRegistry()

        XCTAssertTrue(
            registry.start(.inspection, for: .codex, token: inspectionToken)
        )
        XCTAssertEqual(registry.work(for: .codex), .inspection)
        XCTAssertFalse(
            registry.start(.inspection, for: .codex, token: mutationToken)
        )
        XCTAssertFalse(
            registry.start(.installation, for: .codex, token: mutationToken)
        )

        XCTAssertTrue(
            registry.finish(.inspection, for: .codex, token: inspectionToken)
        )
        XCTAssertTrue(
            registry.start(.installation, for: .codex, token: mutationToken)
        )
        XCTAssertEqual(registry.work(for: .codex), .installation)
    }

    func testWorkRegistryIgnoresStaleCompletionAndKeepsTargetsIndependent() {
        let codexToken = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let staleToken = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let claudeToken = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        var registry = AssistantIntegrationWorkRegistry()

        XCTAssertTrue(registry.start(.removal, for: .codex, token: codexToken))
        XCTAssertTrue(registry.start(.inspection, for: .claude, token: claudeToken))
        XCTAssertFalse(registry.finish(.removal, for: .codex, token: staleToken))
        XCTAssertFalse(registry.finish(.inspection, for: .codex, token: codexToken))
        XCTAssertEqual(registry.work(for: .codex), .removal)
        XCTAssertEqual(registry.work(for: .claude), .inspection)

        XCTAssertTrue(registry.cancel(for: .codex, token: codexToken))
        XCTAssertNil(registry.work(for: .codex))
        XCTAssertEqual(registry.work(for: .claude), .inspection)
        XCTAssertFalse(registry.finish(.removal, for: .codex, token: codexToken))
    }

    private final class Fixture {
        let root: URL
        let home: URL
        let skills: URL
        let source: URL
        let destination: URL
        let service: AssistantIntegrationService

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "screenlog-integration-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            home = root.appendingPathComponent("home", isDirectory: true)
            skills = root.appendingPathComponent("skills", isDirectory: true)
            source = root.appendingPathComponent("source", isDirectory: true)
            destination = skills.appendingPathComponent(
                AssistantIntegrationService.skillFolderName,
                isDirectory: true
            )
            service = AssistantIntegrationService(homeDirectory: home, environment: [:])
            try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try writeManifest("current", at: source)
        }

        func writeManifest(_ body: String, at directory: URL) throws {
            try Data(
                "---\nname: \(AssistantIntegrationService.skillFolderName)\n---\n\(body)".utf8
            ).write(to: directory.appendingPathComponent("SKILL.md"))
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
