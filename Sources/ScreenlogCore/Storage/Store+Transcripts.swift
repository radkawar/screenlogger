import Foundation
import SQLite3

extension Store {
    /// Persist a finalized transcript against the closest captured moment.
    /// Returns nil when there is no nearby moment, preventing speech captured
    /// during a paused or excluded period from leaking into later activity.
    @discardableResult
    public func storeTranscript(
        _ draft: TranscriptSegmentDraft,
        maximumMomentDistanceMs: Int64 = 10_000
    ) throws -> TranscriptSegment? {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, draft.endTimestampMs >= draft.startTimestampMs else { return nil }

        let midpoint = draft.startTimestampMs + ((draft.endTimestampMs - draft.startTimestampMs) / 2)
        return try withSerializedMutation {
            guard let frame = try frameNearest(timestampMs: midpoint),
                abs(frame.timestampMs - midpoint) <= max(0, maximumMomentDistanceMs)
            else { return nil }

            let sql = """
                INSERT INTO transcript_segment(
                    frame_id, start_timestamp, end_timestamp, source, text,
                    locale_identifier, confidence
                ) VALUES(?, ?, ?, ?, ?, ?, ?)
                """
            let stmt = try db.prepare(sql)
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.int64(stmt, 1, frame.id)
            SQLiteBind.int64(stmt, 2, draft.startTimestampMs)
            SQLiteBind.int64(stmt, 3, draft.endTimestampMs)
            SQLiteBind.text(stmt, 4, draft.source.rawValue)
            SQLiteBind.text(stmt, 5, text)
            if let localeIdentifier = draft.localeIdentifier {
                SQLiteBind.text(stmt, 6, localeIdentifier)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            if let confidence = draft.confidence {
                sqlite3_bind_double(stmt, 7, min(1, max(0, confidence)))
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw SQLiteError.step("insert transcript segment failed")
            }
            return TranscriptSegment(
                id: db.lastInsertRowID(),
                frameID: frame.id,
                startTimestampMs: draft.startTimestampMs,
                endTimestampMs: draft.endTimestampMs,
                source: draft.source,
                text: text,
                localeIdentifier: draft.localeIdentifier,
                confidence: draft.confidence.map { min(1, max(0, $0)) }
            )
        }
    }

    public func transcripts(frameID: Int64) throws -> [TranscriptSegment] {
        try transcriptSegments(whereSQL: "ts.frame_id = ?") { stmt in
            SQLiteBind.int64(stmt, 1, frameID)
        }
    }

    /// Transcript rows grouped by capture timestamp so every display in a
    /// synchronized multi-display moment presents the same captions.
    func transcriptsByMoment(
        timestamps: [Int64]
    ) throws -> [Int64: [TranscriptSegment]] {
        let unique = Array(Set(timestamps))
        guard !unique.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: unique.count).joined(separator: ",")
        let sql = """
            SELECT
                f.timestamp,
                ts.id, ts.frame_id, ts.start_timestamp, ts.end_timestamp,
                ts.source, ts.text, ts.locale_identifier, ts.confidence
            FROM transcript_segment ts
            JOIN frame f ON f.id = ts.frame_id
            WHERE f.timestamp IN (\(placeholders))
            ORDER BY f.timestamp ASC, ts.start_timestamp ASC, ts.id ASC
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (offset, timestamp) in unique.enumerated() {
            SQLiteBind.int64(stmt, Int32(offset + 1), timestamp)
        }
        var grouped: [Int64: [TranscriptSegment]] = [:]
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            let timestamp = SQLiteColumn.int64(stmt, 0)
            if let segment = Self.transcriptSegment(from: stmt, offset: 1) {
                grouped[timestamp, default: []].append(segment)
            }
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else {
            throw SQLiteError.step("transcript timeline query failed")
        }
        return grouped
    }

    private func transcriptSegments(
        whereSQL: String,
        bind: (OpaquePointer) -> Void
    ) throws -> [TranscriptSegment] {
        let sql = """
            SELECT id, frame_id, start_timestamp, end_timestamp, source, text,
                   locale_identifier, confidence
            FROM transcript_segment ts
            WHERE \(whereSQL)
            ORDER BY start_timestamp ASC, id ASC
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var rows: [TranscriptSegment] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            if let row = Self.transcriptSegment(from: stmt) { rows.append(row) }
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else {
            throw SQLiteError.step("transcript query failed")
        }
        return rows
    }

    static func transcriptSegment(
        from stmt: OpaquePointer,
        offset: Int32 = 0
    ) -> TranscriptSegment? {
        guard let sourceValue = SQLiteColumn.text(stmt, offset + 4),
            let source = TranscriptSource(rawValue: sourceValue),
            let text = SQLiteColumn.text(stmt, offset + 5)
        else { return nil }
        return TranscriptSegment(
            id: SQLiteColumn.int64(stmt, offset),
            frameID: SQLiteColumn.int64(stmt, offset + 1),
            startTimestampMs: SQLiteColumn.int64(stmt, offset + 2),
            endTimestampMs: SQLiteColumn.int64(stmt, offset + 3),
            source: source,
            text: text,
            localeIdentifier: SQLiteColumn.text(stmt, offset + 6),
            confidence: SQLiteColumn.doubleOptional(stmt, offset + 7)
        )
    }
}
