import Foundation
import SQLite3

extension Store {
    // MARK: - Usage

    public func stats(
        fromTimestampMs: Int64? = nil,
        toTimestampMs: Int64? = nil
    ) throws -> RecordingStats {
        var sql =
            """
            SELECT
                COUNT(*),
                MIN(timestamp),
                MAX(timestamp),
                SUM(CASE WHEN image_path IS NOT NULL THEN 1 ELSE 0 END),
                COUNT(DISTINCT timestamp),
                COUNT(DISTINCT CASE WHEN image_path IS NOT NULL THEN timestamp END)
            FROM frame
            """
        var constraints: [String] = []
        if fromTimestampMs != nil { constraints.append("timestamp >= ?") }
        if toTimestampMs != nil { constraints.append("timestamp < ?") }
        if !constraints.isEmpty {
            sql += " WHERE " + constraints.joined(separator: " AND ")
        }
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var bind: Int32 = 1
        if let fromTimestampMs {
            SQLiteBind.int64(stmt, bind, fromTimestampMs)
            bind += 1
        }
        if let toTimestampMs {
            SQLiteBind.int64(stmt, bind, toTimestampMs)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return RecordingStats(totalFrames: 0, minTimestampMs: nil, maxTimestampMs: nil, unfinalizedFrames: 0)
        }
        return RecordingStats(
            totalFrames: SQLiteColumn.int64(stmt, 0),
            minTimestampMs: SQLiteColumn.int64Optional(stmt, 1),
            maxTimestampMs: SQLiteColumn.int64Optional(stmt, 2),
            unfinalizedFrames: SQLiteColumn.int64(stmt, 3),
            totalMoments: SQLiteColumn.int64(stmt, 4),
            unfinalizedMoments: SQLiteColumn.int64(stmt, 5)
        )
    }

    public func topApplications(
        limit: Int = 20,
        fromTimestampMs: Int64? = nil,
        toTimestampMs: Int64? = nil
    ) throws -> [UsageTopItem] {
        var sql = """
            SELECT a.bundle_id, a.display_name, COUNT(DISTINCT f.timestamp) AS fc
            FROM frame f
            JOIN segment s ON s.id = f.segment
            JOIN application a ON a.id = s.application
            WHERE 1 = 1
            """
        if fromTimestampMs != nil { sql += " AND f.timestamp >= ?" }
        if toTimestampMs != nil { sql += " AND f.timestamp < ?" }
        sql += """

            GROUP BY a.bundle_id, a.display_name
            ORDER BY fc DESC
            LIMIT ?
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var bind: Int32 = 1
        if let fromTimestampMs {
            SQLiteBind.int64(stmt, bind, fromTimestampMs)
            bind += 1
        }
        if let toTimestampMs {
            SQLiteBind.int64(stmt, bind, toTimestampMs)
            bind += 1
        }
        SQLiteBind.int(stmt, bind, limit)
        var items: [UsageTopItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(
                UsageTopItem(
                    identifier: SQLiteColumn.text(stmt, 0) ?? "",
                    displayName: SQLiteColumn.text(stmt, 1),
                    frameCount: SQLiteColumn.int64(stmt, 2)
                )
            )
        }
        return items
    }

    public func topDomains(
        limit: Int = 20,
        fromTimestampMs: Int64? = nil,
        toTimestampMs: Int64? = nil
    ) throws -> [UsageTopItem] {
        var sql = """
            SELECT d.normalized_domain, d.common_name, COUNT(DISTINCT f.timestamp) AS fc
            FROM frame f
            JOIN segment s ON s.id = f.segment
            JOIN domain d ON d.id = s.domain
            WHERE 1 = 1
            """
        if fromTimestampMs != nil { sql += " AND f.timestamp >= ?" }
        if toTimestampMs != nil { sql += " AND f.timestamp < ?" }
        sql += """

            GROUP BY d.id, d.normalized_domain, d.common_name
            ORDER BY fc DESC
            LIMIT ?
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var bind: Int32 = 1
        if let fromTimestampMs {
            SQLiteBind.int64(stmt, bind, fromTimestampMs)
            bind += 1
        }
        if let toTimestampMs {
            SQLiteBind.int64(stmt, bind, toTimestampMs)
            bind += 1
        }
        SQLiteBind.int(stmt, bind, limit)
        var items: [UsageTopItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(
                UsageTopItem(
                    identifier: SQLiteColumn.text(stmt, 0) ?? "",
                    displayName: SQLiteColumn.text(stmt, 1),
                    frameCount: SQLiteColumn.int64(stmt, 2)
                )
            )
        }
        return items
    }

    /// Sessions = contiguous recording blocks split when gap >= gapMs.
    /// Enriched with primary app (first frame join) and optional still preview path.
    public func sessions(
        gapMs: Int64 = 5 * 60 * 1000,
        fromTimestampMs: Int64? = nil,
        toTimestampMs: Int64? = nil
    ) throws -> [SessionRow] {
        var momentConstraints: [String] = []
        if fromTimestampMs != nil { momentConstraints.append("timestamp >= ?") }
        if toTimestampMs != nil { momentConstraints.append("timestamp < ?") }
        let momentWhere =
            momentConstraints.isEmpty
            ? ""
            : " WHERE " + momentConstraints.joined(separator: " AND ")
        let sql = """
            WITH moments AS (
                SELECT DISTINCT timestamp
                FROM frame\(momentWhere)
            ),
            ordered AS (
                SELECT
                    timestamp,
                    timestamp - LAG(timestamp) OVER (ORDER BY timestamp) AS delta_ms
                FROM moments
            ),
            breaks AS (
                SELECT
                    timestamp,
                    SUM(CASE WHEN delta_ms IS NULL OR delta_ms >= ? THEN 1 ELSE 0 END)
                        OVER (ORDER BY timestamp) AS session_id
                FROM ordered
            ),
            session_bounds AS (
                SELECT
                    MIN(timestamp) AS start_ms,
                    MAX(timestamp) AS end_ms,
                    COUNT(*) AS frame_count
                FROM breaks
                GROUP BY session_id
            )
            SELECT
                sb.start_ms,
                sb.end_ms,
                sb.frame_count,
                (
                    SELECT a.bundle_id
                    FROM frame f
                    LEFT JOIN segment s ON s.id = f.segment
                    LEFT JOIN application a ON a.id = s.application
                    WHERE f.timestamp = sb.start_ms
                    ORDER BY f.id ASC
                    LIMIT 1
                ),
                (
                    SELECT a.display_name
                    FROM frame f
                    LEFT JOIN segment s ON s.id = f.segment
                    LEFT JOIN application a ON a.id = s.application
                    WHERE f.timestamp = sb.start_ms
                    ORDER BY f.id ASC
                    LIMIT 1
                ),
                (
                    SELECT f.image_path
                    FROM frame f
                    WHERE f.timestamp BETWEEN sb.start_ms AND sb.end_ms
                      AND f.image_path IS NOT NULL
                      AND length(f.image_path) > 0
                    ORDER BY f.timestamp ASC
                    LIMIT 1
                )
            FROM session_bounds sb
            ORDER BY sb.start_ms DESC
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var bind: Int32 = 1
        if let fromTimestampMs {
            SQLiteBind.int64(stmt, bind, fromTimestampMs)
            bind += 1
        }
        if let toTimestampMs {
            SQLiteBind.int64(stmt, bind, toTimestampMs)
            bind += 1
        }
        SQLiteBind.int64(stmt, bind, gapMs)
        var rows: [SessionRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(
                SessionRow(
                    startMs: SQLiteColumn.int64(stmt, 0),
                    endMs: SQLiteColumn.int64(stmt, 1),
                    frameCount: SQLiteColumn.int64(stmt, 2),
                    primaryBundleID: SQLiteColumn.text(stmt, 3),
                    primaryDisplayName: SQLiteColumn.text(stmt, 4),
                    previewImagePath: SQLiteColumn.text(stmt, 5)
                )
            )
        }
        return rows
    }

}
