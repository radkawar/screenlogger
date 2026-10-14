import ScreenlogCore
import XCTest

@MainActor
final class AssistantHandoffLaunchServiceTests: XCTestCase {
    func testClaudeCodePromptLinkRoundTripsReservedCharacters() throws {
        let prompt = "Find design & accessibility notes.\nUse screenlog."
        let url = try XCTUnwrap(
            AssistantHandoffLaunchService.promptURL(
                scheme: "claude-cli",
                host: "open",
                queryName: "q",
                prompt: prompt
            )
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "claude-cli")
        XCTAssertEqual(components.host, "open")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: prompt)])
    }

    func testOpenClawLinkUsesTheApprovalMessageContract() throws {
        let prompt = "Find caf\u{E9} research.\nUse screenlog."
        let url = try XCTUnwrap(
            AssistantHandoffLaunchService.promptURL(
                scheme: "openclaw",
                host: "agent",
                queryName: "message",
                prompt: prompt
            )
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "openclaw")
        XCTAssertEqual(components.host, "agent")
        XCTAssertEqual(
            components.queryItems,
            [URLQueryItem(name: "message", value: prompt)]
        )
    }

    func testEveryDetectedCLIHostHasItsTypedTerminalContract() throws {
        for target in AssistantIntegrationTarget.allCases {
            let executable = URL(
                fileURLWithPath: "/tools/\(target == .cursor ? "cursor-agent" : target.rawValue)"
            )
            let destination = try XCTUnwrap(
                AssistantHandoffLaunchService.destination(
                    for: target,
                    presence: AssistantHostDiscovery.Result(
                        appURL: nil,
                        cliURL: executable
                    )
                )
            )

            XCTAssertEqual(destination.target, target)
            XCTAssertEqual(destination.executableURL, executable)
            XCTAssertEqual(
                destination.actionTitle,
                target == .openclaw ? "Ask OpenClaw" : "Open in \(target.label)"
            )
            XCTAssertEqual(destination.actionSystemImage, "terminal")
            XCTAssertEqual(
                destination.privacyDetail,
                target == .openclaw
                    ? "Runs one OpenClaw turn in Terminal with your search request."
                    : "Opens \(target.label) in Terminal with your search request."
            )

            switch destination.delivery {
            case .terminalCommand(let contract):
                let expected: AssistantHandoffDestination.TerminalContract =
                    switch target {
                    case .claude: .claude
                    case .cursor: .cursor
                    case .codex: .codex
                    case .grok: .grok
                    case .openclaw: .openClaw
                    }
                XCTAssertEqual(contract, expected)
            case .claudeCodePrefill, .openClawApproval:
                XCTFail("A detected CLI must use Terminal for \(target.label).")
            }
        }
    }

    func testGrokLaunchContractPlacesCWDOptionsBeforePrompt() throws {
        let workspace = URL(
            fileURLWithPath: "/Users/example/Library/Caches/Screenlogger's Handoff"
        )
        let command = try XCTUnwrap(
            AssistantHandoffLaunchService.preparedTerminalShellCommand(
                executableURL: URL(fileURLWithPath: "/Users/example/.grok/bin/grok"),
                contract: .grok,
                request: "Find the review",
                workspacePreparer: FixedAssistantHandoffWorkspacePreparer(url: workspace)
            )
        )

        XCTAssertEqual(
            command,
            "exec '/Users/example/.grok/bin/grok' '--cwd' '/Users/example/Library/Caches/Screenlogger'\\''s Handoff' 'Find the review'"
        )
    }

    func testOtherAssistantTerminalContractsUsePrivateWorkspace() throws {
        let executable = URL(fileURLWithPath: "/opt/bin/assistant")
        let workspace = URL(fileURLWithPath: "/Users/example/Library/Caches/Private Handoff")
        let preparer = FixedAssistantHandoffWorkspacePreparer(url: workspace)
        let claude = try XCTUnwrap(
            AssistantHandoffLaunchService.preparedTerminalShellCommand(
                executableURL: executable,
                contract: .claude,
                request: "Find the review",
                workspacePreparer: preparer
            )
        )
        let cursor = try XCTUnwrap(
            AssistantHandoffLaunchService.preparedTerminalShellCommand(
                executableURL: executable,
                contract: .cursor,
                request: "Find the review",
                workspacePreparer: preparer
            )
        )
        let codex = try XCTUnwrap(
            AssistantHandoffLaunchService.preparedTerminalShellCommand(
                executableURL: executable,
                contract: .codex,
                request: "Find the review",
                workspacePreparer: preparer
            )
        )
        let openClaw = try XCTUnwrap(
            AssistantHandoffLaunchService.preparedTerminalShellCommand(
                executableURL: executable,
                contract: .openClaw,
                request: "Find the review",
                workspacePreparer: preparer
            )
        )

        let shellCWD =
            "cd '/Users/example/Library/Caches/Private Handoff' && exec '/opt/bin/assistant' 'Find the review'"
        XCTAssertEqual(claude, shellCWD)
        XCTAssertEqual(cursor, shellCWD)
        XCTAssertEqual(
            codex,
            "exec '/opt/bin/assistant' '--cd' '/Users/example/Library/Caches/Private Handoff' 'Find the review'"
        )
        XCTAssertEqual(
            openClaw,
            "exec '/opt/bin/assistant' 'agent' 'exec' '--no-auth-env-only' '--cwd' '/Users/example/Library/Caches/Private Handoff' 'Find the review'"
        )
    }

    func testTerminalCommandTreatsRequestAsOneQuotedArgument() throws {
        let request = "Find Bob's review; $(touch /tmp/not-screenlogger)\nUse screenlog."
        let command = try XCTUnwrap(
            AssistantHandoffLaunchService.terminalShellCommand(
                executableURL: URL(fileURLWithPath: "/Users/example/bin/codex"),
                argumentsBeforeRequest: [],
                request: request
            )
        )

        XCTAssertEqual(
            command,
            "exec '/Users/example/bin/codex' 'Find Bob'\\''s review; $(touch /tmp/not-screenlogger)\nUse screenlog.'"
        )
    }

    func testShellWorkingDirectoryIsOneQuotedWord() throws {
        let command = try XCTUnwrap(
            AssistantHandoffLaunchService.terminalShellCommand(
                executableURL: URL(fileURLWithPath: "/Users/example/bin/claude"),
                argumentsBeforeRequest: [],
                request: "Find the review",
                workingDirectoryURL: URL(
                    fileURLWithPath: "/Users/example/Library/Caches/Assistant's Workspace"
                )
            )
        )

        XCTAssertEqual(
            command,
            "cd '/Users/example/Library/Caches/Assistant'\\''s Workspace' && exec '/Users/example/bin/claude' 'Find the review'"
        )
    }

    func testTerminalCommandRejectsNonFileExecutablesAndNULBytes() {
        XCTAssertNil(
            AssistantHandoffLaunchService.terminalShellCommand(
                executableURL: URL(string: "https://example.com/codex")!,
                argumentsBeforeRequest: [],
                request: "Find the review"
            )
        )
        XCTAssertNil(
            AssistantHandoffLaunchService.terminalShellCommand(
                executableURL: URL(fileURLWithPath: "/tools/codex"),
                argumentsBeforeRequest: [],
                request: "Find\0the review"
            )
        )
        XCTAssertNil(
            AssistantHandoffLaunchService.terminalShellCommand(
                executableURL: URL(fileURLWithPath: "/tools/claude"),
                argumentsBeforeRequest: [],
                request: "Find the review",
                workingDirectoryURL: URL(string: "https://example.com/workspace")
            )
        )
    }

    func testAppOnlyHostsWithoutARequestAPIAreNotOfferedAsHandoffs() {
        for target in [AssistantIntegrationTarget.cursor, .codex, .grok] {
            XCTAssertNil(
                AssistantHandoffLaunchService.destination(
                    for: target,
                    presence: AssistantHostDiscovery.Result(
                        appURL: URL(fileURLWithPath: "/Applications/\(target.label).app"),
                        cliURL: nil
                    )
                ),
                "\(target.label) must not fall back to a clipboard handoff."
            )
        }
    }

    func testErrorsNeverSuggestClipboardRecovery() {
        let errors: [AssistantHandoffLaunchError] = [
            .invalidLink, .invalidTerminalCommand, .couldNotPrepareWorkspace, .couldNotOpenAssistant,
        ]
        for error in errors {
            XCTAssertFalse(error.localizedDescription.localizedCaseInsensitiveContains("clipboard"))
        }
        for error in [
            AssistantHandoffLaunchError.couldNotPrepareWorkspace,
            AssistantHandoffLaunchError.couldNotOpenAssistant,
        ] {
            XCTAssertTrue(error.localizedDescription.contains("did not send anything"))
        }
    }

    func testAssistantWorkspaceIsPrivateAndReused() throws {
        let root = try makeTemporaryCachesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preparer = AssistantHandoffWorkspacePreparer(cachesDirectory: root)

        let first = try preparer.prepareWorkspace()
        let second = try preparer.prepareWorkspace()
        let attributes = try FileManager.default.attributesOfItem(atPath: first.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first,
            root.appendingPathComponent("dev.screenlog/Assistant Handoff Workspace")
                .standardizedFileURL
        )
        XCTAssertEqual(mode & 0o777, 0o700)
    }

    func testAssistantWorkspaceRejectsFileConflictWithoutReplacingIt() throws {
        let root = try makeTemporaryCachesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let product = root.appendingPathComponent("dev.screenlog", isDirectory: true)
        try FileManager.default.createDirectory(at: product, withIntermediateDirectories: false)
        let workspace = product.appendingPathComponent("Assistant Handoff Workspace")
        let marker = Data("keep me".utf8)
        try marker.write(to: workspace)

        XCTAssertThrowsError(
            try AssistantHandoffWorkspacePreparer(cachesDirectory: root)
                .prepareWorkspace()
        ) { error in
            XCTAssertEqual(
                error as? AssistantHandoffWorkspacePreparationError,
                .unsafeFilesystemNode
            )
        }
        XCTAssertEqual(try Data(contentsOf: workspace), marker)
    }

    func testAssistantWorkspaceRejectsLeafAndIntermediateSymlinks() throws {
        let fileManager = FileManager.default

        do {
            let root = try makeTemporaryCachesRoot()
            defer { try? fileManager.removeItem(at: root) }
            let product = root.appendingPathComponent("dev.screenlog", isDirectory: true)
            let target = root.appendingPathComponent("target", isDirectory: true)
            try fileManager.createDirectory(at: product, withIntermediateDirectories: false)
            try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
            let workspace = product.appendingPathComponent("Assistant Handoff Workspace")
            try fileManager.createSymbolicLink(at: workspace, withDestinationURL: target)

            XCTAssertThrowsError(
                try AssistantHandoffWorkspacePreparer(cachesDirectory: root)
                    .prepareWorkspace()
            )
            XCTAssertTrue(fileManager.fileExists(atPath: target.path))
            XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: workspace.path), target.path)
        }

        do {
            let root = try makeTemporaryCachesRoot()
            defer { try? fileManager.removeItem(at: root) }
            let target = root.appendingPathComponent("target", isDirectory: true)
            try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
            let product = root.appendingPathComponent("dev.screenlog", isDirectory: true)
            try fileManager.createSymbolicLink(at: product, withDestinationURL: target)

            XCTAssertThrowsError(
                try AssistantHandoffWorkspacePreparer(cachesDirectory: root)
                    .prepareWorkspace()
            )
            XCTAssertTrue(fileManager.fileExists(atPath: target.path))
            XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: product.path), target.path)
        }
    }

    func testWorkspaceFailureStopsEveryTerminalContract() {
        for contract in AssistantHandoffDestination.TerminalContract.allCases {
            XCTAssertThrowsError(
                try AssistantHandoffLaunchService.preparedTerminalShellCommand(
                    executableURL: URL(fileURLWithPath: "/Users/example/bin/assistant"),
                    contract: contract,
                    request: "Find the review",
                    workspacePreparer: FailingAssistantHandoffWorkspacePreparer()
                )
            ) { error in
                XCTAssertEqual(
                    error as? AssistantHandoffLaunchError,
                    .couldNotPrepareWorkspace,
                    "Unexpected failure for \(contract)"
                )
            }
        }
    }

    private func makeTemporaryCachesRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlogger-handoff-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct FixedAssistantHandoffWorkspacePreparer: AssistantHandoffWorkspacePreparing {
    let url: URL

    func prepareWorkspace() throws -> URL { url }
}

private struct FailingAssistantHandoffWorkspacePreparer: AssistantHandoffWorkspacePreparing {
    func prepareWorkspace() throws -> URL {
        throw AssistantHandoffWorkspacePreparationError.couldNotCreateDirectory
    }
}
