import Foundation
import SQLite3

extension Store {
    // MARK: - Frame and video queries

    public func frame(id: Int64) throws -> FrameRow? {
        let sql = """
            SELECT id, timestamp, image_path, width, height, foreground, background, title,
                   segment, video, video_index, is_inactive, ax_root_hash,
                   capture_display_x, capture_display_y, capture_display_width, capture_display_height
            FROM frame WHERE id = ? LIMIT 1
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Self.frameRow(from: stmt)
    }

    /// Resolve the media that can currently produce a preview for one frame.
    /// Inactive/purged video rows are intentionally treated as unavailable.
    public func framePreviewDescriptor(id: Int64) throws -> FramePreviewDescriptor? {
        let sql = """
            SELECT
                f.id,
                f.timestamp,
                f.image_path,
                CASE WHEN v.status = 0 THEN v.path ELSE NULL END,
                CASE WHEN v.status = 0 THEN f.video_index ELSE NULL END
            FROM frame f
            LEFT JOIN video v ON v.id = f.video
            WHERE f.id = ?
            LIMIT 1
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let source: FramePreviewSource
        if let stillPath = SQLiteColumn.text(stmt, 2), !stillPath.isEmpty {
            source = .still(path: stillPath)
        } else if let videoPath = SQLiteColumn.text(stmt, 3),
            let videoIndex = SQLiteColumn.intOptional(stmt, 4)
        {
            source = .video(path: videoPath, index: videoIndex)
        } else {
            source = .unavailable
        }
        return FramePreviewDescriptor(
            frameID: SQLiteColumn.int64(stmt, 0),
            timestampMs: SQLiteColumn.int64(stmt, 1),
            source: source
        )
    }

    /// Frame whose `timestamp` is closest to `timestampMs` (ties to lower id).
    public func frameNearest(timestampMs: Int64) throws -> FrameRow? {
        func candidate(comparison: String, ordering: String) throws -> FrameRow? {
            let sql = """
                SELECT id, timestamp, image_path, width, height, foreground, background, title,
                       segment, video, video_index, is_inactive, ax_root_hash,
                       capture_display_x, capture_display_y, capture_display_width, capture_display_height
                FROM frame
                WHERE timestamp \(comparison) ?
                ORDER BY timestamp \(ordering), id ASC
                LIMIT 1
                """
            let stmt = try db.prepare(sql)
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.int64(stmt, 1, timestampMs)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Self.frameRow(from: stmt)
        }

        let before = try candidate(comparison: "<=", ordering: "DESC")
        let after = try candidate(comparison: ">=", ordering: "ASC")
        guard let before else { return after }
        guard let after else { return before }

        // Bias signed values into monotonically ordered UInt64 space so even
        // extreme test inputs cannot overflow while computing a distance.
        let signBit = UInt64(1) << 63
        let target = UInt64(bitPattern: timestampMs) ^ signBit
        let beforeValue = UInt64(bitPattern: before.timestampMs) ^ signBit
        let afterValue = UInt64(bitPattern: after.timestampMs) ^ signBit
        let beforeDistance = target - beforeValue
        let afterDistance = afterValue - target
        if beforeDistance != afterDistance {
            return beforeDistance < afterDistance ? before : after
        }
        return before.id <= after.id ? before : after
    }

    /// Latest frame at or before `timestampMs`, if any.
    public func frameAtOrBefore(timestampMs: Int64) throws -> FrameRow? {
        let sql = """
            SELECT id, timestamp, image_path, width, height, foreground, background, title,
                   segment, video, video_index, is_inactive, ax_root_hash,
                   capture_display_x, capture_display_y, capture_display_width, capture_display_height
            FROM frame
            WHERE timestamp <= ?
            ORDER BY timestamp DESC, id DESC
            LIMIT 1
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, timestampMs)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Self.frameRow(from: stmt)
    }

    public func recentFrames(limit: Int = 50) throws -> [FrameRow] {
        let sql = """
            SELECT id, timestamp, image_path, width, height, foreground, background, title,
                   segment, video, video_index, is_inactive, ax_root_hash,
                   capture_display_x, capture_display_y, capture_display_width, capture_display_height
            FROM frame
            ORDER BY id DESC
            LIMIT ?
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int(stmt, 1, limit)
        var rows: [FrameRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Self.frameRow(from: stmt))
        }
        return rows
    }

    /// Indexed frame time-range scan (`idx_frame_timestamp`).
    /// Inclusive lower bound, exclusive upper bound: `[startMs, endMs)`.
    public func frames(
        fromTimestampMs startMs: Int64,
        toTimestampMs endMs: Int64,
        limit: Int = 500
    ) throws -> [FrameRow] {
        let sql = """
            SELECT id, timestamp, image_path, width, height, foreground, background, title,
                   segment, video, video_index, is_inactive, ax_root_hash,
                   capture_display_x, capture_display_y, capture_display_width, capture_display_height
            FROM frame
            WHERE timestamp >= ? AND timestamp < ?
            ORDER BY timestamp ASC
            LIMIT ?
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, startMs)
        SQLiteBind.int64(stmt, 2, endMs)
        SQLiteBind.int(stmt, 3, limit)
        var rows: [FrameRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Self.frameRow(from: stmt))
        }
        return rows
    }

    /// Frames for an application via segment join (`idx_segment_application` + `idx_frame_segment`).
    public func frames(
        bundleID: String,
        fromTimestampMs startMs: Int64? = nil,
        toTimestampMs endMs: Int64? = nil,
        limit: Int = 500
    ) throws -> [FrameRow] {
        var sql = """
            SELECT f.id, f.timestamp, f.image_path, f.width, f.height, f.foreground, f.background, f.title,
                   f.segment, f.video, f.video_index, f.is_inactive, f.ax_root_hash,
                   f.capture_display_x, f.capture_display_y, f.capture_display_width, f.capture_display_height
            FROM frame f
            JOIN segment s ON s.id = f.segment
            JOIN application a ON a.id = s.application
            WHERE a.bundle_id = ?
            """
        if startMs != nil {
            sql += " AND f.timestamp >= ?"
        }
        if endMs != nil {
            sql += " AND f.timestamp < ?"
        }
        sql += " ORDER BY f.timestamp ASC LIMIT ?"

        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var bind: Int32 = 1
        SQLiteBind.text(stmt, bind, bundleID)
        bind += 1
        if let startMs {
            SQLiteBind.int64(stmt, bind, startMs)
            bind += 1
        }
        if let endMs {
            SQLiteBind.int64(stmt, bind, endMs)
            bind += 1
        }
        SQLiteBind.int(stmt, bind, limit)
        var rows: [FrameRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Self.frameRow(from: stmt))
        }
        return rows
    }

    public func windowBounds(frameID: Int64) throws -> [(
        applicationID: Int64, windowTitle: String?, x: Int, y: Int, width: Int, height: Int, zOrder: Int, url: String?
    )] {
        let stmt = try db.prepare(
            """
            SELECT application, window_title, x, y, width, height, z_order, url
            FROM window_bound
            WHERE frame = ?
            ORDER BY z_order ASC, id ASC
            """
        )
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, frameID)
        var rows: [(applicationID: Int64, windowTitle: String?, x: Int, y: Int, width: Int, height: Int, zOrder: Int, url: String?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(
                (
                    applicationID: SQLiteColumn.int64(stmt, 0),
                    windowTitle: SQLiteColumn.text(stmt, 1),
                    x: Int(SQLiteColumn.int64(stmt, 2)),
                    y: Int(SQLiteColumn.int64(stmt, 3)),
                    width: Int(SQLiteColumn.int64(stmt, 4)),
                    height: Int(SQLiteColumn.int64(stmt, 5)),
                    zOrder: Int(SQLiteColumn.int64(stmt, 6)),
                    url: SQLiteColumn.text(stmt, 7)
                )
            )
        }
        return rows
    }

    /// Insert a video row for compaction and retention tests.
    @discardableResult
    public func insertVideo(
        path: String,
        width: Int = 1920,
        height: Int = 1080,
        numFrames: Int = 0,
        sizeBytes: Int64 = 0,
        status: Int = 0
    ) throws -> Int64 {
        try withSerializedMutation {
            let stmt = try db.prepare(
                """
                INSERT INTO video(height, width, path, num_frames, size_bytes, status)
                VALUES(?, ?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.int(stmt, 1, height)
            SQLiteBind.int(stmt, 2, width)
            SQLiteBind.text(stmt, 3, path)
            SQLiteBind.int(stmt, 4, numFrames)
            SQLiteBind.int64(stmt, 5, sizeBytes)
            SQLiteBind.int(stmt, 6, status)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw SQLiteError.step("insert video failed")
            }
            return db.lastInsertRowID()
        }
    }

    public func attachFrame(id frameID: Int64, videoID: Int64, videoIndex: Int) throws {
        try withSerializedMutation {
            let stmt = try db.prepare("UPDATE frame SET video = ?, video_index = ? WHERE id = ?")
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.int64(stmt, 1, videoID)
            SQLiteBind.int(stmt, 2, videoIndex)
            SQLiteBind.int64(stmt, 3, frameID)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw SQLiteError.step("attachFrame video failed")
            }
        }
    }

    /// Frames for a video ordered by timestamp (`idx_frame_video_timestamp`).
    public func frames(videoID: Int64, limit: Int = 10_000) throws -> [FrameRow] {
        let sql = """
            SELECT id, timestamp, image_path, width, height, foreground, background, title,
                   segment, video, video_index, is_inactive, ax_root_hash,
                   capture_display_x, capture_display_y, capture_display_width, capture_display_height
            FROM frame
            WHERE video = ?
            ORDER BY timestamp ASC
            LIMIT ?
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, videoID)
        SQLiteBind.int(stmt, 2, limit)
        var rows: [FrameRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Self.frameRow(from: stmt))
        }
        return rows
    }

    /// Map frame SELECT columns: id...is_inactive, ax_root_hash, capture_display_*.
    private static func frameRow(from stmt: OpaquePointer) -> FrameRow {
        let cx = SQLiteColumn.doubleOptional(stmt, 13)
        let cy = SQLiteColumn.doubleOptional(stmt, 14)
        let cw = SQLiteColumn.doubleOptional(stmt, 15)
        let ch = SQLiteColumn.doubleOptional(stmt, 16)
        let capture: CaptureDisplayRect? = {
            guard let cx, let cy, let cw, let ch else { return nil }
            return CaptureDisplayRect(x: cx, y: cy, width: cw, height: ch)
        }()
        return FrameRow(
            id: SQLiteColumn.int64(stmt, 0),
            timestampMs: SQLiteColumn.int64(stmt, 1),
            imagePath: SQLiteColumn.text(stmt, 2),
            width: SQLiteColumn.intOptional(stmt, 3),
            height: SQLiteColumn.intOptional(stmt, 4),
            foreground: SQLiteColumn.text(stmt, 5),
            background: SQLiteColumn.text(stmt, 6),
            title: SQLiteColumn.text(stmt, 7),
            segmentID: SQLiteColumn.int64Optional(stmt, 8),
            videoID: SQLiteColumn.int64Optional(stmt, 9),
            videoIndex: SQLiteColumn.intOptional(stmt, 10),
            isInactive: SQLiteColumn.bool(stmt, 11),
            axRootHash: SQLiteColumn.data(stmt, 12),
            captureDisplay: capture
        )
    }

    public func sampleFrames(limit: Int = 50, minSegLen: Int = 1) throws -> [FrameRow] {
        // One representative frame per segment (earliest in segment) with enough frames.
        let sql = """
            SELECT f.id, f.timestamp, f.image_path, f.width, f.height, f.foreground, f.background, f.title,
                   f.segment, f.video, f.video_index, f.is_inactive, f.ax_root_hash,
                   f.capture_display_x, f.capture_display_y, f.capture_display_width, f.capture_display_height
            FROM frame f
            WHERE f.id IN (
                SELECT MIN(f2.id)
                FROM frame f2
                WHERE f2.segment IS NOT NULL
                GROUP BY f2.segment
                HAVING COUNT(*) >= ?
            )
            ORDER BY f.timestamp ASC
            LIMIT ?
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int(stmt, 1, minSegLen)
        SQLiteBind.int(stmt, 2, limit)
        var rows: [FrameRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Self.frameRow(from: stmt))
        }
        return rows
    }
}
