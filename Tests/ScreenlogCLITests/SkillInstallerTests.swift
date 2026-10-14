import Foundation
@testable import ScreenlogCLI
import XCTest

final class SkillInstallerTests: XCTestCase {
    func testShippedSkillCopiesMatch() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourceSkill = repositoryRoot.appendingPathComponent(
            "Resources/skill/screenlog-cli-skill/SKILL.md"
        )
        let packagedSkill = repositoryRoot.appendingPathComponent(
            "Sources/ScreenlogCLI/skill/screenlog-cli-skill/SKILL.md"
        )
        let contract = try String(contentsOf: resourceSkill, encoding: .utf8)
        let packagedContract = try String(contentsOf: packagedSkill, encoding: .utf8)

        XCTAssertEqual(packagedContract, contract)
    }

    func testCLIErrorExitCodesDistinguishUsageFromOperationalFailure() {
        XCTAssertEqual(CLIError.usage("command").exitCode, 2)
        XCTAssertEqual(CLIError.unknown("command").exitCode, 2)
        XCTAssertEqual(CLIError.message("verification failed").exitCode, 1)
    }

    func testParsesLifecycleOperationsAndAliases() throws {
        XCTAssertEqual(
            try SkillInstaller.parseInvocation(["install", "codex"]),
            .init(operation: .install, target: .codex, directoryOverride: nil, force: false)
        )
        XCTAssertEqual(
            try SkillInstaller.parseInvocation(["verify", "--target", "claude"]),
            .init(operation: .status, target: .claude, directoryOverride: nil, force: false)
        )
        XCTAssertEqual(
            try SkillInstaller.parseInvocation(["uninstall", "cursor", "--force"]),
            .init(operation: .remove, target: .cursor, directoryOverride: nil, force: true)
        )
        XCTAssertEqual(
            try SkillInstaller.parseInvocation(["upgrade", "openclaw"]),
            .init(operation: .upgrade, target: .openclaw, directoryOverride: nil, force: false)
        )
        XCTAssertEqual(
            try SkillInstaller.parseInvocation(["install", "grok"]),
            .init(operation: .install, target: .grok, directoryOverride: nil, force: false)
        )
        XCTAssertEqual(
            try SkillInstaller.parseInvocation(["status", "all", "--json"]),
            .init(
                operation: .status,
                target: .all,
                directoryOverride: nil,
                force: false,
                jsonOutput: true
            )
        )
    }

    func testDefaultsToBackwardCompatibleInstallAll() throws {
        XCTAssertEqual(
            try SkillInstaller.parseInvocation([]),
            .init(operation: .install, target: .all, directoryOverride: nil, force: false)
        )
        XCTAssertEqual(
            try SkillInstaller.parseInvocation(["codex", "--force"]),
            .init(operation: .install, target: .codex, directoryOverride: nil, force: true)
        )
    }

    func testRejectsAmbiguousOrUnsupportedArguments() {
        XCTAssertThrowsError(try SkillInstaller.parseInvocation(["install", "codex", "--target", "claude"]))
        XCTAssertThrowsError(try SkillInstaller.parseInvocation(["status", "codex", "--force"]))
        XCTAssertThrowsError(try SkillInstaller.parseInvocation(["install", "--directory"]))
        XCTAssertThrowsError(try SkillInstaller.parseInvocation(["install", "--bogus"]))
        XCTAssertThrowsError(try SkillInstaller.parseInvocation(["install", "codex", "claude"]))
        XCTAssertThrowsError(try SkillInstaller.parseInvocation(["install", "codex", "--json"]))
        XCTAssertThrowsError(try SkillInstaller.parseInvocation(["status", "codex", "--json", "--json"]))
    }

    func testDefaultAndAgentRootDestinationsAreExact() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(
            try SkillInstaller.standardDestination(target: .codex, directoryOverride: nil, home: home).path,
            "/Users/example/.agents/skills/screenlog-cli-skill"
        )
        XCTAssertEqual(
            try SkillInstaller.standardDestination(
                target: .grok,
                directoryOverride: nil,
                home: home,
                environment: [:]
            ).path,
            "/Users/example/.grok/skills/screenlog-cli-skill"
        )
        XCTAssertEqual(
            try SkillInstaller.standardDestination(
                target: .claude,
                directoryOverride: "~/.claude",
                home: home
            ).path,
            "/Users/example/.claude/skills/screenlog-cli-skill"
        )
    }

    func testCustomDirectoryIsTreatedAsSkillsDirectoryWithoutDotPathHeuristics() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(
            try SkillInstaller.standardDestination(
                target: .cursor,
                directoryOverride: "/tmp/.custom-agent",
                home: home
            ).path,
            "/tmp/.custom-agent/screenlog-cli-skill"
        )
    }

    func testRejectsUnsafeOrAmbiguousDirectoryOverrides() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertThrowsError(
            try SkillInstaller.standardDestination(target: .codex, directoryOverride: "/", home: home)
        )
        XCTAssertThrowsError(
            try SkillInstaller.standardDestination(target: .codex, directoryOverride: "~someone/skills", home: home)
        )
        XCTAssertThrowsError(
            try SkillInstaller.standardDestination(target: .all, directoryOverride: "/tmp/skills", home: home)
        )
        XCTAssertThrowsError(
            try SkillInstaller.standardDestination(
                target: .codex,
                directoryOverride: "~/.cursor",
                home: home
            )
        )
        XCTAssertThrowsError(
            try SkillInstaller.standardDestination(
                target: .codex,
                directoryOverride: "~/.grok",
                home: home
            )
        )
    }

    func testInstallationStateForCopyAndSymlinkLifecycle() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        let destination = temporary.appendingPathComponent("screenlog-cli-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("---\nname: screenlog-cli-skill\n---\ncurrent".utf8)
            .write(to: source.appendingPathComponent("SKILL.md"))

        XCTAssertEqual(SkillInstaller.installationState(at: destination, source: source), .missing)

        try FileManager.default.copyItem(at: source, to: destination)
        XCTAssertEqual(SkillInstaller.installationState(at: destination, source: source), .currentCopy)
        try Data("---\nname: screenlog-cli-skill\n---\nstale".utf8)
            .write(to: destination.appendingPathComponent("SKILL.md"))
        XCTAssertEqual(SkillInstaller.installationState(at: destination, source: source), .staleCopy)

        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        XCTAssertEqual(SkillInstaller.installationState(at: destination, source: source), .currentLink)

        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(
            atPath: destination.path,
            withDestinationPath: temporary.appendingPathComponent("missing").path
        )
        guard case .brokenLink = SkillInstaller.installationState(at: destination, source: source) else {
            return XCTFail("Expected a broken link state")
        }

        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(to: destination.appendingPathComponent("README.md"))
        XCTAssertEqual(SkillInstaller.installationState(at: destination, source: source), .conflict)
    }

    func testOpenClawRegistrationRoundTripPreservesUnrelatedConfiguration() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let config = temporary.appendingPathComponent("openclaw.json")
        let skillHome = temporary.appendingPathComponent("Screenlogger Skills", isDirectory: true)
        let initial: [String: Any] = ["unrelated": ["enabled": true]]
        try JSONSerialization.data(withJSONObject: initial).write(to: config)

        XCTAssertFalse(try SkillInstaller.openClawRegistration(configURL: config, skillHome: skillHome))
        XCTAssertTrue(
            try SkillInstaller.updateOpenClawRegistration(
                configURL: config,
                skillHome: skillHome,
                shouldRegister: true
            )
        )
        XCTAssertTrue(try SkillInstaller.openClawRegistration(configURL: config, skillHome: skillHome))

        let registered = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
        )
        XCTAssertNotNil(registered["unrelated"])

        XCTAssertTrue(
            try SkillInstaller.updateOpenClawRegistration(
                configURL: config,
                skillHome: skillHome,
                shouldRegister: false
            )
        )
        XCTAssertFalse(try SkillInstaller.openClawRegistration(configURL: config, skillHome: skillHome))
        XCTAssertFalse(
            try SkillInstaller.updateOpenClawRegistration(
                configURL: config,
                skillHome: skillHome,
                shouldRegister: false
            )
        )
    }

    func testOpenClawRegistrationRejectsMalformedOwnedKeysWithoutRewriting() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let config = temporary.appendingPathComponent("openclaw.json")
        let original = Data(#"{"skills":"unexpected","unrelated":true}"#.utf8)
        try original.write(to: config)

        XCTAssertThrowsError(
            try SkillInstaller.updateOpenClawRegistration(
                configURL: config,
                skillHome: temporary.appendingPathComponent("skills"),
                shouldRegister: true
            )
        )
        XCTAssertEqual(try Data(contentsOf: config), original)
    }

    func testFailedReplacementPreservesExistingInstallation() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let destination = temporary.appendingPathComponent("screenlog-cli-skill", isDirectory: true)
        let missingSource = temporary.appendingPathComponent("missing-source", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let manifest = destination.appendingPathComponent("SKILL.md")
        let original = Data("---\nname: screenlog-cli-skill\n---\nworking".utf8)
        try original.write(to: manifest)

        XCTAssertThrowsError(
            try SkillInstaller.replaceSkill(
                at: destination,
                source: missingSource,
                removeExisting: true,
                preferCopy: true
            )
        )
        XCTAssertEqual(try Data(contentsOf: manifest), original)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
            .filter { $0.contains(".stage-") || $0.contains(".backup-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testAtomicReplacementPublishesCompleteNewSkill() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        let destination = temporary.appendingPathComponent("screenlog-cli-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let current = Data("---\nname: screenlog-cli-skill\n---\ncurrent".utf8)
        try current.write(to: source.appendingPathComponent("SKILL.md"))
        try Data("---\nname: screenlog-cli-skill\n---\nstale".utf8)
            .write(to: destination.appendingPathComponent("SKILL.md"))

        try SkillInstaller.replaceSkill(
            at: destination,
            source: source,
            removeExisting: true,
            preferCopy: true
        )

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("SKILL.md")), current)
        XCTAssertEqual(SkillInstaller.installationState(at: destination, source: source), .currentCopy)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
            .filter { $0.contains(".stage-") || $0.contains(".backup-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testRemoveRefusesUnrelatedDirectoryWithoutForce() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let skills = temporary.appendingPathComponent("skills", isDirectory: true)
        let destination = skills.appendingPathComponent("screenlog-cli-skill", isDirectory: true)
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(to: destination.appendingPathComponent("README.md"))
        try Data("---\nname: screenlog-cli-skill\n---".utf8)
            .write(to: source.appendingPathComponent("SKILL.md"))

        XCTAssertThrowsError(
            try SkillInstaller.performStandard(
                .remove,
                target: .codex,
                directoryOverride: skills.path,
                skillSource: source,
                force: false
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRemoveRefusesUnauthenticatedBrokenLinkWithoutForce() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let skills = temporary.appendingPathComponent("skills", isDirectory: true)
        let destination = skills.appendingPathComponent("screenlog-cli-skill", isDirectory: true)
        let source = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("---\nname: screenlog-cli-skill\n---".utf8)
            .write(to: source.appendingPathComponent("SKILL.md"))
        try FileManager.default.createSymbolicLink(
            atPath: destination.path,
            withDestinationPath: temporary.appendingPathComponent("unknown-missing-target").path
        )

        XCTAssertThrowsError(
            try SkillInstaller.performStandard(
                .remove,
                target: .codex,
                directoryOverride: skills.path,
                skillSource: source,
                force: false
            )
        )
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path))
    }

    func testRemoveWorksWhenBundledSkillSourceIsUnavailable() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let skills = temporary.appendingPathComponent("skills", isDirectory: true)
        let destination = skills.appendingPathComponent(
            "screenlog-cli-skill",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        try Data("---\nname: screenlog-cli-skill\n---\ninstalled".utf8)
            .write(to: destination.appendingPathComponent("SKILL.md"))

        let result = try SkillInstaller.performStandard(
            .remove,
            target: .codex,
            directoryOverride: skills.path,
            skillSource: nil,
            force: false
        )

        XCTAssertEqual(result.changed, [destination])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSourceLessRemoveStillRefusesUnrelatedContent() throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let skills = temporary.appendingPathComponent("skills", isDirectory: true)
        let destination = skills.appendingPathComponent(
            "screenlog-cli-skill",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let unrelated = destination.appendingPathComponent("README.md")
        try Data("keep me".utf8).write(to: unrelated)

        XCTAssertThrowsError(
            try SkillInstaller.performStandard(
                .remove,
                target: .codex,
                directoryOverride: skills.path,
                skillSource: nil,
                force: false
            )
        )
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep me".utf8))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-skill-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
