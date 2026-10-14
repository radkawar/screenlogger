import Foundation
@testable import ScreenlogCore
import XCTest

final class CLIArtifactInstallationServiceTests: XCTestCase {
    func testAutomaticUpgradeRequiresAnIntactManagedInstallation() {
        XCTAssertFalse(CLIArtifactInstallationState.notInstalled.needsAutomaticUpgrade)
        XCTAssertFalse(CLIArtifactInstallationState.current.needsAutomaticUpgrade)
        XCTAssertTrue(CLIArtifactInstallationState.managed.needsAutomaticUpgrade)
        XCTAssertFalse(
            CLIArtifactInstallationState.conflict(
                .unrecognized(existing: ["/tmp/unrelated-screenlog"])
            ).needsAutomaticUpgrade
        )
    }

    func testInstallCreatesAuthenticatedReceiptAndRecognizesCurrentPair() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "current", version: "1")
        var verifiedPath: URL?

        let destination = try fixture.service.install(
            executable: source.executable,
            framework: source.framework,
            into: fixture.destination
        ) { executable in
            verifiedPath = executable
            XCTAssertTrue(executable.path.contains(".screenlog-install-"))
        }

        XCTAssertEqual(destination, fixture.destination.appendingPathComponent("screenlog"))
        XCTAssertNotNil(verifiedPath)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent(".screenlog-cli-install.json").path
            ))
        XCTAssertEqual(
            try Data(contentsOf: fixture.installedSkillManifest),
            try Data(contentsOf: source.skill.appendingPathComponent("SKILL.md"))
        )
        let receipt = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: fixture.destination.appendingPathComponent(
                        ".screenlog-cli-install.json"
                    ))
            ) as? [String: Any]
        )
        XCTAssertEqual(receipt["schemaVersion"] as? Int, 2)
        XCTAssertNotNil(receipt["skillSHA256"] as? String)
        XCTAssertEqual(fixture.service.inspect(in: fixture.destination), .managed)
        XCTAssertEqual(
            fixture.service.inspect(
                in: fixture.destination,
                sourceExecutable: source.executable,
                sourceFramework: source.framework
            ),
            .current
        )
    }

    func testInstallRejectsSymlinkedSourceBeforeVerificationOrPublication() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "source", version: "1")
        let symlink = fixture.root.appendingPathComponent("linked-screenlog")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: source.executable
        )
        var verifierCalled = false

        XCTAssertThrowsError(
            try fixture.service.install(
                executable: symlink,
                framework: source.framework,
                into: fixture.destination
            ) { _ in
                verifierCalled = true
            }
        ) { error in
            XCTAssertEqual(
                error as? CLIArtifactInstallationError,
                .sourceArtifactsInvalid
            )
        }

        XCTAssertFalse(verifierCalled)
        XCTAssertEqual(fixture.service.inspect(in: fixture.destination), .notInstalled)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent("screenlog").path
            )
        )
    }

    func testInstallRejectsSourceWithoutAdjacentCanonicalSkill() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "source", version: "1")
        try FileManager.default.removeItem(at: source.skill)
        var verifierCalled = false

        XCTAssertFalse(
            fixture.service.sourceArtifactsAreValid(
                executable: source.executable,
                framework: source.framework
            )
        )
        XCTAssertThrowsError(
            try fixture.service.install(
                executable: source.executable,
                framework: source.framework,
                into: fixture.destination
            ) { _ in verifierCalled = true }
        ) { error in
            XCTAssertEqual(error as? CLIArtifactInstallationError, .sourceArtifactsInvalid)
        }
        XCTAssertFalse(verifierCalled)
        XCTAssertEqual(fixture.service.inspect(in: fixture.destination), .notInstalled)
    }

    func testInstallFindsCanonicalSkillInAppResourceLayout() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "source", version: "1")
        let contents = fixture.root.appendingPathComponent("Screenlogger.app/Contents")
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources/skill", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let appExecutable = macOS.appendingPathComponent("screenlog")
        let appSkill = resources.appendingPathComponent(
            "screenlog-cli-skill",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: source.executable, to: appExecutable)
        try FileManager.default.moveItem(at: source.skill, to: appSkill)

        XCTAssertTrue(
            fixture.service.sourceArtifactsAreValid(
                executable: appExecutable,
                framework: source.framework
            )
        )
        try fixture.service.install(
            executable: appExecutable,
            framework: source.framework,
            into: fixture.destination,
            verifyStagedExecutable: { _ in }
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.installedSkillManifest),
            try Data(contentsOf: appSkill.appendingPathComponent("SKILL.md"))
        )
    }

    func testInstallRevalidatesFixedStagedBytesBeforeExecutingThem() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "source", version: "1")
        let mutatingFileManager = StagedSourceMutatingFileManager(
            sourceExecutable: source.executable
        )
        let service = CLIArtifactInstallationService(fileManager: mutatingFileManager)
        var verifierCalled = false

        XCTAssertThrowsError(
            try service.install(
                executable: source.executable,
                framework: source.framework,
                into: fixture.destination
            ) { _ in
                verifierCalled = true
            }
        ) { error in
            XCTAssertEqual(
                error as? CLIArtifactInstallationError,
                .sourceArtifactsInvalid
            )
        }

        XCTAssertTrue(mutatingFileManager.didMutateStagedExecutable)
        XCTAssertFalse(verifierCalled)
        XCTAssertEqual(service.inspect(in: fixture.destination), .notInstalled)
        XCTAssertTrue(try fixture.transactionDirectories().isEmpty)
    }

    func testReceiptAuthenticatesOlderPairForTransactionalUpgrade() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.makeSource(named: "old", version: "1")
        let current = try fixture.makeSource(named: "current", version: "2")
        try fixture.service.install(
            executable: old.executable,
            framework: old.framework,
            into: fixture.destination,
            verifyStagedExecutable: { _ in }
        )

        XCTAssertEqual(
            fixture.service.inspect(
                in: fixture.destination,
                sourceExecutable: current.executable,
                sourceFramework: current.framework
            ),
            .managed
        )
        try fixture.service.install(
            executable: current.executable,
            framework: current.framework,
            into: fixture.destination,
            verifyStagedExecutable: { _ in }
        )

        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("screenlog")),
            try Data(contentsOf: current.executable)
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.installedSkillManifest),
            try Data(contentsOf: current.skill.appendingPathComponent("SKILL.md"))
        )
        XCTAssertEqual(
            fixture.service.inspect(
                in: fixture.destination,
                sourceExecutable: current.executable,
                sourceFramework: current.framework
            ),
            .current
        )
    }

    func testUnsupportedReceiptSchemaIsRejectedAndPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.makeSource(named: "old", version: "1")
        let current = try fixture.makeSource(named: "current", version: "2")
        try fixture.service.install(
            executable: old.executable,
            framework: old.framework,
            into: fixture.destination,
            verifyStagedExecutable: { _ in }
        )

        let receiptURL = fixture.destination.appendingPathComponent(
            ".screenlog-cli-install.json"
        )
        var receipt = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL))
                as? [String: Any]
        )
        receipt["schemaVersion"] = 1
        receipt.removeValue(forKey: "skillSHA256")
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            .write(to: receiptURL, options: .atomic)
        let unsupportedReceipt = try Data(contentsOf: receiptURL)
        XCTAssertEqual(
            fixture.service.inspect(
                in: fixture.destination,
                sourceExecutable: current.executable,
                sourceFramework: current.framework
            ),
            .conflict(.invalidReceipt(receiptURL.path))
        )
        XCTAssertThrowsError(
            try fixture.service.install(
                executable: current.executable,
                framework: current.framework,
                into: fixture.destination,
                verifyStagedExecutable: { _ in XCTFail("Must fail before verification") }
            )
        )
        XCTAssertEqual(try Data(contentsOf: receiptURL), unsupportedReceipt)
    }

    func testSchemaOneReceiptNeverClaimsOrReplacesExistingSkill() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.makeSource(named: "old", version: "1")
        let current = try fixture.makeSource(named: "current", version: "2")
        try fixture.service.install(
            executable: old.executable,
            framework: old.framework,
            into: fixture.destination,
            verifyStagedExecutable: { _ in }
        )

        let receiptURL = fixture.destination.appendingPathComponent(
            ".screenlog-cli-install.json"
        )
        var receipt = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL))
                as? [String: Any]
        )
        receipt["schemaVersion"] = 1
        receipt.removeValue(forKey: "skillSHA256")
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            .write(to: receiptURL, options: .atomic)
        let unownedSkill = Data("preserve this unowned skill".utf8)
        try unownedSkill.write(to: fixture.installedSkillManifest)

        XCTAssertEqual(
            fixture.service.inspect(in: fixture.destination),
            .conflict(.invalidReceipt(receiptURL.path))
        )
        XCTAssertThrowsError(
            try fixture.service.install(
                executable: current.executable,
                framework: current.framework,
                into: fixture.destination,
                verifyStagedExecutable: { _ in XCTFail("Must fail before verification") }
            )
        )
        XCTAssertEqual(try Data(contentsOf: fixture.installedSkillManifest), unownedSkill)
    }

    func testRecognizedReceiptlessArtifactsAreRefusedAndPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previous = try fixture.makeSource(named: "previous", version: "1")
        let current = try fixture.makeSource(named: "current", version: "2")
        try FileManager.default.copyItem(at: previous.directory, to: fixture.destination)
        var verificationCount = 0

        guard case .conflict(.unrecognized) = fixture.service.inspect(in: fixture.destination)
        else { return XCTFail("Expected receiptless artifacts to be unowned") }
        XCTAssertThrowsError(
            try fixture.service.install(
                executable: current.executable,
                framework: current.framework,
                into: fixture.destination
            ) { _ in verificationCount += 1 }
        )
        XCTAssertEqual(verificationCount, 0)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("screenlog")),
            try Data(contentsOf: previous.executable)
        )
        XCTAssertTrue(try fixture.transactionDirectories().isEmpty)
    }

    func testByteIdenticalReceiptlessArtifactsRemainUnownedAndCannotBeRemoved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "current", version: "1")
        try FileManager.default.copyItem(at: source.directory, to: fixture.destination)

        let inspection = fixture.service.inspect(
            in: fixture.destination,
            sourceExecutable: source.executable,
            sourceFramework: source.framework
        )
        guard case .conflict(let conflict) = inspection,
            case .unrecognized = conflict
        else {
            return XCTFail("Expected byte-identical receiptless artifacts to be unowned")
        }
        let appState = CLIInstallState(
            inspection: inspection,
            commandPath: fixture.destination.appendingPathComponent("screenlog").path,
            bundledArtifactsAvailable: true
        )
        XCTAssertEqual(appState, .conflict(conflict))
        XCTAssertFalse(appState.isReady)
        XCTAssertFalse(appState.canRemove)

        XCTAssertThrowsError(try fixture.service.remove(from: fixture.destination)) {
            error in
            guard case CLIArtifactInstallationError.conflict(.unrecognized) = error else {
                return XCTFail("Expected an ownership conflict, got \(error)")
            }
        }
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appendingPathComponent("screenlog")),
            try Data(contentsOf: source.executable)
        )
    }

    func testUnrecognizedPairIsRefusedBeforeStagingAndPreservedByteForByte() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "source", version: "2")
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        let executable = fixture.destination.appendingPathComponent("screenlog")
        let framework = fixture.destination.appendingPathComponent("ScreenlogCore.framework")
        let originalExecutable = Data("unrelated command".utf8)
        try originalExecutable.write(to: executable)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let marker = framework.appendingPathComponent("keep.txt")
        let originalFramework = Data("unrelated framework".utf8)
        try originalFramework.write(to: marker)
        var verifierCalled = false

        XCTAssertThrowsError(
            try fixture.service.install(
                executable: source.executable,
                framework: source.framework,
                into: fixture.destination
            ) { _ in verifierCalled = true }
        ) { error in
            guard case CLIArtifactInstallationError.conflict(.unrecognized) = error else {
                return XCTFail("Expected unrecognized conflict, got \(error)")
            }
        }

        XCTAssertFalse(verifierCalled)
        XCTAssertEqual(try Data(contentsOf: executable), originalExecutable)
        XCTAssertEqual(try Data(contentsOf: marker), originalFramework)
        XCTAssertTrue(try fixture.transactionDirectories().isEmpty)
    }

    func testPartialPairIsTypedConflictAndNeverRepairedDestructively() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "source", version: "2")
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        let executable = fixture.destination.appendingPathComponent("screenlog")
        let original = Data("keep this command".utf8)
        try original.write(to: executable)

        guard case .conflict(.incomplete(let existing, let missing)) = fixture.service.inspect(in: fixture.destination) else {
            return XCTFail("Expected an incomplete installation conflict")
        }
        XCTAssertEqual(existing, [executable.path])
        XCTAssertEqual(missing, [fixture.destination.appendingPathComponent("ScreenlogCore.framework").path])
        XCTAssertThrowsError(
            try fixture.service.install(
                executable: source.executable,
                framework: source.framework,
                into: fixture.destination,
                verifyStagedExecutable: { _ in XCTFail("Must fail before verification") }
            ))
        XCTAssertEqual(try Data(contentsOf: executable), original)
    }

    func testModifiedReceiptBackedPairFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "source", version: "1")
        try fixture.service.install(
            executable: source.executable,
            framework: source.framework,
            into: fixture.destination,
            verifyStagedExecutable: { _ in }
        )
        let installedExecutable = fixture.destination.appendingPathComponent("screenlog")
        let modified = Data("modified after install".utf8)
        try modified.write(to: installedExecutable)

        guard case .conflict(.modifiedAuthenticatedInstallation) = fixture.service.inspect(in: fixture.destination) else {
            return XCTFail("Expected a modified authenticated installation conflict")
        }
        XCTAssertThrowsError(
            try fixture.service.install(
                executable: source.executable,
                framework: source.framework,
                into: fixture.destination,
                verifyStagedExecutable: { _ in XCTFail("Must fail before verification") }
            ))
        XCTAssertEqual(try Data(contentsOf: installedExecutable), modified)
    }

    func testModifiedReceiptBackedSkillFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "source", version: "1")
        try fixture.service.install(
            executable: source.executable,
            framework: source.framework,
            into: fixture.destination,
            verifyStagedExecutable: { _ in }
        )
        let modified = Data("user changed the installed skill".utf8)
        try modified.write(to: fixture.installedSkillManifest)

        XCTAssertEqual(
            fixture.service.inspect(in: fixture.destination),
            .conflict(
                .modifiedAuthenticatedInstallation(
                    paths: [fixture.installedSkillDirectory.path]
                )
            )
        )
        XCTAssertThrowsError(try fixture.service.remove(from: fixture.destination))
        XCTAssertEqual(try Data(contentsOf: fixture.installedSkillManifest), modified)
    }

    func testMissingReceiptBackedSkillIsTypedIncompleteConflict() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "source", version: "1")
        try fixture.service.install(
            executable: source.executable,
            framework: source.framework,
            into: fixture.destination,
            verifyStagedExecutable: { _ in }
        )
        try FileManager.default.removeItem(at: fixture.installedSkillDirectory)

        guard
            case .conflict(.incomplete(let existing, let missing)) =
                fixture.service.inspect(in: fixture.destination)
        else { return XCTFail("Expected an incomplete installation conflict") }
        XCTAssertTrue(
            existing.contains(fixture.destination.appendingPathComponent("screenlog").path)
        )
        XCTAssertEqual(missing, [fixture.installedSkillDirectory.path])
    }

    func testStagedVerificationFailurePreservesAuthenticatedInstallation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.makeSource(named: "old", version: "1")
        let current = try fixture.makeSource(named: "current", version: "2")
        try fixture.service.install(
            executable: old.executable,
            framework: old.framework,
            into: fixture.destination,
            verifyStagedExecutable: { _ in }
        )
        let installedExecutable = fixture.destination.appendingPathComponent("screenlog")
        let before = try Data(contentsOf: installedExecutable)

        XCTAssertThrowsError(
            try fixture.service.install(
                executable: current.executable,
                framework: current.framework,
                into: fixture.destination
            ) { _ in
                throw NSError(domain: "test", code: 1)
            }
        ) { error in
            guard case CLIArtifactInstallationError.stagedVerificationFailed = error else {
                return XCTFail("Expected verification failure, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: installedExecutable), before)
        XCTAssertEqual(
            fixture.service.inspect(
                in: fixture.destination,
                sourceExecutable: old.executable,
                sourceFramework: old.framework
            ),
            .current
        )
        XCTAssertTrue(try fixture.transactionDirectories().isEmpty)
    }

    func testPublishFailureRollsBackExecutableFrameworkAndReceiptTogether() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.makeSource(named: "old", version: "1")
        let current = try fixture.makeSource(named: "current", version: "2")
        try fixture.service.install(
            executable: old.executable,
            framework: old.framework,
            into: fixture.destination,
            verifyStagedExecutable: { _ in }
        )
        let executable = fixture.destination.appendingPathComponent("screenlog")
        let frameworkExecutable = fixture.destination
            .appendingPathComponent("ScreenlogCore.framework/ScreenlogCore")
        let receipt = fixture.destination.appendingPathComponent(".screenlog-cli-install.json")
        let beforeExecutable = try Data(contentsOf: executable)
        let beforeFramework = try Data(contentsOf: frameworkExecutable)
        let beforeSkill = try Data(contentsOf: fixture.installedSkillManifest)
        let beforeReceipt = try Data(contentsOf: receipt)
        let failingFileManager = PublishFailingFileManager(destinationExecutable: executable)
        let failingService = CLIArtifactInstallationService(fileManager: failingFileManager)

        XCTAssertThrowsError(
            try failingService.install(
                executable: current.executable,
                framework: current.framework,
                into: fixture.destination,
                verifyStagedExecutable: { _ in }
            ))

        XCTAssertTrue(failingFileManager.didInjectFailure)
        XCTAssertEqual(try Data(contentsOf: executable), beforeExecutable)
        XCTAssertEqual(try Data(contentsOf: frameworkExecutable), beforeFramework)
        XCTAssertEqual(try Data(contentsOf: fixture.installedSkillManifest), beforeSkill)
        XCTAssertEqual(try Data(contentsOf: receipt), beforeReceipt)
        XCTAssertEqual(
            fixture.service.inspect(
                in: fixture.destination,
                sourceExecutable: old.executable,
                sourceFramework: old.framework
            ),
            .current
        )
        XCTAssertTrue(try fixture.transactionDirectories().isEmpty)
    }

    func testPublishRollbackFailurePreservesAuthenticatedBackupForRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.makeSource(named: "old", version: "1")
        let current = try fixture.makeSource(named: "current", version: "2")
        try fixture.service.install(
            executable: old.executable,
            framework: old.framework,
            into: fixture.destination,
            verifyStagedExecutable: { _ in }
        )
        let executable = fixture.destination.appendingPathComponent("screenlog")
        let failingFileManager = PublishAndRollbackFailingFileManager(
            destinationExecutable: executable
        )
        let failingService = CLIArtifactInstallationService(fileManager: failingFileManager)

        XCTAssertThrowsError(
            try failingService.install(
                executable: current.executable,
                framework: current.framework,
                into: fixture.destination,
                verifyStagedExecutable: { _ in }
            )
        ) { error in
            guard
                case CLIArtifactInstallationError.installationRecoveryRequired(let path) = error
            else {
                return XCTFail("Expected a recovery-required installation failure, got \(error)")
            }
            XCTAssertTrue(path.contains(".screenlog-backup-"))
        }

        XCTAssertTrue(failingFileManager.didInjectPublishFailure)
        XCTAssertTrue(failingFileManager.didInjectRollbackFailure)
        let recovery = try XCTUnwrap(
            fixture.transactionDirectories().first {
                $0.lastPathComponent.hasPrefix(".screenlog-backup-")
            }
        )
        XCTAssertEqual(
            CLIArtifactInstallationService().pendingRecovery(in: fixture.destination),
            .installation(directory: recovery.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: recovery.appendingPathComponent("screenlog").path
            )
        )
    }

    func testSuccessfulInstallCleanupLeftoverIsNotReportedAsRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.makeSource(named: "old-cleanup", version: "1")
        let current = try fixture.makeSource(named: "current-cleanup", version: "2")
        try fixture.service.install(
            executable: old.executable,
            framework: old.framework,
            into: fixture.destination,
            verifyStagedExecutable: { _ in }
        )
        let fileManager = TransactionCleanupFailingFileManager(
            blockedPrefix: ".screenlog-backup-"
        )

        try CLIArtifactInstallationService(fileManager: fileManager).install(
            executable: current.executable,
            framework: current.framework,
            into: fixture.destination,
            verifyStagedExecutable: { _ in }
        )

        XCTAssertTrue(fileManager.didInjectFailure)
        XCTAssertNil(fixture.service.pendingRecovery(in: fixture.destination))
        XCTAssertEqual(
            fixture.service.inspect(
                in: fixture.destination,
                sourceExecutable: current.executable,
                sourceFramework: current.framework
            ),
            .current
        )
    }

    func testRemoveDeletesOnlyAuthenticatedInstallationAsOneLifecycle() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "source", version: "1")
        try fixture.service.install(
            executable: source.executable,
            framework: source.framework,
            into: fixture.destination,
            verifyStagedExecutable: { _ in }
        )

        XCTAssertTrue(try fixture.service.remove(from: fixture.destination))
        XCTAssertEqual(fixture.service.inspect(in: fixture.destination), .notInstalled)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent("screenlog").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent("ScreenlogCore.framework").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.installedSkillDirectory.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent(".screenlog-cli-install.json").path
            )
        )
        XCTAssertFalse(try fixture.service.remove(from: fixture.destination))
    }

    func testRemovalRollbackFailurePreservesQuarantineForRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "source", version: "1")
        try fixture.service.install(
            executable: source.executable,
            framework: source.framework,
            into: fixture.destination,
            verifyStagedExecutable: { _ in }
        )
        let failingFileManager = RemovalRollbackFailingFileManager(
            destinationDirectory: fixture.destination
        )
        let failingService = CLIArtifactInstallationService(fileManager: failingFileManager)

        XCTAssertThrowsError(try failingService.remove(from: fixture.destination)) { error in
            guard case CLIArtifactInstallationError.removalRecoveryRequired(let path) = error else {
                return XCTFail("Expected a recovery-required removal failure, got \(error)")
            }
            XCTAssertTrue(path.contains(".screenlog-remove-"))
        }

        XCTAssertTrue(failingFileManager.didInjectRemovalFailure)
        XCTAssertTrue(failingFileManager.didInjectRollbackFailure)
        let recovery = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.destination,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix(".screenlog-remove-") }
        )
        XCTAssertEqual(
            CLIArtifactInstallationService().pendingRecovery(in: fixture.destination),
            .removal(directory: recovery.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: recovery.appendingPathComponent("screenlog").path
            )
        )
    }

    func testSuccessfulRemovalCleanupLeftoverIsNotReportedAsRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "remove-cleanup", version: "1")
        try fixture.service.install(
            executable: source.executable,
            framework: source.framework,
            into: fixture.destination,
            verifyStagedExecutable: { _ in }
        )
        let fileManager = TransactionCleanupFailingFileManager(
            blockedPrefix: ".screenlog-remove-"
        )

        XCTAssertTrue(
            try CLIArtifactInstallationService(fileManager: fileManager).remove(
                from: fixture.destination
            )
        )
        XCTAssertTrue(fileManager.didInjectFailure)
        XCTAssertNil(fixture.service.pendingRecovery(in: fixture.destination))
        XCTAssertEqual(fixture.service.inspect(in: fixture.destination), .notInstalled)
    }

    func testRemovePreservesModifiedReceiptBackedInstallation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeSource(named: "source", version: "1")
        try fixture.service.install(
            executable: source.executable,
            framework: source.framework,
            into: fixture.destination,
            verifyStagedExecutable: { _ in }
        )
        let executable = fixture.destination.appendingPathComponent("screenlog")
        let modified = Data("user modified command".utf8)
        try modified.write(to: executable)

        XCTAssertThrowsError(try fixture.service.remove(from: fixture.destination)) {
            error in
            guard
                case CLIArtifactInstallationError.conflict(
                    .modifiedAuthenticatedInstallation
                ) = error
            else {
                return XCTFail("Expected an authenticated-installation conflict, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: executable), modified)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent("ScreenlogCore.framework").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent(".screenlog-cli-install.json").path
            )
        )
    }

    func testRemovePreservesRecognizedInstallationWithoutOwnershipReceipt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previous = try fixture.makeSource(named: "previous", version: "1")
        try FileManager.default.copyItem(at: previous.directory, to: fixture.destination)

        guard case .conflict(.unrecognized) = fixture.service.inspect(in: fixture.destination)
        else { return XCTFail("Expected receiptless artifacts to be unowned") }
        XCTAssertThrowsError(try fixture.service.remove(from: fixture.destination)) {
            error in
            guard case CLIArtifactInstallationError.conflict(.unrecognized) = error else {
                return XCTFail("Expected an ownership conflict, got \(error)")
            }
        }

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent("screenlog").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.destination.appendingPathComponent("ScreenlogCore.framework").path
            )
        )
    }

    private final class Fixture {
        struct Pair {
            let directory: URL
            let executable: URL
            let framework: URL
            let skill: URL
        }

        let root: URL
        let destination: URL
        let service = CLIArtifactInstallationService()
        var installedSkillDirectory: URL {
            destination.appendingPathComponent(
                "skill/screenlog-cli-skill",
                isDirectory: true
            )
        }
        var installedSkillManifest: URL {
            installedSkillDirectory.appendingPathComponent("SKILL.md")
        }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("screenlog-cli-install-tests-\(UUID().uuidString)", isDirectory: true)
            destination = root.appendingPathComponent("destination", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func makeSource(named name: String, version: String) throws -> Pair {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            let executable = directory.appendingPathComponent("screenlog")
            let framework = directory.appendingPathComponent("ScreenlogCore.framework", isDirectory: true)
            let skill = directory.appendingPathComponent(
                "skill/screenlog-cli-skill",
                isDirectory: true
            )
            let resources = framework.appendingPathComponent("Versions/A/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)

            var executableData = Data([0xcf, 0xfa, 0xed, 0xfe])
            executableData.append(Data("\0@rpath/ScreenlogCore.framework/Versions/A/ScreenlogCore\0\(version)".utf8))
            try executableData.write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

            let frameworkExecutable = framework.appendingPathComponent("ScreenlogCore")
            var frameworkData = Data([0xcf, 0xfa, 0xed, 0xfe])
            frameworkData.append(Data("framework-\(version)".utf8))
            try frameworkData.write(to: frameworkExecutable)
            let info: [String: Any] = [
                "CFBundleIdentifier": "dev.screenlog.core",
                "CFBundlePackageType": "FMWK",
                "CFBundleExecutable": "ScreenlogCore",
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: resources.appendingPathComponent("Info.plist"))
            try Data(
                """
                ---
                name: screenlog-cli-skill
                description: Screenlogger test skill \(version)
                ---
                # Screenlogger test skill \(version)
                """.utf8
            ).write(to: skill.appendingPathComponent("SKILL.md"))
            return Pair(
                directory: directory,
                executable: executable,
                framework: framework,
                skill: skill
            )
        }

        func transactionDirectories() throws -> [URL] {
            guard FileManager.default.fileExists(atPath: destination.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(
                at: destination,
                includingPropertiesForKeys: nil
            ).filter {
                $0.lastPathComponent.hasPrefix(".screenlog-install-")
                    || $0.lastPathComponent.hasPrefix(".screenlog-backup-")
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private final class PublishFailingFileManager: FileManager, @unchecked Sendable {
        let destinationExecutable: URL
        var didInjectFailure = false

        init(destinationExecutable: URL) {
            self.destinationExecutable = destinationExecutable
            super.init()
        }

        override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
            if !didInjectFailure,
                destinationURL.standardizedFileURL == destinationExecutable.standardizedFileURL,
                sourceURL.deletingLastPathComponent().lastPathComponent.hasPrefix(".screenlog-install-")
            {
                didInjectFailure = true
                throw NSError(
                    domain: "dev.screenlog.cli-install.tests",
                    code: 99,
                    userInfo: [NSLocalizedDescriptionKey: "Injected publish failure"]
                )
            }
            try super.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    private final class PublishAndRollbackFailingFileManager: FileManager,
        @unchecked Sendable
    {
        let destinationExecutable: URL
        var didInjectPublishFailure = false
        var didInjectRollbackFailure = false

        init(destinationExecutable: URL) {
            self.destinationExecutable = destinationExecutable
            super.init()
        }

        override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
            if !didInjectPublishFailure,
                destinationURL.standardizedFileURL == destinationExecutable.standardizedFileURL,
                sourceURL.deletingLastPathComponent().lastPathComponent.hasPrefix(
                    ".screenlog-install-"
                )
            {
                didInjectPublishFailure = true
                throw injectedFailure(code: 101, description: "Injected publish failure")
            }
            if didInjectPublishFailure, !didInjectRollbackFailure,
                destinationURL.standardizedFileURL == destinationExecutable.standardizedFileURL,
                sourceURL.deletingLastPathComponent().lastPathComponent.hasPrefix(
                    ".screenlog-backup-"
                )
            {
                didInjectRollbackFailure = true
                throw injectedFailure(code: 102, description: "Injected rollback failure")
            }
            try super.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    private final class RemovalRollbackFailingFileManager: FileManager,
        @unchecked Sendable
    {
        let destinationDirectory: URL
        var didInjectRemovalFailure = false
        var didInjectRollbackFailure = false

        init(destinationDirectory: URL) {
            self.destinationDirectory = destinationDirectory
            super.init()
        }

        override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
            if !didInjectRemovalFailure,
                sourceURL.deletingLastPathComponent().standardizedFileURL
                    == destinationDirectory.standardizedFileURL,
                sourceURL.lastPathComponent == "ScreenlogCore.framework",
                destinationURL.deletingLastPathComponent().lastPathComponent.hasPrefix(
                    ".screenlog-remove-"
                )
            {
                didInjectRemovalFailure = true
                throw injectedFailure(code: 103, description: "Injected removal failure")
            }
            if didInjectRemovalFailure, !didInjectRollbackFailure,
                sourceURL.deletingLastPathComponent().lastPathComponent.hasPrefix(
                    ".screenlog-remove-"
                ),
                destinationURL.standardizedFileURL
                    == destinationDirectory.appendingPathComponent("screenlog").standardizedFileURL
            {
                didInjectRollbackFailure = true
                throw injectedFailure(code: 104, description: "Injected rollback failure")
            }
            try super.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    private final class TransactionCleanupFailingFileManager: FileManager,
        @unchecked Sendable
    {
        let blockedPrefix: String
        var didInjectFailure = false

        init(blockedPrefix: String) {
            self.blockedPrefix = blockedPrefix
            super.init()
        }

        override func removeItem(at URL: URL) throws {
            if URL.lastPathComponent.hasPrefix(blockedPrefix) {
                didInjectFailure = true
                throw injectedFailure(code: 105, description: "Injected cleanup failure")
            }
            try super.removeItem(at: URL)
        }
    }

    private static func injectedFailure(code: Int, description: String) -> NSError {
        NSError(
            domain: "dev.screenlog.cli-install.tests",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    private final class StagedSourceMutatingFileManager: FileManager, @unchecked Sendable {
        let sourceExecutable: URL
        var didMutateStagedExecutable = false

        init(sourceExecutable: URL) {
            self.sourceExecutable = sourceExecutable
            super.init()
        }

        override func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
            try super.copyItem(at: sourceURL, to: destinationURL)
            guard
                !didMutateStagedExecutable,
                sourceURL.standardizedFileURL == sourceExecutable.standardizedFileURL
            else { return }
            didMutateStagedExecutable = true
            try Data("changed while copying".utf8).write(to: destinationURL)
        }
    }
}
