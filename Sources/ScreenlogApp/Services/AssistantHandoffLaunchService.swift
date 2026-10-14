import AppKit
import Foundation
import ScreenlogCore

/// A configured assistant and the direct handoff its installed host supports.
/// Destinations without a direct delivery contract are intentionally omitted
/// from the Library flow; clipboard handoffs are never treated as connected.
struct AssistantHandoffDestination: Identifiable, Equatable {
    enum TerminalContract: CaseIterable, Equatable {
        /// Claude accepts the reviewed request as its first argument, but has
        /// no working-directory option of its own.
        case claude
        /// Cursor accepts the reviewed request as its first argument, but has
        /// no documented working-directory option of its own.
        case cursor
        /// Codex accepts an explicit working root before the initial request.
        case codex
        /// Grok needs a non-special working directory or it intercepts the
        /// first request with its project picker.
        case grok
        /// OpenClaw exposes a one-turn command rather than an interactive TUI.
        case openClaw
    }

    enum Delivery: Equatable {
        /// Launches the assistant CLI in Terminal with an initial request.
        case terminalCommand(TerminalContract)
        /// Opens Claude Code's registered request URL.
        case claudeCodePrefill
        /// Opens OpenClaw's registered approval URL.
        case openClawApproval
    }

    let target: AssistantIntegrationTarget
    let delivery: Delivery
    let applicationURL: URL?
    let executableURL: URL?

    var id: AssistantIntegrationTarget { target }

    var actionTitle: String {
        switch delivery {
        case .terminalCommand(.openClaw):
            return "Ask \(target.label)"
        case .terminalCommand, .claudeCodePrefill, .openClawApproval:
            return "Open in \(target.label)"
        }
    }

    var actionSystemImage: String {
        switch delivery {
        case .terminalCommand:
            return "terminal"
        case .claudeCodePrefill, .openClawApproval:
            return "arrow.up.forward.app"
        }
    }

    var privacyDetail: String {
        switch delivery {
        case .terminalCommand(.openClaw):
            return "Runs one \(target.label) turn in Terminal with your search request."
        case .terminalCommand:
            return "Opens \(target.label) in Terminal with your search request."
        case .claudeCodePrefill:
            return "Opens Claude Code with your search request ready to run."
        case .openClawApproval:
            return "Opens OpenClaw so you can approve your search request."
        }
    }
}

enum AssistantHandoffLaunchOutcome: Equatable {
    case opened
}

enum AssistantHandoffLaunchError: LocalizedError, Equatable {
    case invalidLink
    case invalidTerminalCommand
    case couldNotPrepareWorkspace
    case couldNotOpenAssistant

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            return "Screenlogger could not create a safe assistant link."
        case .invalidTerminalCommand:
            return "Screenlogger could not prepare a safe Terminal handoff."
        case .couldNotPrepareWorkspace:
            return "Screenlogger could not prepare its private assistant handoff workspace. Screenlogger did not send anything."
        case .couldNotOpenAssistant:
            return "Screenlogger could not open the assistant. Screenlogger did not send anything."
        }
    }
}

enum AssistantHandoffWorkspacePreparationError: Error, Equatable {
    case cacheDirectoryUnavailable
    case unsafeFilesystemNode
    case couldNotCreateDirectory
}

protocol AssistantHandoffWorkspacePreparing {
    func prepareWorkspace() throws -> URL
}

/// Creates a metadata-only working directory for command-line handoffs. It is
/// kept outside Screenlogger's Library so an assistant never receives captured
/// data merely because it was launched, and so coding agents never treat the
/// user's entire home directory as their working root.
struct AssistantHandoffWorkspacePreparer: AssistantHandoffWorkspacePreparing {
    private let fileManager: FileManager
    private let cachesDirectoryOverride: URL?

    init(
        fileManager: FileManager = .default,
        cachesDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        cachesDirectoryOverride = cachesDirectory
    }

    func prepareWorkspace() throws -> URL {
        guard
            let cachesDirectory = cachesDirectoryOverride
                ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        else {
            throw AssistantHandoffWorkspacePreparationError.cacheDirectoryUnavailable
        }

        let cachesRoot = cachesDirectory.standardizedFileURL
        try requireExistingDirectory(cachesRoot)

        let productCache = cachesRoot.appendingPathComponent(
            ScreenlogPaths.appSupportName,
            isDirectory: true
        )
        try ensureDirectory(productCache)

        let workspace = productCache.appendingPathComponent(
            "Assistant Handoff Workspace",
            isDirectory: true
        )
        try ensureDirectory(workspace)
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: workspace.path
            )
        } catch {
            throw AssistantHandoffWorkspacePreparationError.couldNotCreateDirectory
        }
        return workspace.standardizedFileURL
    }

    private func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw AssistantHandoffWorkspacePreparationError.unsafeFilesystemNode
            }
            try requireExistingDirectory(url)
            return
        }

        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw AssistantHandoffWorkspacePreparationError.couldNotCreateDirectory
        }
        try requireExistingDirectory(url)
    }

    private func requireExistingDirectory(_ url: URL) throws {
        do {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw AssistantHandoffWorkspacePreparationError.unsafeFilesystemNode
            }
        } catch let error as AssistantHandoffWorkspacePreparationError {
            throw error
        } catch {
            throw AssistantHandoffWorkspacePreparationError.unsafeFilesystemNode
        }
    }
}

@MainActor
enum AssistantHandoffLaunchService {
    static func destination(
        for target: AssistantIntegrationTarget,
        presence: AgentPresence.Result,
        workspace: NSWorkspace = .shared
    ) -> AssistantHandoffDestination? {
        if let executableURL = presence.cliURL {
            return AssistantHandoffDestination(
                target: target,
                delivery: .terminalCommand(terminalContract(for: target)),
                applicationURL: presence.appURL,
                executableURL: executableURL
            )
        }

        switch target {
        case .claude:
            guard hasRegisteredHandler(forScheme: "claude-cli", workspace: workspace) else {
                return nil
            }
            return AssistantHandoffDestination(
                target: target,
                delivery: .claudeCodePrefill,
                applicationURL: presence.appURL,
                executableURL: nil
            )

        case .openclaw:
            guard hasRegisteredHandler(forScheme: "openclaw", workspace: workspace) else {
                return nil
            }
            return AssistantHandoffDestination(
                target: target,
                delivery: .openClawApproval,
                applicationURL: presence.appURL,
                executableURL: nil
            )

        case .cursor, .codex, .grok:
            // These hosts do not currently publish a stable macOS request URL.
            // An installed app alone therefore cannot promise a direct handoff.
            return nil
        }
    }

    static func launch(
        _ destination: AssistantHandoffDestination,
        prompt: String,
        workspace: NSWorkspace = .shared
    ) async throws -> AssistantHandoffLaunchOutcome {
        switch destination.delivery {
        case .terminalCommand(let contract):
            guard
                let executableURL = destination.executableURL,
                let command = try preparedTerminalShellCommand(
                    executableURL: executableURL,
                    contract: contract,
                    request: prompt
                )
            else {
                throw AssistantHandoffLaunchError.invalidTerminalCommand
            }
            try await openInTerminal(command)
            return .opened

        case .claudeCodePrefill:
            guard
                let url = promptURL(
                    scheme: "claude-cli",
                    host: "open",
                    queryName: "q",
                    prompt: prompt
                )
            else {
                throw AssistantHandoffLaunchError.invalidLink
            }
            guard workspace.open(url) else {
                throw AssistantHandoffLaunchError.couldNotOpenAssistant
            }
            return .opened

        case .openClawApproval:
            guard
                let url = promptURL(
                    scheme: "openclaw",
                    host: "agent",
                    queryName: "message",
                    prompt: prompt
                )
            else {
                throw AssistantHandoffLaunchError.invalidLink
            }
            guard workspace.open(url) else {
                throw AssistantHandoffLaunchError.couldNotOpenAssistant
            }
            return .opened
        }
    }

    nonisolated static func promptURL(
        scheme: String,
        host: String,
        queryName: String,
        prompt: String
    ) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: queryName, value: prompt)]
        return components.url
    }

    /// Builds the one command Terminal receives. Every value is passed as a
    /// distinct, single-quoted shell word so search text cannot become syntax.
    nonisolated static func terminalShellCommand(
        executableURL: URL,
        argumentsBeforeRequest: [String],
        request: String,
        workingDirectoryURL: URL? = nil
    ) -> String? {
        let hasSafeWorkingDirectory =
            workingDirectoryURL.map { url in
                url.isFileURL && url.path.hasPrefix("/") && !url.path.contains("\0")
            } ?? true
        guard
            executableURL.isFileURL,
            executableURL.path.hasPrefix("/"),
            !executableURL.path.contains("\0"),
            !request.contains("\0"),
            !argumentsBeforeRequest.contains(where: { $0.contains("\0") }),
            hasSafeWorkingDirectory
        else { return nil }

        let arguments = [executableURL.path] + argumentsBeforeRequest + [request]
        let executableCommand = "exec " + arguments.map(shellQuote).joined(separator: " ")
        guard let workingDirectoryURL else { return executableCommand }
        return "cd " + shellQuote(workingDirectoryURL.path) + " && " + executableCommand
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func preparedTerminalShellCommand(
        executableURL: URL,
        contract: AssistantHandoffDestination.TerminalContract,
        request: String,
        workspacePreparer: any AssistantHandoffWorkspacePreparing =
            AssistantHandoffWorkspacePreparer()
    ) throws -> String? {
        let workspace: URL
        do {
            workspace = try workspacePreparer.prepareWorkspace()
        } catch {
            throw AssistantHandoffLaunchError.couldNotPrepareWorkspace
        }

        let argumentsBeforeRequest: [String]
        let shellWorkingDirectory: URL?
        switch contract {
        case .claude, .cursor:
            argumentsBeforeRequest = []
            shellWorkingDirectory = workspace
        case .codex:
            argumentsBeforeRequest = ["--cd", workspace.path]
            shellWorkingDirectory = nil
        case .grok:
            argumentsBeforeRequest = ["--cwd", workspace.path]
            shellWorkingDirectory = nil
        case .openClaw:
            argumentsBeforeRequest = [
                "agent", "exec", "--no-auth-env-only", "--cwd", workspace.path,
            ]
            shellWorkingDirectory = nil
        }
        return terminalShellCommand(
            executableURL: executableURL,
            argumentsBeforeRequest: argumentsBeforeRequest,
            request: request,
            workingDirectoryURL: shellWorkingDirectory
        )
    }

    private static func terminalContract(
        for target: AssistantIntegrationTarget
    ) -> AssistantHandoffDestination.TerminalContract {
        switch target {
        case .claude:
            return .claude
        case .cursor:
            return .cursor
        case .codex:
            return .codex
        case .openclaw:
            return .openClaw
        case .grok:
            return .grok
        }
    }

    private static func hasRegisteredHandler(
        forScheme scheme: String,
        workspace: NSWorkspace
    ) -> Bool {
        guard let probe = URL(string: "\(scheme)://open") else { return false }
        return workspace.urlForApplication(toOpen: probe) != nil
    }

    /// Uses argv to move the fully quoted shell command into AppleScript. It
    /// is never interpolated into AppleScript source.
    private static func openInTerminal(_ command: String) async throws {
        let source = [
            "on run argv",
            "if (count of argv) is not 1 then error \"Expected one command\"",
            "set shellCommand to item 1 of argv",
            "tell application id \"com.apple.Terminal\"",
            "activate",
            "do script shellCommand",
            "end tell",
            "end run",
        ]
        let arguments = source.flatMap { ["-e", $0] } + ["--", command]

        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { completed in
                if completed.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: AssistantHandoffLaunchError.couldNotOpenAssistant
                    )
                }
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(
                    throwing: AssistantHandoffLaunchError.couldNotOpenAssistant
                )
            }
        }
    }
}
