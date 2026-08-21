import Foundation
import ScreenlogCore

/// Thin command-line client for Screenlogger.app. It never opens SQLite directly.
@main
enum ScreenlogCLIMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            try await run(args: args)
        } catch let err as XPCClientError {
            fflush(stdout)
            fputs("error: \(err)\n", stderr)
            if case .appNotRunning = err {
                fputs("hint: open Screenlogger.app first - the CLI never opens the database itself.\n", stderr)
            }
            exit(1)
        } catch let err as CLIError {
            fflush(stdout)
            fputs("error: \(err)\n", stderr)
            exit(err.exitCode)
        } catch {
            fflush(stdout)
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run(args: [String]) async throws {
        if args.isEmpty || args[0] == "-h" || args[0] == "--help" {
            print(helpText)
            return
        }
        if args[0] == "--version" || args[0] == "-v" {
            print(ScreenlogCore.version)
            return
        }

        let (globals, rest) = try parseGlobals(args)
        let root = globals.root
        guard let cmd = rest.first else {
            print(helpText)
            return
        }
        let sub = Array(rest.dropFirst())

        // Help must be resolved before any client call. In particular,
        // `compact --help` and `retention --help` must never perform work.
        if sub.contains(where: isHelpArgument) {
            print(helpText(for: cmd, subcommand: sub.first))
            return
        }

        // Assistant skill lifecycle is pure filesystem work - no app / XPC required.
        if cmd == "skill" || cmd == "install-skill" {
            let skillArguments = cmd == "install-skill" ? ["install"] + sub : sub
            let result = try SkillInstaller.run(args: skillArguments)
            if !result.changed.isEmpty {
                print("skill: changed \(result.changed.count) path(s).")
            } else if !result.inspected.isEmpty {
                print("skill: no changes needed.")
            }
            return
        }

        let client = ScreenlogXPCClient(root: root)

        switch cmd {
        case "search":
            try search(sub, client: client)
        case "digest", "overview":
            try digest(sub, client: client)
        case "recent":
            try recent(sub, client: client)
        case "query":
            try query(sub, client: client)
        case "image":
            try image(sub, client: client)
        case "status":
            try status(sub, client: client)
        case "usage":
            try usage(sub, client: client)
        case "list":
            try list(sub, client: client)
        case "stats":
            try stats(client: client)
        case "record":
            try record(sub, client: client)
        case "compact":
            let n = try client.compact()
            print("compacted_frames=\(n)")
        case "retention":
            print(try client.retention())
        case "doctor":
            try await doctor(sub, root: root, client: client)
        case "ping":
            print(try client.ping())
        default:
            throw CLIError.unknown(cmd)
        }
    }

    static let helpText = """
        screenlog \(ScreenlogCore.version) - search your local screen history

        Most commands need Screenlogger.app running (the CLI never opens the database).

        Usage:
          screenlog [--data-dir PATH] <command>

        Commands:
          search <QUERY> [--content all|screen|transcripts] [--limit N] [--json]
          digest [--since 30d] [--before DATE] [--json]
          recent [--limit N] [--show-ocr] [--max-ocr-chars N] [--json]
          usage time|coverage|top-applications|top-domains|sessions
          list applications|domains
          query frame|context|image|axtree|sample|ocrboxes|fts ...
          record start|stop|once
          stats | status [--json] | doctor [--json] | ping
          skill install|status [--json]|upgrade|remove [claude|cursor|codex|grok|openclaw|all]
          install-skill [target]  (compatibility alias for `skill install`)
          compact | retention

        `skill` and `install-skill` do not require the app. All other commands do.
        Search combines screen text and transcripts by default.
        Search operators: app:, site:, date:, since:, before:.
        Run any command with --help to view its usage.
        """

    static func helpText(for command: String, subcommand: String?) -> String {
        switch command {
        case "search": return searchHelp
        case "digest", "overview": return digestHelp
        case "recent": return recentHelp
        case "usage":
            return usageHelp(for: subcommand)
        case "query":
            return queryHelp(for: subcommand)
        case "image":
            return "Usage: screenlog image --id N | --at DATE [--out PATH] [--base64] [--json]"
        case "status": return "Usage: screenlog status [--json]"
        case "stats": return "Usage: screenlog stats"
        case "doctor": return "Usage: screenlog doctor [--json]"
        case "ping": return "Usage: screenlog ping"
        case "list": return "Usage: screenlog list applications|domains"
        case "record": return "Usage: screenlog record start|stop|once"
        case "compact": return "Usage: screenlog compact"
        case "retention": return "Usage: screenlog retention"
        case "skill", "install-skill": return SkillInstaller.helpText
        default: return helpText
        }
    }
}
