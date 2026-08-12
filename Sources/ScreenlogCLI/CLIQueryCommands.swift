import Foundation
import ScreenlogCore

extension ScreenlogCLIMain {
    // MARK: - search / query

    /// `screenlog search "query"` - structured Library search over the app bridge.
    static func search(_ args: [String], client: ScreenlogXPCClient) throws {
        let q =
            try stringFlag(args, name: "--query")
            ?? positionalArguments(args, valueFlags: ["--query", "--limit", "--content"]).first
            ?? ""
        let limit = try intFlag(args, name: "--limit", allowed: 1...500) ?? 50
        let content = try searchContentFlag(args)
        let json = args.contains("--json")
        try printFTS(query: q, limit: limit, content: content, json: json, client: client)
    }

    static func query(_ args: [String], client: ScreenlogXPCClient) throws {
        guard let sub = args.first else {
            throw CLIError.usage("query fts|frame|sample|ocrboxes|axtree|image")
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "fts":
            let q =
                try stringFlag(rest, name: "--query")
                ?? positionalArguments(rest, valueFlags: ["--query", "--limit", "--content"]).first
                ?? ""
            let limit = try intFlag(rest, name: "--limit", allowed: 1...500) ?? 50
            let content = try searchContentFlag(rest)
            let json = rest.contains("--json")
            try printFTS(query: q, limit: limit, content: content, json: json, client: client)
        case "frame":
            if let at = try stringFlag(rest, name: "--at") {
                let ms = try parseTimestampMs(at)
                let f = try client.frameAt(timestampMs: ms)
                printFrame(f, showOCR: rest.contains("--show-ocr"))
            } else {
                guard
                    let id = try int64Flag(rest, name: "--id", allowed: 1...Int64.max)
                        ?? positionalArguments(rest, valueFlags: ["--id", "--at"]).compactMap({ Int64($0) }).first,
                    id > 0
                else {
                    throw CLIError.usage("query frame --id N | --at <iso-or-epoch> [--show-ocr]")
                }
                let f = try client.frame(id: id)
                printFrame(f, showOCR: rest.contains("--show-ocr"))
            }
        case "image":
            try image(rest, client: client)
        case "sample":
            let limit = try intFlag(rest, name: "--limit", allowed: 1...500) ?? 50
            let minSeg = try intFlag(rest, name: "--min-seg-len", allowed: 1...10_000) ?? 1
            for f in try client.sample(limit: limit, minSegLen: minSeg) {
                print("#\(f.id)\t\(f.timestampMs)\tseg=\(f.segmentID ?? -1)\t\(f.title ?? "")")
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

    static func printFTS(
        query: String,
        limit: Int,
        content: LibrarySearchContent,
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
            throw CLIError.message("query exceeds 4096 bytes")
        }
        let results = try client.fts(query: normalized, limit: limit, content: content)
        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: try enc.encode(results), encoding: .utf8)!)
        } else {
            for r in results {
                print("#\(r.frameID)\t\(r.timestampMs)\t\(r.bundleID ?? "-")\t\(r.snippet ?? r.title ?? "")")
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

    static func printFrame(_ f: FrameRow, showOCR: Bool) {
        print("id: \(f.id)")
        print("timestamp_ms: \(f.timestampMs)")
        print("title: \(f.title ?? "")")
        print("image_path: \(f.imagePath ?? "")")
        print("video_id: \(f.videoID.map(String.init) ?? "")")
        print("video_index: \(f.videoIndex.map(String.init) ?? "")")
        print("size: \(f.width ?? 0)x\(f.height ?? 0)")
        if showOCR {
            print("--- OCR ---")
            print(f.foreground ?? "")
        }
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
