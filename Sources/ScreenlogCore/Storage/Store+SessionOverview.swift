import Foundation
import SQLite3

extension Store {
    /// Names belong to the Library database, so its existing snapshot/restore path
    /// includes them. The start key matches pin identity and survives live growth.
    /// Passing nil or whitespace resets to the recorded app label.
    @discardableResult
    public func setSessionName(startMs: Int64, name: String?) throws -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.flatMap { $0.isEmpty ? nil : $0 }
        return try withSerializedMutation {
            let key = "session.name.\(startMs)"
            if let normalized {
                try setMeta(key: key, value: normalized)
            } else {
                let stmt = try db.prepare("DELETE FROM metadata WHERE key = ?")
                defer { sqlite3_finalize(stmt) }
                SQLiteBind.text(stmt, 1, key)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw SQLiteError.step("reset session name failed")
                }
            }
            return normalized
        }
    }

    /// Aggregates only the selected session's indexed timestamp range. One
    /// lowest-ID display represents each synchronized moment, matching Timeline.
    /// Connected captures meet at their midpoint; gaps at the ribbon's cadence
    /// threshold contribute no time, nor does time beyond the first/last capture.
    /// Only eight app/domain rows and six sampled moments leave SQLite.
    public func sessionOverview(
        session: SessionRow,
        expectedCaptureIntervalMs: Int64
    ) throws -> SessionOverview {
        let threshold = TimelineActivityPresentation.gapThreshold(
            expectedCaptureIntervalMs: expectedCaptureIntervalMs
        )
        let stmt = try db.prepare(
            """
            WITH moments AS (
                SELECT timestamp, MIN(id) AS frame_id
                FROM frame WHERE timestamp BETWEEN ? AND ?
                GROUP BY timestamp
            ), neighbors AS (
                SELECT *,
                    timestamp - LAG(timestamp) OVER (ORDER BY timestamp) AS before_ms,
                    LEAD(timestamp) OVER (ORDER BY timestamp) - timestamp AS after_ms
                FROM moments
            ), activity AS (
                SELECT n.timestamp,
                    COALESCE(a.bundle_id, '') AS bundle_id,
                    COALESCE(NULLIF(a.display_name, ''), NULLIF(a.bundle_id, ''), 'Unknown application') AS app_name,
                    d.normalized_domain AS domain,
                    (CASE WHEN before_ms < ? THEN before_ms - before_ms / 2 ELSE 0 END)
                    + (CASE WHEN after_ms < ? THEN after_ms / 2 ELSE 0 END) AS duration_ms
                FROM neighbors n
                JOIN frame f ON f.id = n.frame_id
                LEFT JOIN segment s ON s.id = f.segment
                LEFT JOIN application a ON a.id = s.application
                LEFT JOIN domain d ON d.id = s.domain
            ), apps AS (
                SELECT bundle_id AS identifier, MAX(app_name) AS label,
                    SUM(duration_ms) AS duration_ms, COUNT(*) AS moment_count
                FROM activity GROUP BY bundle_id
                ORDER BY duration_ms DESC, moment_count DESC, identifier LIMIT 8
            ), domains AS (
                SELECT domain AS identifier, domain AS label,
                    SUM(duration_ms) AS duration_ms, COUNT(*) AS moment_count
                FROM activity WHERE domain IS NOT NULL AND domain != '' GROUP BY domain
                ORDER BY duration_ms DESC, moment_count DESC, identifier LIMIT 8
            )
            SELECT 0 AS kind, '', '', COALESCE(SUM(duration_ms), 0), COUNT(*),
                COUNT(DISTINCT bundle_id), COUNT(DISTINCT NULLIF(domain, '')) FROM activity
            UNION ALL
            SELECT 1, identifier, label, duration_ms, moment_count, 0, 0 FROM apps
            UNION ALL
            SELECT 2, identifier, label, duration_ms, moment_count, 0, 0 FROM domains
            """
        )
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, session.startMs)
        SQLiteBind.int64(stmt, 2, session.endMs)
        SQLiteBind.int64(stmt, 3, threshold)
        SQLiteBind.int64(stmt, 4, threshold)
        var momentCount: Int64 = 0
        var coveredDurationMs: Int64 = 0
        var applicationCount = 0
        var domainCount = 0
        var applications: [SessionOverview.Activity] = []
        var domains: [SessionOverview.Activity] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            let kind = SQLiteColumn.int64(stmt, 0)
            if kind == 0 {
                coveredDurationMs = SQLiteColumn.int64(stmt, 3)
                momentCount = SQLiteColumn.int64(stmt, 4)
                applicationCount = Int(SQLiteColumn.int64(stmt, 5))
                domainCount = Int(SQLiteColumn.int64(stmt, 6))
            } else {
                let item = SessionOverview.Activity(
                    identifier: SQLiteColumn.text(stmt, 1) ?? "",
                    displayName: SQLiteColumn.text(stmt, 2) ?? "",
                    durationMs: SQLiteColumn.int64(stmt, 3),
                    momentCount: SQLiteColumn.int64(stmt, 4)
                )
                if kind == 1 { applications.append(item) } else { domains.append(item) }
            }
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw SQLiteError.step("session overview failed") }
        return SessionOverview(
            momentCount: momentCount,
            coveredDurationMs: coveredDurationMs,
            applicationCount: applicationCount,
            domainCount: domainCount,
            applications: applications,
            domains: domains,
            moments: try sessionRepresentativeMoments(session),
            gapThresholdMs: threshold
        )
    }

    private func sessionRepresentativeMoments(_ session: SessionRow) throws -> [SessionOverview.Moment] {
        // Six evenly spaced time anchors, including both bounds. Indexed seeks
        // select the next actual capture; DISTINCT collapses anchors in gaps.
        let stmt = try db.prepare(
            """
            WITH RECURSIVE samples(n) AS (
                VALUES(0) UNION ALL SELECT n + 1 FROM samples WHERE n < 5
            ), selected AS (
                SELECT DISTINCT (
                    SELECT id FROM frame
                    WHERE timestamp >= ? + CAST((? - ?) * (n / 5.0) AS INTEGER)
                      AND timestamp <= ?
                    ORDER BY timestamp, id LIMIT 1
                ) AS frame_id FROM samples
            )
            SELECT f.id, f.timestamp, f.title, a.bundle_id, a.display_name,
                d.normalized_domain, f.image_path,
                CASE WHEN v.status = 0 THEN f.video ELSE NULL END
            FROM selected
            JOIN frame f ON f.id = selected.frame_id
            LEFT JOIN segment s ON s.id = f.segment
            LEFT JOIN application a ON a.id = s.application
            LEFT JOIN domain d ON d.id = s.domain
            LEFT JOIN video v ON v.id = f.video
            ORDER BY f.timestamp, f.id
            """
        )
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, session.startMs)
        SQLiteBind.int64(stmt, 2, session.endMs)
        SQLiteBind.int64(stmt, 3, session.startMs)
        SQLiteBind.int64(stmt, 4, session.endMs)
        var moments: [SessionOverview.Moment] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            let bundleID = SQLiteColumn.text(stmt, 3)
            moments.append(
                SessionOverview.Moment(
                    id: SQLiteColumn.int64(stmt, 0),
                    timestampMs: SQLiteColumn.int64(stmt, 1),
                    title: SQLiteColumn.text(stmt, 2),
                    bundleID: bundleID,
                    appLabel: SQLiteColumn.text(stmt, 4) ?? bundleID ?? "Unknown application",
                    domain: SQLiteColumn.text(stmt, 5),
                    imagePath: SQLiteColumn.text(stmt, 6),
                    videoID: SQLiteColumn.int64Optional(stmt, 7)
                ))
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw SQLiteError.step("session moments failed") }
        return moments
    }
}
