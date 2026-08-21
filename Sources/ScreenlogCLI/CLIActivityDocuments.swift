import Foundation
import ScreenlogCore

struct CLIActivityRangeDocument: Encodable, Equatable {
    let requestedSinceMs: Int64?
    let requestedBeforeMs: Int64?
    let firstRecordedMs: Int64?
    let lastRecordedMs: Int64?
    let activeDays: Int
    let sessionCount: Int
    let sessionBreakCount: Int

    init(
        bounds: ScreenlogCLIMain.ActivityBounds,
        stats: RecordingStats,
        sessions: [SessionRow],
        calendar: Calendar = .current
    ) {
        requestedSinceMs = bounds.sinceMs
        requestedBeforeMs = bounds.beforeMs
        firstRecordedMs = stats.minTimestampMs
        lastRecordedMs = stats.maxTimestampMs
        let days = sessions.reduce(into: Set<Date>()) { result, session in
            var day = calendar.startOfDay(
                for: Date(timeIntervalSince1970: TimeInterval(session.startMs) / 1000)
            )
            let endDay = calendar.startOfDay(
                for: Date(timeIntervalSince1970: TimeInterval(session.endMs) / 1000)
            )
            while day <= endDay {
                result.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else {
                    break
                }
                day = next
            }
        }
        activeDays = days.count
        sessionCount = sessions.count
        sessionBreakCount = max(0, sessions.count - 1)
    }
}

struct CLIUsageTimeDocument: Encodable, Equatable {
    let schemaVersion = 1
    let range: CLIActivityRangeDocument
    let physicalFrameCount: Int64
    let momentCount: Int64
    let captureSpanSeconds: Int64
    let unfinalizedMomentCount: Int64
}

struct CLIUsageItemDocument: Encodable, Equatable {
    let identifier: String
    let displayName: String?
    let momentCount: Int64
    let shareOfRecordedMoments: Double

    init(item: UsageTopItem, totalMoments: Int64) {
        identifier = item.identifier
        displayName = item.displayName
        momentCount = item.frameCount
        shareOfRecordedMoments =
            totalMoments > 0
            ? Double(item.frameCount) / Double(totalMoments)
            : 0
    }
}

struct CLIUsageTopDocument: Encodable, Equatable {
    let schemaVersion = 1
    let range: CLIActivityRangeDocument
    let items: [CLIUsageItemDocument]
    let simultaneousDisplaysMayOverlap = true
}

struct CLISessionDocument: Encodable, Equatable {
    let startMs: Int64
    let endMs: Int64
    let start: String
    let end: String
    let durationSeconds: Int64
    let momentCount: Int64
    let startingBundleID: String?
    let startingDisplayName: String?

    init(_ session: SessionRow) {
        startMs = session.startMs
        endMs = session.endMs
        start = CLIOutputFormat.localISO(session.startMs)
        end = CLIOutputFormat.localISO(session.endMs)
        durationSeconds = session.durationMs / 1000
        momentCount = session.frameCount
        startingBundleID = session.primaryBundleID
        startingDisplayName = session.primaryDisplayName
    }
}

struct CLIFrameDocument: Encodable, Equatable {
    let id: Int64
    let timestampMs: Int64
    let timestamp: String
    let title: String?
    let bundleID: String?
    let displayName: String?
    let domain: String?
    let segmentID: Int64?
    let width: Int?
    let height: Int?
    let ocr: String?
    let ocrTruncated: Bool

    init(frame: FrameRow, maximumOCRCharacters: Int = 0) {
        id = frame.id
        timestampMs = frame.timestampMs
        timestamp = CLIOutputFormat.localISO(frame.timestampMs)
        title = frame.title
        bundleID = frame.bundleID
        displayName = frame.displayName
        domain = frame.domain
        segmentID = frame.segmentID
        width = frame.width
        height = frame.height
        let source = frame.foreground ?? ""
        if maximumOCRCharacters > 0, !source.isEmpty {
            let prefix = String(source.prefix(maximumOCRCharacters))
            ocr = prefix
            ocrTruncated = prefix.count < source.count
        } else {
            ocr = nil
            ocrTruncated = false
        }
    }
}

struct CLIFramePageDocument: Encodable, Equatable {
    let schemaVersion = 1
    let frames: [CLIFrameDocument]
    let nextCursorMs: Int64?
}

/// A privacy-safe search result for assistant output. Storage paths and media
/// implementation details intentionally remain inside Screenlogger.
struct CLISearchResultDocument: Encodable, Equatable {
    let frameID: Int64
    let timestampMs: Int64
    let timestamp: String
    let title: String?
    let bundleID: String?
    let displayName: String?
    let domain: String?
    let snippet: String?
    let transcriptSource: TranscriptSource?
    let transcriptStartTimestampMs: Int64?
    let transcriptEndTimestampMs: Int64?

    init(_ result: FTSResult) {
        frameID = result.frameID
        timestampMs = result.timestampMs
        timestamp = CLIOutputFormat.localISO(result.timestampMs)
        title = result.title
        bundleID = result.bundleID
        displayName = result.displayName
        domain = result.domain
        snippet = result.snippet
        transcriptSource = result.transcriptSource
        transcriptStartTimestampMs = result.transcriptStartTimestampMs
        transcriptEndTimestampMs = result.transcriptEndTimestampMs
    }
}

struct CLIDigestDocument: Encodable, Equatable {
    let schemaVersion = 1
    let range: CLIActivityRangeDocument
    let momentCount: Int64
    let captureSpanSeconds: Int64
    let topApplications: [CLIUsageItemDocument]
    let topDomains: [CLIUsageItemDocument]
    let sessions: [CLISessionDocument]
    let representativeFrames: [CLIFrameDocument]
    let interpretationNotes: [String]
}

enum CLIOutputFormat {
    static func localISO(_ timestampMs: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)
        )
    }

    static func duration(seconds: Int64) -> String {
        let seconds = max(0, seconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(remainder)s" }
        return "\(remainder)s"
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
