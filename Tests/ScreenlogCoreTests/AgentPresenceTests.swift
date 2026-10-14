import XCTest

@testable import ScreenlogCore

final class AssistantHostDiscoveryTests: XCTestCase {
    func testSupportedExecutablesAreHostEvidence() {
        let executableURLs = [
            "claude": URL(fileURLWithPath: "/tools/claude"),
            "cursor-agent": URL(fileURLWithPath: "/tools/cursor-agent"),
            "codex": URL(fileURLWithPath: "/tools/codex"),
            "grok": URL(fileURLWithPath: "/tools/grok"),
            "openclaw": URL(fileURLWithPath: "/tools/openclaw"),
        ]
        let discovery = makeDiscovery(executables: executableURLs)

        XCTAssertEqual(discovery.detectedTargets(), AssistantIntegrationTarget.allCases)
        for target in AssistantIntegrationTarget.allCases {
            let result = discovery.detect(target)
            XCTAssertTrue(result.isPresent)
            XCTAssertNil(result.appURL)
            XCTAssertEqual(
                result.cliURL?.lastPathComponent,
                target == .cursor ? "cursor-agent" : target.rawValue
            )
        }
    }

    func testOnlyCompatibleApplicationsAreHostEvidence() {
        let applications = [
            "Claude Code": URL(fileURLWithPath: "/Applications/Claude Code.app"),
            "Cursor": URL(fileURLWithPath: "/Applications/Cursor.app"),
            "Codex": URL(fileURLWithPath: "/Applications/Codex.app"),
        ]
        let discovery = makeDiscovery(applications: applications)

        XCTAssertTrue(discovery.detect(.claude).isPresent)
        XCTAssertTrue(discovery.detect(.cursor).isPresent)
        XCTAssertTrue(discovery.detect(.codex).isPresent)
        XCTAssertFalse(discovery.detect(.grok).isPresent)
        XCTAssertFalse(discovery.detect(.openclaw).isPresent)
    }

    func testUnrelatedDesktopAppsDoNotImplyCodingAssistants() {
        let discovery = makeDiscovery(applications: [
            "Claude": URL(fileURLWithPath: "/Applications/Claude.app"),
            "ChatGPT": URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            "Claude Code URL Handler": URL(
                fileURLWithPath: "/Applications/Claude Code URL Handler.app"
            ),
        ])

        XCTAssertFalse(discovery.detect(.claude).isPresent)
        XCTAssertFalse(discovery.detect(.codex).isPresent)
    }

    func testIntegrationAndConfigurationFilesAreNotHostEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        for path in [
            ".claude/skills/screenlogger/SKILL.md",
            ".cursor/skills/screenlogger/SKILL.md",
            ".agents/skills/screenlogger/SKILL.md",
            ".grok/skills/screenlogger/SKILL.md",
            ".openclaw/openclaw.json",
        ] {
            let file = root.appendingPathComponent(path, isDirectory: false)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        }

        let discovery = makeDiscovery()
        for target in AssistantIntegrationTarget.allCases {
            XCTAssertFalse(discovery.detect(target).isPresent)
        }
        XCTAssertTrue(discovery.detectedTargets().isEmpty)
    }

    func testFileSystemProbeFindsOfficialGrokInstallLocationOutsidePATH() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(".grok/bin/grok", isDirectory: false)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let discovery = AssistantHostDiscovery(
            probes: .fileSystem(
                environment: ["PATH": ""],
                homeDirectory: root,
                applicationDirectories: []
            )
        )
        XCTAssertEqual(discovery.detect(.grok).cliURL, executable.standardizedFileURL)
    }

    func testGrokBuildProbeHonorsGrokHomeAndRejectsPATHOnlyNamesake() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let pathBin = root.appendingPathComponent("path-bin", isDirectory: true)
        let grokHome = root.appendingPathComponent("official-grok", isDirectory: true)
        let namesake = pathBin.appendingPathComponent("grok", isDirectory: false)
        let official = grokHome.appendingPathComponent("bin/grok", isDirectory: false)
        for executable in [namesake, official] {
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            XCTAssertTrue(
                FileManager.default.createFile(atPath: executable.path, contents: Data())
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }

        var discovery = AssistantHostDiscovery(
            probes: .fileSystem(
                environment: ["PATH": pathBin.path],
                homeDirectory: root,
                applicationDirectories: []
            )
        )
        XCTAssertNil(discovery.detect(.grok).cliURL)

        discovery = AssistantHostDiscovery(
            probes: .fileSystem(
                environment: ["PATH": pathBin.path, "GROK_HOME": grokHome.path],
                homeDirectory: root,
                applicationDirectories: []
            )
        )
        XCTAssertEqual(discovery.detect(.grok).cliURL, official.standardizedFileURL)
    }

    func testGrokBuildProbeRejectsInvalidGrokHome() {
        let discovery = AssistantHostDiscovery(
            probes: .fileSystem(
                environment: ["PATH": "", "GROK_HOME": "relative/path"],
                homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true),
                applicationDirectories: []
            )
        )
        XCTAssertFalse(discovery.detect(.grok).isPresent)
    }

    func testFileSystemProbeRequiresAnExecutableFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex", isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: codex.path, contents: Data()))

        var discovery = AssistantHostDiscovery(
            probes: .fileSystem(
                environment: ["PATH": bin.path],
                homeDirectory: root,
                applicationDirectories: []
            )
        )
        XCTAssertFalse(discovery.detect(.codex).isPresent)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: codex.path
        )
        discovery = AssistantHostDiscovery(
            probes: .fileSystem(
                environment: ["PATH": bin.path],
                homeDirectory: root,
                applicationDirectories: []
            )
        )
        XCTAssertEqual(discovery.detect(.codex).cliURL, codex.standardizedFileURL)
    }

    func testFileSystemProbeRequiresARealApplicationBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let codexApp = applications.appendingPathComponent("Codex.app", isDirectory: true)
        try FileManager.default.createDirectory(at: codexApp, withIntermediateDirectories: true)

        var probes = AssistantHostDiscovery.Probes.fileSystem(
            environment: ["PATH": ""],
            homeDirectory: root,
            applicationDirectories: [applications]
        )
        XCTAssertFalse(AssistantHostDiscovery(probes: probes).detect(.codex).isPresent)

        let contents = codexApp.appendingPathComponent("Contents", isDirectory: true)
        let executableDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: executableDirectory,
            withIntermediateDirectories: true
        )
        let executable = executableDirectory.appendingPathComponent("Codex")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let info: [String: Any] = [
            "CFBundleExecutable": "Codex",
            "CFBundleIdentifier": "dev.test.codex",
            "CFBundlePackageType": "APPL",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))
        probes = AssistantHostDiscovery.Probes.fileSystem(
            environment: ["PATH": ""],
            homeDirectory: root,
            applicationDirectories: [applications]
        )

        XCTAssertEqual(
            AssistantHostDiscovery(probes: probes).detect(.codex).appURL,
            codexApp.standardizedFileURL
        )
    }

    private func makeDiscovery(
        executables: [String: URL] = [:],
        applications: [String: URL] = [:]
    ) -> AssistantHostDiscovery {
        AssistantHostDiscovery(
            probes: .init(
                executableURL: { executables[$0] },
                applicationURL: { applications[$0] }
            )
        )
    }
}
