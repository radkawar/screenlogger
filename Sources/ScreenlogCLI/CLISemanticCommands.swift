import Foundation
import ScreenlogCore

/// Parse the complete request before opening IPC. Semantic controls never infer consent.
enum CLISemanticOperation {
    case status(json: Bool)
    case control(SemanticControlRequest)

    static func parse(_ args: [String]) throws -> CLISemanticOperation {
        guard let command = args.first else { throw CLIError.usage(ScreenlogCLIMain.semanticHelp) }
        let flags = try CLISemanticArguments(
            Array(args.dropFirst()), valueFlags: command == "download" || command == "enable" ? ["--mode"] : [],
            booleanFlags: command == "status" ? ["--json"] : ["--yes"])
        guard flags.positionals.isEmpty else { throw CLIError.message("Unexpected semantic argument.") }
        if command == "status" { return .status(json: flags.switches.contains("--json")) }
        let action: SemanticControlAction
        switch command {
        case "download": action = .downloadModels
        case "enable": action = .enable
        case "disable": action = .disable
        case "pause": action = .pause
        case "resume": action = .resume
        case "index-now": action = .indexNow
        case "remove-index": action = .removeIndex
        case "remove-models": action = .removeModels
        default: throw CLIError.usage(ScreenlogCLIMain.semanticHelp)
        }
        guard flags.switches.contains("--yes") else {
            throw CLIError.message("Semantic changes require explicit user approval and --yes.")
        }
        let mode = try flags.mode()
        if action == .downloadModels || action == .enable {
            guard mode != nil else { throw CLIError.message("--mode images|text|both is required.") }
        }
        return .control(SemanticControlRequest(action: action, mode: mode))
    }
}

struct CLISemanticQuery {
    let request: SemanticSearchRequest
    let json: Bool

    static func parse(_ args: [String]) throws -> CLISemanticQuery {
        let flags = try CLISemanticArguments(args, valueFlags: ["--query", "--mode", "--limit"], booleanFlags: ["--json"])
        guard flags.positionals.count <= 1, flags.values["--query"] == nil || flags.positionals.isEmpty else {
            throw CLIError.message("Use one quoted QUERY or --query, not both.")
        }
        let query = flags.values["--query"] ?? flags.positionals.first ?? ""
        let parsed = SearchOperatorParser.parse(query)
        if let issue = parsed.validationIssue { throw CLIError.message(issue) }
        guard !parsed.ftsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            query.utf8.count <= 4096, !query.utf8.contains(0)
        else { throw CLIError.message("QUERY must contain search text and at most 4096 bytes, without NUL bytes.") }
        let limit: Int
        if let raw = flags.values["--limit"] {
            guard let value = Int(raw), (1...500).contains(value) else {
                throw CLIError.message("--limit must be between 1 and 500.")
            }
            limit = value
        } else {
            limit = 50
        }
        return CLISemanticQuery(
            request: SemanticSearchRequest(query: query, mode: try flags.mode(), limit: limit), json: flags.switches.contains("--json"))
    }
}

private struct CLISemanticArguments {
    var values: [String: String] = [:]
    var switches: Set<String> = []
    var positionals: [String] = []

    init(_ args: [String], valueFlags: Set<String>, booleanFlags: Set<String>) throws {
        var index = 0
        while index < args.count {
            let argument = args[index]
            if valueFlags.contains(argument) {
                guard values[argument] == nil else { throw CLIError.message("Duplicate flag: \(argument)") }
                index += 1
                guard index < args.count, !args[index].hasPrefix("--") else {
                    throw CLIError.message("Missing value for \(argument).")
                }
                values[argument] = args[index]
            } else if booleanFlags.contains(argument) {
                guard switches.insert(argument).inserted else { throw CLIError.message("Duplicate flag: \(argument)") }
            } else if argument.hasPrefix("-") {
                throw CLIError.message("Unknown flag: \(argument)")
            } else {
                positionals.append(argument)
            }
            index += 1
        }
    }

    func mode() throws -> SemanticSearchMode? {
        guard let raw = values["--mode"] else { return nil }
        guard let mode = SemanticSearchMode(rawValue: raw) else {
            throw CLIError.message("--mode must be images, text, or both.")
        }
        return mode
    }
}

extension ScreenlogCLIMain {
    static let semanticHelp = """
        Usage:
          screenlog semantic status [--json]
          screenlog semantic download --mode images|text|both --yes
          screenlog semantic enable --mode images|text|both --yes
          screenlog semantic index-now --yes
          screenlog semantic disable|pause|resume|remove-index|remove-models --yes

        Semantic search is off by default. Status and queries never download or enable models.
        Images searches screen appearance. Text searches screen text and transcripts. Both uses both sources.
        Download accepts background installation. Use status to inspect progress before enable.
        index-now uses installed models and current sources. It never downloads, enables, or changes modes.
        Automatic indexing waits for 60 seconds of idle time and external power. index-now skips those waits
        until the backlog is finished. Both wait for available memory, normal temperature, and Low Power Mode to end.
        Changes require user approval, --yes, and Allow capture control and maintenance in Settings > Integrations.
        remove-index removes derived vectors, not captured history. remove-models removes downloaded models.
        """

    static let semanticQueryHelp = """
        Usage:
          screenlog query semantic <QUERY> [--mode images|text|both] [--limit 1...500] [--json]
          screenlog query semantic --query <QUERY> [--mode images|text|both] [--limit 1...500] [--json]

        QUERY supports app:, site:, date:, since:, and before: operators.
        Mode can narrow enabled sources. It cannot enable a source or install a model.
        Scores are cosine similarity, not confidence. Inspect candidate frames before using them as evidence.
        Coverage can be partial while indexing. Use exact search for names, codes, and identifiers.
        Example: screenlog query semantic 'a blue chart app:Safari since:2026-10-01' --mode images --json
        """

    static func semantic(_ args: [String], client: ScreenlogXPCClient) throws {
        switch try CLISemanticOperation.parse(args) {
        case .status(let json):
            do { try printSemanticStatus(client.semanticStatus(), json: json) } catch {
                if json { try printSemanticError(error, status: nil) }
                throw error
            }
        case .control(let request):
            try printSemanticStatus(client.semanticControl(request), json: false)
        }
    }

    static func semanticQuery(_ args: [String], client: ScreenlogXPCClient) throws {
        let parsed = try CLISemanticQuery.parse(args)
        do {
            let response = try client.semanticSearch(parsed.request)
            if parsed.json {
                print(try CLIOutputFormat.json(CLISemanticSearchDocument(response)))
            } else {
                try printSemanticStatus(response.status, json: false)
                for hit in response.hits {
                    print(
                        "#\(hit.result.frameID)\t\(CLIOutputFormat.localISO(hit.result.timestampMs))\t\(hit.kind.rawValue)\tcosine=\(hit.score)\toccurrences=\(hit.occurrenceCount)\t\(hit.result.bundleID ?? "-")\t\(hit.result.snippet ?? hit.result.title ?? "")"
                    )
                }
                if response.hits.isEmpty { print("No related results in the indexed sources for these filters.") }
            }
        } catch {
            if parsed.json {
                let status = error is SemanticSearchError ? try? client.semanticStatus() : nil
                try printSemanticError(error, status: status)
            }
            throw error
        }
    }

    private static func printSemanticStatus(_ status: SemanticFeatureStatus, json: Bool) throws {
        if json {
            print(try CLIOutputFormat.json(CLISemanticStatusDocument(status)))
        } else {
            print(
                "semantic: \(status.phase.rawValue); enabled=\(status.enabled); mode=\(status.mode.rawValue); model_installed=\(status.modelInstalled); indexing_policy=\(status.indexingPolicy.rawValue)"
            )
            print("download_bytes: \(status.downloadedBytes)/\(status.downloadBytes)")
            print(
                "sources: indexed=\(status.index.indexedSources) pending=\(status.index.pendingSources) failed=\(status.index.failedSources); vectors=\(status.index.vectorCount) bytes=\(status.index.vectorBytes)"
            )
        }
    }

    private static func printSemanticError(_ error: Error, status: SemanticFeatureStatus?) throws {
        print(try CLIOutputFormat.json(CLISemanticErrorDocument(error: error, status: status)))
    }
}
