import Foundation
import SQLite3

extension Store {
    // Shared SELECT for TimelineFrame rows (includes FG + BG OCR for Replay panel).
    private static let timelineSelectSQL = """
        f.id,
        f.timestamp,
        f.image_path,
        f.title,
        f.foreground,
        f.background,
        a.bundle_id,
        a.display_name,
        d.normalized_domain,
        s.url,
        CASE WHEN v.status = 0 THEN f.video ELSE NULL END,
        f.video_index,
        f.segment,
        f.width,
        f.height,
        f.capture_display_x,
        f.capture_display_y,
        f.capture_display_width,
        f.capture_display_height
        """

    private static let timelineJoinSQL = """
        FROM frame f
        LEFT JOIN segment s ON s.id = f.segment
        LEFT JOIN application a ON a.id = s.application
        LEFT JOIN domain d ON d.id = s.domain
        LEFT JOIN video v ON v.id = f.video
        """

    private static func timelineFrame(from stmt: OpaquePointer) -> TimelineFrame {
        let captureDisplay: CaptureDisplayRect? = {
            guard let x = SQLiteColumn.doubleOptional(stmt, 15),
                let y = SQLiteColumn.doubleOptional(stmt, 16),
                let width = SQLiteColumn.doubleOptional(stmt, 17),
                let height = SQLiteColumn.doubleOptional(stmt, 18)
            else { return nil }
            return CaptureDisplayRect(x: x, y: y, width: width, height: height)
        }()
        return TimelineFrame(
            id: SQLiteColumn.int64(stmt, 0),
            timestampMs: SQLiteColumn.int64(stmt, 1),
            imagePath: SQLiteColumn.text(stmt, 2),
            width: SQLiteColumn.intOptional(stmt, 13),
            height: SQLiteColumn.intOptional(stmt, 14),
            title: SQLiteColumn.text(stmt, 3),
            foreground: SQLiteColumn.text(stmt, 4),
            background: SQLiteColumn.text(stmt, 5),
            bundleID: SQLiteColumn.text(stmt, 6),
            displayName: SQLiteColumn.text(stmt, 7),
            domain: SQLiteColumn.text(stmt, 8),
            url: SQLiteColumn.text(stmt, 9),
            segmentID: SQLiteColumn.int64Optional(stmt, 12),
            videoID: SQLiteColumn.int64Optional(stmt, 10),
            videoIndex: SQLiteColumn.intOptional(stmt, 11),
            captureDisplay: captureDisplay
        )
    }

    private func attachingTranscripts(to rows: [TimelineFrame]) throws -> [TimelineFrame] {
        let grouped = try transcriptsByMoment(timestamps: rows.map(\.timestampMs))
        return rows.map { row in
            var hydrated = row
            hydrated.transcriptSegments = grouped[row.timestampMs] ?? []
            return hydrated
        }
    }

    /// Recent frames joined with app / domain / url for Timeline UI.
    public func recentTimeline(limit: Int = 80) throws -> [TimelineFrame] {
        let sql = """
            SELECT \(Self.timelineSelectSQL)
            \(Self.timelineJoinSQL)
            WHERE f.timestamp IN (
                SELECT timestamp
                FROM frame
                GROUP BY timestamp
                ORDER BY timestamp DESC
                LIMIT ?
            )
            ORDER BY f.timestamp DESC, f.id DESC
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int(stmt, 1, limit)
        var rows: [TimelineFrame] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Self.timelineFrame(from: stmt))
        }
        return try attachingTranscripts(to: rows)
    }

    /// Chronological window of frames around a center id (for search to replay).
    public func timelineAround(frameID: Int64, before: Int = 40, after: Int = 40) throws -> [TimelineFrame] {
        guard let center = try frame(id: frameID) else { return [] }
        let sql = """
            WITH before_moments AS (
                SELECT DISTINCT timestamp
                FROM frame
                WHERE timestamp < ?
                ORDER BY timestamp DESC
                LIMIT ?
            ), after_moments AS (
                SELECT DISTINCT timestamp
                FROM frame
                WHERE timestamp > ?
                ORDER BY timestamp ASC
                LIMIT ?
            ), selected_moments AS (
                SELECT timestamp FROM before_moments
                UNION
                SELECT ?
                UNION
                SELECT timestamp FROM after_moments
            )
            SELECT \(Self.timelineSelectSQL)
            \(Self.timelineJoinSQL)
            WHERE f.timestamp IN (SELECT timestamp FROM selected_moments)
            ORDER BY f.timestamp ASC, f.id ASC
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, center.timestampMs)
        SQLiteBind.int(stmt, 2, max(0, before))
        SQLiteBind.int64(stmt, 3, center.timestampMs)
        SQLiteBind.int(stmt, 4, max(0, after))
        SQLiteBind.int64(stmt, 5, center.timestampMs)
        var rows: [TimelineFrame] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Self.timelineFrame(from: stmt))
        }
        return try attachingTranscripts(to: rows)
    }

    public func timelineNear(timestampMs: Int64, limit: Int = 80) throws -> [TimelineFrame] {
        let boundedLimit = max(1, limit)
        let sql = """
            WITH earlier_candidates AS (
                SELECT DISTINCT timestamp
                FROM frame
                WHERE timestamp <= ?
                ORDER BY timestamp DESC
                LIMIT ?
            ), later_candidates AS (
                SELECT DISTINCT timestamp
                FROM frame
                WHERE timestamp > ?
                ORDER BY timestamp ASC
                LIMIT ?
            ), candidates AS (
                SELECT timestamp FROM earlier_candidates
                UNION
                SELECT timestamp FROM later_candidates
            ), nearest_moments AS (
                SELECT timestamp
                FROM candidates
                ORDER BY ABS(timestamp - ?) ASC
                LIMIT ?
            )
            SELECT \(Self.timelineSelectSQL)
            \(Self.timelineJoinSQL)
            WHERE f.timestamp IN (SELECT timestamp FROM nearest_moments)
            ORDER BY f.timestamp ASC, f.id ASC
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, timestampMs)
        SQLiteBind.int(stmt, 2, boundedLimit)
        SQLiteBind.int64(stmt, 3, timestampMs)
        SQLiteBind.int(stmt, 4, boundedLimit)
        SQLiteBind.int64(stmt, 5, timestampMs)
        SQLiteBind.int(stmt, 6, boundedLimit)
        var rows: [TimelineFrame] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Self.timelineFrame(from: stmt))
        }
        return try attachingTranscripts(to: rows)
    }

    /// Inclusive time-range timeline (`idx_frame_timestamp`) for session browse / scrub windows.
    public func timeline(
        fromTimestampMs startMs: Int64,
        toTimestampMs endMs: Int64,
        limit: Int = 500
    ) throws -> [TimelineFrame] {
        let sql = """
            SELECT \(Self.timelineSelectSQL)
            \(Self.timelineJoinSQL)
            WHERE f.timestamp IN (
                SELECT timestamp
                FROM frame
                WHERE timestamp >= ? AND timestamp <= ?
                GROUP BY timestamp
                ORDER BY timestamp ASC
                LIMIT ?
            )
            ORDER BY f.timestamp ASC, f.id ASC
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, startMs)
        SQLiteBind.int64(stmt, 2, endMs)
        SQLiteBind.int(stmt, 3, limit)
        var rows: [TimelineFrame] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Self.timelineFrame(from: stmt))
        }
        return try attachingTranscripts(to: rows)
    }

    /// Timeline frames for a contiguous recording block from `sessions(gapMs:)`.
    public func timeline(session: SessionRow, limit: Int = 500) throws -> [TimelineFrame] {
        try timeline(fromTimestampMs: session.startMs, toTimestampMs: session.endMs, limit: limit)
    }

    /// Expand a time window around `centerMs` by `radiusMs` on each side (more context than id-window).
    /// Useful when jumping from Search to Replay and needing surrounding minutes of activity.
    public func timelineExpand(
        aroundTimestampMs centerMs: Int64,
        radiusMs: Int64 = 60_000,
        limit: Int = 200
    ) throws -> [TimelineFrame] {
        let radius = max(0, radiusMs)
        let start = centerMs &- radius  // wrapping subtract avoids crash on underflow
        let end = centerMs &+ radius
        // If center is near 0, clamp start to 0.
        let lo = start > centerMs ? 0 : start
        return try timeline(fromTimestampMs: lo, toTimestampMs: end, limit: limit)
    }

}
