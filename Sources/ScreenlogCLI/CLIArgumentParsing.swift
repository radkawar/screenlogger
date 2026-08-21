import Foundation
import ScreenlogCore

extension ScreenlogCLIMain {
    // MARK: - parsing

    struct Globals {
        var dataDir: String?
        var root: URL {
            if let dataDir { return URL(fileURLWithPath: dataDir, isDirectory: true) }
            return ScreenlogPaths.resolvedRoot()
        }
    }

    static func parseGlobals(_ args: [String]) throws -> (Globals, [String]) {
        var g = Globals()
        var rest: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "--data-dir" {
                guard g.dataDir == nil else {
                    throw CLIError.message("--data-dir may only be provided once")
                }
                guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else {
                    throw CLIError.usage("screenlog --data-dir PATH <command>")
                }
                let value = args[i + 1]
                guard !value.isEmpty, value.utf8.count <= 4_096 else {
                    throw CLIError.message("data directory path is empty or exceeds 4096 bytes")
                }
                g.dataDir = value
                i += 2
            } else {
                rest.append(args[i])
                i += 1
            }
        }
        return (g, rest)
    }

    static func intFlag(
        _ args: [String],
        name: String,
        allowed: ClosedRange<Int>
    ) throws -> Int? {
        guard let idx = args.firstIndex(of: name) else { return nil }
        guard args.lastIndex(of: name) == idx else {
            throw CLIError.message("\(name) may only be provided once")
        }
        guard idx + 1 < args.count, let value = Int(args[idx + 1]) else {
            throw CLIError.message("\(name) requires an integer value")
        }
        guard allowed.contains(value) else {
            throw CLIError.message("\(name) must be between \(allowed.lowerBound) and \(allowed.upperBound)")
        }
        return value
    }

    static func int64Flag(
        _ args: [String],
        name: String,
        allowed: ClosedRange<Int64>
    ) throws -> Int64? {
        guard let idx = args.firstIndex(of: name) else { return nil }
        guard args.lastIndex(of: name) == idx else {
            throw CLIError.message("\(name) may only be provided once")
        }
        guard idx + 1 < args.count, let value = Int64(args[idx + 1]) else {
            throw CLIError.message("\(name) requires an integer value")
        }
        guard allowed.contains(value) else {
            throw CLIError.message("\(name) is outside the supported range")
        }
        return value
    }

    static func stringFlag(
        _ args: [String],
        name: String,
        maximumBytes: Int = 4_096
    ) throws -> String? {
        guard let idx = args.firstIndex(of: name) else { return nil }
        guard args.lastIndex(of: name) == idx else {
            throw CLIError.message("\(name) may only be provided once")
        }
        guard idx + 1 < args.count, !args[idx + 1].hasPrefix("-") else {
            throw CLIError.message("\(name) requires a value")
        }
        let value = args[idx + 1]
        guard !value.isEmpty, value.utf8.count <= maximumBytes else {
            throw CLIError.message("\(name) is empty or exceeds \(maximumBytes) bytes")
        }
        return value
    }

    static func positionalArguments(_ args: [String], valueFlags: Set<String>) -> [String] {
        var values: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext {
                skipNext = false
                continue
            }
            if valueFlags.contains(arg) {
                skipNext = true
            } else if !arg.hasPrefix("-") {
                values.append(arg)
            }
        }
        return values
    }

    struct ActivityBounds: Equatable {
        var sinceMs: Int64?
        var beforeMs: Int64?

        var isBounded: Bool { sinceMs != nil || beforeMs != nil }
    }

    static func activityBounds(_ args: [String], now: Date = Date()) throws -> ActivityBounds {
        let since = try stringFlag(args, name: "--since").map {
            try parseActivityBound($0, now: now)
        }
        let before = try stringFlag(args, name: "--before").map {
            try parseActivityBound($0, now: now)
        }
        if let since, let before, since >= before {
            throw CLIError.message("--since must be earlier than --before")
        }
        return ActivityBounds(sinceMs: since, beforeMs: before)
    }

    /// Parse a timestamp or a duration before `now` such as `30d`, `12h`, or `45m`.
    static func parseActivityBound(_ raw: String, now: Date = Date()) throws -> Int64 {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "now" {
            return Int64(now.timeIntervalSince1970 * 1000)
        }
        if let unit = value.last, ["d", "h", "m", "w"].contains(unit),
            let amount = Double(value.dropLast()), amount.isFinite, amount >= 0
        {
            let secondsPerUnit: Double =
                switch unit {
                case "m": 60
                case "h": 60 * 60
                case "d": 24 * 60 * 60
                case "w": 7 * 24 * 60 * 60
                default: 1
                }
            let milliseconds = (now.timeIntervalSince1970 - amount * secondsPerUnit) * 1000
            guard milliseconds.isFinite,
                milliseconds >= Double(Int64.min),
                milliseconds <= Double(Int64.max)
            else {
                throw CLIError.message("activity bound is outside the supported date range")
            }
            return Int64(milliseconds)
        }
        return try parseTimestampMs(raw)
    }

    static func commaSeparatedIDs(_ raw: String, maximumCount: Int = 100) throws -> [Int64] {
        let values = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard !values.isEmpty, values.count <= maximumCount else {
            throw CLIError.message("--ids must contain between 1 and \(maximumCount) frame ids")
        }
        var seen: Set<Int64> = []
        var ids: [Int64] = []
        for value in values {
            guard let id = Int64(value.trimmingCharacters(in: .whitespaces)), id > 0 else {
                throw CLIError.message("--ids must contain positive comma-separated frame ids")
            }
            if seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    /// Parse ISO-8601, epoch seconds, or epoch milliseconds into ms since 1970.
    static func parseTimestampMs(_ raw: String) throws -> Int64 {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int64(trimmed) {
            // Heuristic: 10-digit / smaller to seconds; 13-digit to ms.
            if n > -100_000_000_000, n < 100_000_000_000 {  // < ~year 5138 in seconds
                return n * 1000
            }
            return n
        }
        // ISO8601 with/without fractional seconds
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: trimmed) {
            return Int64(d.timeIntervalSince1970 * 1000)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: trimmed) {
            return Int64(d.timeIntervalSince1970 * 1000)
        }
        // Common local-style without Z
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
        ] {
            df.dateFormat = format
            if let d = df.date(from: trimmed) {
                return Int64(d.timeIntervalSince1970 * 1000)
            }
        }
        throw CLIError.message("invalid timestamp: \(raw) (use ISO-8601 or epoch seconds/ms)")
    }
}

enum CLIError: Error, CustomStringConvertible {
    case unknown(String)
    case usage(String)
    case message(String)
    var description: String {
        switch self {
        case .unknown(let c): return "unknown command: \(c)"
        case .usage(let u): return "usage: \(u)"
        case .message(let m): return m
        }
    }

    /// Shell-friendly convention: malformed invocation is 2; runtime/verification failure is 1.
    var exitCode: Int32 {
        switch self {
        case .unknown, .usage: return 2
        case .message: return 1
        }
    }
}
