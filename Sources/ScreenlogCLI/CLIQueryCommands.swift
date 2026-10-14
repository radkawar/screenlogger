import Foundation
import ScreenlogCore

extension ScreenlogCLIMain {
    // MARK: - search / query

    static let searchHelp = """
        Usage:
          screenlog search <QUERY> [--content all|screen|transcripts]
                           [--literal] [--dedupe-seconds N] [--limit 1...500] [--json]

        QUERY supports app:, site:, date:, since:, and before: operators.
        --literal keeps tokenizer terms adjacent and in order. It does not match punctuation byte for byte.

        Example:
          screenlog search 'release app:Safari since:7d' --dedupe-seconds 30 --json
        """

    static let queryHelp = """
        Usage:
          screenlog query frame --id N | --ids N,N,N | --at DATE
                                [--show-ocr] [--max-ocr-chars N] [--json]
          screenlog query context --id N [--before N] [--after N]
                                  [--show-ocr] [--max-ocr-chars N] [--json]
          screenlog query sample [--since DATE|30d] [--before DATE]
                                 [--order oldest|newest] [--cursor DATE]
                                 [--limit 1...500] [--min-seg-len N]
                                 [--show-ocr] [--max-ocr-chars N] [--json]
          screenlog query fts <QUERY> [search options]
          screenlog query semantic <QUERY> [--mode images|text|both] [--limit 1...500] [--json]
          screenlog query image|ocrboxes|axtree ...
        """

    static let recentHelp = """
        Usage: screenlog recent [--limit 1...500] [--show-ocr]
                                [--max-ocr-chars N] [--json]

        This command returns the newest captured moments with one representative display per moment.
        Example: screenlog recent --limit 20 --show-ocr --max-ocr-chars 500 --json
        """

    static func queryHelp(for subcommand: String?) -> String {
        switch subcommand {
        case "frame":
            return """
                Usage: screenlog query frame --id N | --ids N,N,N | --at DATE
                                             [--show-ocr] [--max-ocr-chars N] [--json]

                Example: screenlog query frame --ids 123,456 --show-ocr --max-ocr-chars 1000 --json
                """
        case "context":
            return """
                Usage: screenlog query context --id N [--before N] [--after N]
                                               [--show-ocr] [--max-ocr-chars N] [--json]

                Example: screenlog query context --id 456 --before 3 --after 3 --show-ocr --json
                """
        case "sample":
            return """
                Usage: screenlog query sample [--since DATE|30d] [--before DATE]
                                              [--order oldest|newest] [--cursor DATE]
                                              [--limit 1...500] [--min-seg-len N]
                                              [--show-ocr] [--max-ocr-chars N] [--json]

                Sampling selects results across the requested range. It does not return every result.
                Use nextCursorMs to sample the remaining range after or before the last timestamp again.
                Example: screenlog query sample --since 7d --limit 40 --show-ocr --json
                """
        case "fts":
            return searchHelp.replacingOccurrences(of: "screenlog search", with: "screenlog query fts")
        case "semantic":
            return semanticQueryHelp
        case "image":
            return "Usage: screenlog query image --id N | --at DATE [--out PATH] [--base64] [--json]"
        case "ocrboxes":
            return "Usage: screenlog query ocrboxes --id N"
        case "axtree":
            return "Usage: screenlog query axtree --id N"
        default:
            return queryHelp
        }
    }

    /// `screenlog search "query"` - structured Library search over the app bridge.
    static func search(_ args: [String], client: ScreenlogXPCClient) throws {
        if args.contains(where: isHelpArgument) {
            print(searchHelp)
            return
        }
        let q =
            try stringFlag(args, name: "--query")
            ?? positionalArguments(
                args,
                valueFlags: ["--query", "--limit", "--content", "--dedupe-seconds"]
            ).first
            ?? ""
        let limit = try intFlag(args, name: "--limit", allowed: 1...500) ?? 50
        let content = try searchContentFlag(args)
        let json = args.contains("--json")
        let dedupeSeconds = try intFlag(args, name: "--dedupe-seconds", allowed: 0...3600) ?? 0
        try printFTS(
            query: q,
            limit: limit,
            content: content,
            literal: args.contains("--literal"),
            dedupeSeconds: dedupeSeconds,
            json: json,
            client: client
        )
    }

    static func query(_ args: [String], client: ScreenlogXPCClient) throws {
        guard let sub = args.first else {
            print(queryHelp)
            return
        }
        if isHelpArgument(sub) {
            print(queryHelp)
            return
        }
        let rest = Array(args.dropFirst())
        if rest.contains(where: isHelpArgument) {
            print(queryHelp(for: sub))
            return
        }
        switch sub {
        case "semantic":
            try semanticQuery(rest, client: client)
        case "fts":
            let q =
                try stringFlag(rest, name: "--query")
                ?? positionalArguments(
                    rest,
                    valueFlags: ["--query", "--limit", "--content", "--dedupe-seconds"]
                ).first
                ?? ""
            let limit = try intFlag(rest, name: "--limit", allowed: 1...500) ?? 50
            let content = try searchContentFlag(rest)
            let json = rest.contains("--json")
            let dedupeSeconds = try intFlag(rest, name: "--dedupe-seconds", allowed: 0...3600) ?? 0
            try printFTS(
                query: q,
                limit: limit,
                content: content,
                literal: rest.contains("--literal"),
                dedupeSeconds: dedupeSeconds,
                json: json,
                client: client
            )
        case "frame":
            let maximumOCRCharacters = try maximumOCRCharacters(rest)
            let frames: [FrameRow]
            if let ids = try stringFlag(rest, name: "--ids") {
                frames = try client.frames(ids: commaSeparatedIDs(ids, maximumCount: 100))
            } else if let at = try stringFlag(rest, name: "--at") {
                let ms = try parseTimestampMs(at)
                frames = [try client.frameAt(timestampMs: ms)]
            } else {
                guard
                    let id = try int64Flag(rest, name: "--id", allowed: 1...Int64.max)
                        ?? positionalArguments(
                            rest,
                            valueFlags: ["--id", "--ids", "--at", "--max-ocr-chars"]
                        ).compactMap({ Int64($0) }).first,
                    id > 0
                else {
                    throw CLIError.usage(
                        "query frame --id N | --ids N,N,N | --at DATE [--show-ocr] [--max-ocr-chars N] [--json]"
                    )
                }
                frames = [try client.frame(id: id)]
            }
            try printFrames(
                frames,
                maximumOCRCharacters: maximumOCRCharacters,
                json: rest.contains("--json")
            )
        case "context":
            guard let id = try int64Flag(rest, name: "--id", allowed: 1...Int64.max) else {
                throw CLIError.usage("query context --id N [--before N] [--after N]")
            }
            let before = try intFlag(rest, name: "--before", allowed: 0...50) ?? 3
            let after = try intFlag(rest, name: "--after", allowed: 0...50) ?? 3
            guard before + after > 0 else {
                throw CLIError.message("--before and --after cannot both be zero")
            }
            try printFrames(
                try client.context(frameID: id, before: before, after: after),
                maximumOCRCharacters: try maximumOCRCharacters(rest),
                json: rest.contains("--json")
            )
        case "image":
            try image(rest, client: client)
        case "sample":
            let limit = try intFlag(rest, name: "--limit", allowed: 1...500) ?? 50
            let minSeg = try intFlag(rest, name: "--min-seg-len", allowed: 1...10_000) ?? 1
            let order = try sampleOrder(rest)
            let bounds = try sampleActivityBounds(rest, order: order)
            let frames = try client.sample(
                limit: limit,
                minSegLen: minSeg,
                fromTimestampMs: bounds.sinceMs,
                toTimestampMs: bounds.beforeMs,
                order: order
            )
            let maximumOCRCharacters = try maximumOCRCharacters(rest)
            if rest.contains("--json") {
                print(
                    try CLIOutputFormat.json(
                        CLIFramePageDocument(
                            frames: frames.map {
                                CLIFrameDocument(
                                    frame: $0,
                                    maximumOCRCharacters: maximumOCRCharacters
                                )
                            },
                            nextCursorMs: frames.last?.timestampMs
                        )
                    )
                )
            } else {
                for frame in frames {
                    for line in humanReadableSampleLines(
                        frame: frame,
                        maximumOCRCharacters: maximumOCRCharacters
                    ) {
                        print(line)
                    }
                }
                if let cursor = frames.last?.timestampMs {
                    FileHandle.standardError.write(Data("next_cursor: \(cursor)\n".utf8))
                }
            }
        case "ocrboxes":
            guard let id = try int64Flag(rest, name: "--id", allowed: 1...Int64.max) else {
                throw CLIError.usage("query ocrboxes --id N")
            }
            for b in try client.ocrBoxes(frameID: id) {
                print("\(b.x),\(b.y) \(b.width)x\(b.height) off=\(b.textOffset) len=\(b.textLength)")
            }
        case "axtree":
            guard let id = try int64Flag(rest, name: "--id", allowed: 1...Int64.max) else {
                throw CLIError.usage("query axtree --id N")
            }
            print(try client.axTree(frameID: id))
        default:
            throw CLIError.unknown("query \(sub)")
        }
    }

    static func recent(_ args: [String], client: ScreenlogXPCClient) throws {
        if args.contains(where: isHelpArgument) {
            print(recentHelp)
            return
        }
        let limit = try intFlag(args, name: "--limit", allowed: 1...500) ?? 20
        try printFrames(
            client.recent(limit: limit),
            maximumOCRCharacters: try maximumOCRCharacters(args),
            json: args.contains("--json")
        )
    }

    static func printFTS(
        query: String,
        limit: Int,
        content: LibrarySearchContent,
        literal: Bool,
        dedupeSeconds: Int,
        json: Bool,
        client: ScreenlogXPCClient
    ) throws {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CLIError.usage(
                "search <QUERY> [--content all|screen|transcripts] [--limit 1...500] [--json]"
            )
        }
        guard normalized.utf8.count <= 4_096 else {
            throw CLIError.message("query contains more than 4096 bytes")
        }
        let fetchLimit = dedupeSeconds > 0 ? min(500, max(limit, limit * 3)) : limit
        let rawResults = try client.fts(
            query: normalized,
            limit: fetchLimit,
            content: content,
            literal: literal
        )
        let results = Array(
            deduplicatedSearchResults(rawResults, withinSeconds: dedupeSeconds).prefix(limit)
        )
        if json {
            print(try CLIOutputFormat.json(results.map(CLISearchResultDocument.init)))
        } else {
            for r in results {
                print(
                    "#\(r.frameID)\t\(CLIOutputFormat.localISO(r.timestampMs))"
                        + "\t\(r.bundleID ?? "-")\t\(r.snippet ?? r.title ?? "")"
                )
            }
            if results.isEmpty {
                FileHandle.standardError.write(Data("no matches\n".utf8))
            }
        }
    }

    private static func searchContentFlag(_ args: [String]) throws -> LibrarySearchContent {
        guard let raw = try stringFlag(args, name: "--content")?.lowercased() else {
            return .all
        }
        switch raw {
        case "all": return .all
        case "screen", "text", "ocr": return .screenText
        case "transcripts", "transcript", "audio": return .transcripts
        default:
            throw CLIError.usage("--content must be all, screen, or transcripts")
        }
    }

    static func printFrames(
        _ frames: [FrameRow],
        maximumOCRCharacters: Int,
        json: Bool
    ) throws {
        let documents = frames.map {
            CLIFrameDocument(frame: $0, maximumOCRCharacters: maximumOCRCharacters)
        }
        if json {
            print(try CLIOutputFormat.json(documents))
            return
        }
        for (index, document) in documents.enumerated() {
            if index > 0 { print("") }
            print("id: \(document.id)")
            print("timestamp: \(document.timestamp)")
            print("timestamp_ms: \(document.timestampMs)")
            print("title: \(document.title ?? "")")
            print("segment_id: \(document.segmentID.map(String.init) ?? "")")
            print("size: \(document.width ?? 0)x\(document.height ?? 0)")
            if let ocr = document.ocr {
                print("--- OCR\(document.ocrTruncated ? " (truncated)" : "") ---")
                print(ocr)
            }
        }
    }

    private static func maximumOCRCharacters(_ args: [String]) throws -> Int {
        guard args.contains("--show-ocr") else { return 0 }
        return try intFlag(args, name: "--max-ocr-chars", allowed: 1...20_000) ?? 2_000
    }

    private static func sampleOrder(_ args: [String]) throws -> ActivitySortOrder {
        guard let raw = try stringFlag(args, name: "--order")?.lowercased() else {
            return .oldest
        }
        guard let order = ActivitySortOrder(rawValue: raw) else {
            throw CLIError.message("--order must be oldest or newest")
        }
        return order
    }

    static func humanReadableSampleLines(
        frame: FrameRow,
        maximumOCRCharacters: Int
    ) -> [String] {
        let document = CLIFrameDocument(
            frame: frame,
            maximumOCRCharacters: maximumOCRCharacters
        )
        var lines = [
            "#\(frame.id)\t\(CLIOutputFormat.localISO(frame.timestampMs))"
                + "\tseg=\(frame.segmentID ?? -1)\t\(frame.title ?? "")"
        ]
        if let ocr = document.ocr {
            lines.append("  OCR\(document.ocrTruncated ? " (truncated)" : ""): \(ocr)")
        }
        return lines
    }

    private static func deduplicatedSearchResults(
        _ results: [FTSResult],
        withinSeconds: Int
    ) -> [FTSResult] {
        guard withinSeconds > 0 else { return results }
        let threshold = Int64(withinSeconds) * 1000
        var kept: [FTSResult] = []
        for result in results {
            let duplicate =
                kept.last.map {
                    abs($0.timestampMs - result.timestampMs) <= threshold
                        && $0.bundleID == result.bundleID
                        && $0.domain == result.domain
                        && searchResultFingerprint($0) == searchResultFingerprint(result)
                } ?? false
            if !duplicate { kept.append(result) }
        }
        return kept
    }

    private static func searchResultFingerprint(_ result: FTSResult) -> String {
        (result.snippet ?? result.title ?? "")
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(16)
            .joined(separator: " ")
    }

    // MARK: - image

    /// `screenlog image --at <iso-or-epoch> [--out path] [--base64] [--id N]`
    static func image(_ args: [String], client: ScreenlogXPCClient) throws {
        let out = try stringFlag(args, name: "--out", maximumBytes: 4_096)
        let preferBase64 = args.contains("--base64")
        let json = args.contains("--json")
        let id = try int64Flag(args, name: "--id", allowed: 1...Int64.max)
        let atRaw = try stringFlag(args, name: "--at")

        guard id != nil || atRaw != nil else {
            throw CLIError.usage("image --at <iso-or-epoch> | --id N [--out path] [--base64] [--json]")
        }

        let timestampMs: Int64
        if let atRaw {
            timestampMs = try parseTimestampMs(atRaw)
        } else {
            timestampMs = 0
        }

        let result = try client.extractImage(
            frameID: id ?? 0,
            timestampMs: timestampMs,
            outPath: out ?? "",
            preferBase64: preferBase64
        )

        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: try enc.encode(result), encoding: .utf8)!)
            return
        }

        print("frame_id: \(result.frameID)")
        print("timestamp_ms: \(result.timestampMs)")
        print("source: \(result.source)")
        print("bytes: \(result.byteCount)")
        print("ext: \(result.fileExtension)")
        if let path = result.path {
            print("path: \(path)")
        }
        if let b64 = result.base64 {
            print("base64: \(b64)")
        }
    }
}
