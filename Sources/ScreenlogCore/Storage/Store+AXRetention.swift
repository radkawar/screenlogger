import Compression
import Foundation
import SQLite3

public struct DatabasePayloadMigrationBatch: Equatable, Sendable {
    public let scannedPayloadCount: Int
    public let compressedPayloadCount: Int
    /// Stored payload bytes, not space returned to the filesystem.
    public let payloadBytesSaved: Int64
    public let isComplete: Bool
    public let reclamationPending: Bool
}

enum AXPayloadCodec {
    private static let magic = Data([0x53, 0x4C, 0x41, 0x58, 0x01])
    static let maximumDecodedBytes = 32 * 1024 * 1024

    static func encode(_ data: Data) -> Data {
        // Raw legacy payloads remain readable, while compressed payloads must
        // never advertise a size that this same codec refuses to decode.
        guard !data.isEmpty, data.count <= maximumDecodedBytes else { return data }
        var compressed = Data(count: data.count)
        let encodedCount = compressed.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { inputBytes in
                compression_encode_buffer(
                    outputBytes.bindMemory(to: UInt8.self).baseAddress!,
                    outputBytes.count,
                    inputBytes.bindMemory(to: UInt8.self).baseAddress!,
                    inputBytes.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        let headerSize = magic.count + MemoryLayout<UInt64>.size
        guard encodedCount > 0, headerSize + encodedCount < data.count else { return data }
        compressed.count = encodedCount

        var output = magic
        var decodedSize = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &decodedSize) { output.append(contentsOf: $0) }
        output.append(compressed)
        return output
    }

    static func isEncoded(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    static func decode(_ data: Data) -> Data? {
        guard data.starts(with: magic) else { return data }
        let sizeStart = magic.count
        let payloadStart = sizeStart + MemoryLayout<UInt64>.size
        guard data.count > payloadStart else { return nil }

        var decodedSize: UInt64 = 0
        for (offset, byte) in data[sizeStart..<payloadStart].enumerated() {
            decodedSize |= UInt64(byte) << UInt64(offset * 8)
        }
        guard decodedSize > 0, decodedSize <= UInt64(maximumDecodedBytes) else { return nil }

        let payload = data[payloadStart...]
        var output = Data(count: Int(decodedSize))
        let decodedCount = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { inputBytes in
                compression_decode_buffer(
                    outputBytes.bindMemory(to: UInt8.self).baseAddress!,
                    outputBytes.count,
                    inputBytes.bindMemory(to: UInt8.self).baseAddress!,
                    inputBytes.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        return decodedCount == output.count ? output : nil
    }
}

extension Store {
    private static let payloadMigrationID = "ax-payload-lzfse-v1"
    private static let payloadMigrationCursor = "ax-payload-lzfse-v1.cursor"
    private static let payloadMigrationTable = "ax-payload-lzfse-v1.table"
    private static let payloadReclamation = "ax-payload-lzfse-v1.reclamation"

    /// Commits at most 32 rows or 4 MiB of source payloads per call. A single
    /// payload can exceed that byte budget, up to the codec's 32 MiB limit.
    /// Progress and payload changes commit together. No schema transaction
    /// calls this method. Callers must release the writer between calls.
    public func migrateDatabasePayloadBatch() throws -> DatabasePayloadMigrationBatch {
        try Task.checkCancellation()
        return try withSerializedMutation {
            try db.transaction {
                try Task.checkCancellation()
                if try isOnceTaskCompleted(Self.payloadMigrationID) {
                    return DatabasePayloadMigrationBatch(
                        scannedPayloadCount: 0, compressedPayloadCount: 0,
                        payloadBytesSaved: 0, isComplete: true,
                        reclamationPending: try getMeta(key: Self.payloadReclamation) == "pending"
                    )
                }
                let tableIndex = Int(try getMeta(key: Self.payloadMigrationTable) ?? "0") ?? 0
                let table = tableIndex == 0 ? "ax_node" : "ax_legacy_tree"
                let key = tableIndex == 0 ? "rowid" : "frame_id"
                let cursor = try getMeta(key: Self.payloadMigrationCursor).flatMap(Int64.init)
                let after = cursor == nil ? "" : " WHERE \(key) > ?"
                let select = try db.prepare(
                    "SELECT \(key), length(payload) FROM \(table)\(after) ORDER BY \(key) LIMIT 32"
                )
                defer { sqlite3_finalize(select) }
                if let cursor { SQLiteBind.int64(select, 1, cursor) }
                let payload = try db.prepare("SELECT payload FROM \(table) WHERE \(key) = ?")
                defer { sqlite3_finalize(payload) }
                let update = try db.prepare("UPDATE \(table) SET payload = ? WHERE \(key) = ?")
                defer { sqlite3_finalize(update) }
                var rows = 0
                var count = 0
                var sourceBytes = 0
                var saved: Int64 = 0
                var lastID = cursor
                var exhausted = false
                while rows < 32, sourceBytes < 4 * 1024 * 1024 {
                    try Task.checkCancellation()
                    let result = sqlite3_step(select)
                    if result == SQLITE_DONE {
                        exhausted = true
                        break
                    }
                    guard result == SQLITE_ROW else {
                        throw SQLiteError.step("Could not read accessibility data for migration")
                    }
                    let id = SQLiteColumn.int64(select, 0)
                    lastID = id
                    rows += 1
                    let length = SQLiteColumn.int64(select, 1)
                    guard length > 0, length <= Int64(AXPayloadCodec.maximumDecodedBytes) else { continue }
                    sqlite3_reset(payload)
                    sqlite3_clear_bindings(payload)
                    SQLiteBind.int64(payload, 1, id)
                    guard sqlite3_step(payload) == SQLITE_ROW,
                        let raw = SQLiteColumn.data(payload, 0)
                    else { throw SQLiteError.step("Could not read the accessibility payload") }
                    sourceBytes += raw.count
                    guard !AXPayloadCodec.isEncoded(raw) else { continue }
                    let encoded = AXPayloadCodec.encode(raw)
                    guard encoded.count < raw.count else { continue }
                    guard AXPayloadCodec.decode(encoded) == raw else {
                        throw SQLiteError.exec("Accessibility data changed during compression")
                    }
                    sqlite3_reset(update)
                    sqlite3_clear_bindings(update)
                    SQLiteBind.blob(update, 1, encoded)
                    SQLiteBind.int64(update, 2, id)
                    guard sqlite3_step(update) == SQLITE_DONE, db.changes() == 1 else {
                        throw SQLiteError.step("Could not migrate the accessibility payload")
                    }
                    count += 1
                    saved += Int64(raw.count - encoded.count)
                }
                if count > 0 { try setMeta(key: Self.payloadReclamation, value: "pending") }
                let complete = exhausted && tableIndex == 1
                if complete {
                    try markOnceTask(Self.payloadMigrationID)
                } else if exhausted {
                    try setMeta(key: Self.payloadMigrationTable, value: "1")
                    try setMeta(key: Self.payloadMigrationCursor, value: "")
                } else if let lastID {
                    try setMeta(key: Self.payloadMigrationCursor, value: String(lastID))
                }
                return DatabasePayloadMigrationBatch(
                    scannedPayloadCount: rows, compressedPayloadCount: count,
                    payloadBytesSaved: saved, isComplete: complete,
                    reclamationPending: try getMeta(key: Self.payloadReclamation) == "pending"
                )
            }
        }
    }

    /// Run off-main while capture is stopped. The writer stays open and its
    /// executor excludes all concurrent mutations. Failure keeps the pending
    /// marker, so a later safe opportunity can retry without scanning payloads.
    public func reclaimMigratedDatabaseSpace(
        freeSpaceMarginBytes: Int64 = 256 * 1024 * 1024
    ) throws -> SQLiteCompactionReport? {
        try Task.checkCancellation()
        return try withExclusiveMaintenance {
            guard try isOnceTaskCompleted(Self.payloadMigrationID),
                try getMeta(key: Self.payloadReclamation) == "pending"
            else { return nil }
            try Task.checkCancellation()
            let report = try db.compactDatabaseFile(freeSpaceMarginBytes: freeSpaceMarginBytes)
            try setMeta(key: Self.payloadReclamation, value: "complete")
            return report
        }
    }

    // MARK: - Metadata

    public func setMeta(key: String, value: String) throws {
        try withSerializedMutation {
            let stmt = try db.prepare(
                """
                INSERT INTO metadata(key, value, updated_at) VALUES(?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at
                """
            )
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.text(stmt, 1, key)
            SQLiteBind.text(stmt, 2, value)
            SQLiteBind.int64(stmt, 3, Int64(Date().timeIntervalSince1970 * 1000))
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw SQLiteError.step("setMeta failed")
            }
        }
    }

    public func getMeta(key: String) throws -> String? {
        let stmt = try db.prepare("SELECT value FROM metadata WHERE key = ? LIMIT 1")
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.text(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return SQLiteColumn.text(stmt, 0)
    }

    // MARK: - Content-addressed AX tree

    /// Stores XML payload as content-addressed `ax_node`, links `ax_snapshot.root_hash`,
    /// and sets `frame.ax_root_hash`. Full XML lives on the root node payload.
    public func storeAXSnapshot(frameID: Int64, snapshot: AXTreeSnapshot) throws {
        try withSerializedMutation {
            try db.transaction {
                let rawPayload = Data(snapshot.xml.utf8)
                let hash = ContentHash.sha256(rawPayload)
                let payload = AXPayloadCodec.encode(rawPayload)

                let node = try db.prepare(
                    """
                    INSERT OR IGNORE INTO ax_node(hash, payload, first_seen_frame_id)
                    VALUES(?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(node) }
                SQLiteBind.blob(node, 1, hash)
                SQLiteBind.blob(node, 2, payload)
                SQLiteBind.int64(node, 3, frameID)
                if sqlite3_step(node) != SQLITE_DONE {
                    throw SQLiteError.step("insert ax_node failed")
                }

                let snap = try db.prepare(
                    """
                    INSERT INTO ax_snapshot(
                        frame_id, root_hash, timestamp_ms, application_name, bundle_id,
                        process_identifier, extraction_mode, is_partial_tree
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(frame_id) DO UPDATE SET
                        root_hash=excluded.root_hash,
                        timestamp_ms=excluded.timestamp_ms,
                        application_name=excluded.application_name,
                        bundle_id=excluded.bundle_id,
                        process_identifier=excluded.process_identifier,
                        extraction_mode=excluded.extraction_mode,
                        is_partial_tree=excluded.is_partial_tree
                    """
                )
                defer { sqlite3_finalize(snap) }
                let ts = Int64(Date().timeIntervalSince1970 * 1000)
                SQLiteBind.int64(snap, 1, frameID)
                SQLiteBind.blob(snap, 2, hash)
                SQLiteBind.int64(snap, 3, ts)
                SQLiteBind.text(snap, 4, snapshot.applicationName ?? "")
                SQLiteBind.text(snap, 5, snapshot.bundleID ?? "")
                SQLiteBind.int(snap, 6, Int(snapshot.pid))
                SQLiteBind.text(snap, 7, snapshot.extractionMode)
                SQLiteBind.bool(snap, 8, snapshot.isPartial)
                if sqlite3_step(snap) != SQLITE_DONE {
                    throw SQLiteError.step("storeAXSnapshot failed")
                }

                let fr = try db.prepare("UPDATE frame SET ax_root_hash = ? WHERE id = ?")
                defer { sqlite3_finalize(fr) }
                SQLiteBind.blob(fr, 1, hash)
                SQLiteBind.int64(fr, 2, frameID)
                if sqlite3_step(fr) != SQLITE_DONE {
                    throw SQLiteError.step("set frame.ax_root_hash failed")
                }
            }
        }
    }

    /// Optional edge for multi-node accessibility trees.
    public func storeAXNodeEdge(parentHash: Data, childHash: Data) throws {
        try withSerializedMutation {
            let stmt = try db.prepare(
                """
                INSERT OR IGNORE INTO ax_node_edge(parent_hash, child_hash)
                VALUES(?, ?)
                """
            )
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.blob(stmt, 1, parentHash)
            SQLiteBind.blob(stmt, 2, childHash)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw SQLiteError.step("storeAXNodeEdge failed")
            }
        }
    }

    public func axTreeXML(frameID: Int64) throws -> String? {
        let stmt = try db.prepare(
            """
            SELECT n.payload
            FROM ax_snapshot s
            JOIN ax_node n ON n.hash = s.root_hash
            WHERE s.frame_id = ?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, frameID)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            // Fallback: legacy flat tree table
            let leg = try db.prepare("SELECT payload FROM ax_legacy_tree WHERE frame_id = ? LIMIT 1")
            defer { sqlite3_finalize(leg) }
            SQLiteBind.int64(leg, 1, frameID)
            guard sqlite3_step(leg) == SQLITE_ROW, let data = SQLiteColumn.data(leg, 0) else {
                return nil
            }
            guard let decoded = AXPayloadCodec.decode(data) else { return nil }
            return String(data: decoded, encoding: .utf8)
        }
        guard let data = SQLiteColumn.data(stmt, 0) else { return nil }
        guard let decoded = AXPayloadCodec.decode(data) else { return nil }
        return String(data: decoded, encoding: .utf8)
    }

    // MARK: - Aux: once_tasks / app_version / timezone

    public func markOnceTask(_ taskID: String, completed: Bool = true) throws {
        try withSerializedMutation {
            let stmt = try db.prepare(
                """
                INSERT INTO once_tasks(task_id, completed, completed_at)
                VALUES(?, ?, ?)
                ON CONFLICT(task_id) DO UPDATE SET
                    completed=excluded.completed,
                    completed_at=excluded.completed_at
                """
            )
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.text(stmt, 1, taskID)
            SQLiteBind.bool(stmt, 2, completed)
            if completed {
                sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw SQLiteError.step("markOnceTask failed")
            }
        }
    }

    public func isOnceTaskCompleted(_ taskID: String) throws -> Bool {
        let stmt = try db.prepare(
            "SELECT completed FROM once_tasks WHERE task_id = ? LIMIT 1"
        )
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.text(stmt, 1, taskID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return SQLiteColumn.bool(stmt, 0)
    }

    public func recordAppVersion(_ version: String) throws {
        try withSerializedMutation {
            let stmt = try db.prepare(
                "INSERT INTO app_version(version, observed_at) VALUES(?, ?)"
            )
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.text(stmt, 1, version)
            SQLiteBind.int64(stmt, 2, Int64(Date().timeIntervalSince1970 * 1000))
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw SQLiteError.step("recordAppVersion failed")
            }
        }
    }

    public func recordTimezone(_ identifier: String = TimeZone.current.identifier) throws {
        try withSerializedMutation {
            let stmt = try db.prepare(
                "INSERT INTO timezone(identifier, observed_at) VALUES(?, ?)"
            )
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.text(stmt, 1, identifier)
            SQLiteBind.int64(stmt, 2, Int64(Date().timeIntervalSince1970 * 1000))
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw SQLiteError.step("recordTimezone failed")
            }
        }
    }

    // MARK: - Retention helpers

    public func videosOlderThan(newestTimestampMs: Int64) throws -> [VideoRow] {
        let sql = """
            SELECT v.id, v.path, v.size_bytes, v.status
            FROM video v
            WHERE v.status = 0
              AND v.id IN (
                SELECT video FROM frame WHERE video IS NOT NULL
                GROUP BY video
                HAVING MAX(timestamp) < ?
              )
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, newestTimestampMs)
        var rows: [VideoRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(
                VideoRow(
                    id: SQLiteColumn.int64(stmt, 0),
                    path: SQLiteColumn.text(stmt, 1),
                    sizeBytes: SQLiteColumn.int64Optional(stmt, 2),
                    status: Int(SQLiteColumn.int64(stmt, 3))
                )
            )
        }
        return rows
    }

    public func videosByOldestFrame() throws -> [VideoRow] {
        let sql = """
            SELECT v.id, v.path, v.size_bytes, v.status
            FROM video v
            JOIN frame f ON f.video = v.id
            WHERE v.status = 0
            GROUP BY v.id
            ORDER BY MIN(f.timestamp) ASC
            """
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var rows: [VideoRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(
                VideoRow(
                    id: SQLiteColumn.int64(stmt, 0),
                    path: SQLiteColumn.text(stmt, 1),
                    sizeBytes: SQLiteColumn.int64Optional(stmt, 2),
                    status: Int(SQLiteColumn.int64(stmt, 3))
                )
            )
        }
        return rows
    }

    public func totalVideoBytes() throws -> Int64 {
        let stmt = try db.prepare("SELECT COALESCE(SUM(size_bytes), 0) FROM video WHERE status = 0")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return SQLiteColumn.int64(stmt, 0)
    }

    func retentionCandidatesByOldestFrame() throws -> [RetentionCandidate] {
        let stmt = try db.prepare(
            """
            SELECT kind, resource_id, oldest_timestamp, path, size_bytes
            FROM (
                SELECT 0 AS kind,
                       f.id AS resource_id,
                       f.timestamp AS oldest_timestamp,
                       f.image_path AS path,
                       NULL AS size_bytes
                FROM frame f
                WHERE f.image_path IS NOT NULL AND f.image_path != ''

                UNION ALL

                SELECT 1 AS kind,
                       v.id AS resource_id,
                       MIN(f.timestamp) AS oldest_timestamp,
                       v.path AS path,
                       v.size_bytes AS size_bytes
                FROM video v
                JOIN frame f ON f.video = v.id
                WHERE v.status = 0
                GROUP BY v.id
            )
            ORDER BY oldest_timestamp ASC, kind ASC, resource_id ASC
            """
        )
        defer { sqlite3_finalize(stmt) }
        var candidates: [RetentionCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let kind = RetentionCandidateKind(rawValue: Int(SQLiteColumn.int64(stmt, 0))) else {
                continue
            }
            candidates.append(
                RetentionCandidate(
                    kind: kind,
                    id: SQLiteColumn.int64(stmt, 1),
                    timestampMs: SQLiteColumn.int64(stmt, 2),
                    path: SQLiteColumn.text(stmt, 3),
                    sizeBytes: SQLiteColumn.int64Optional(stmt, 4)
                )
            )
        }
        return candidates
    }

    func stillRetentionCandidates(olderThan timestampMs: Int64) throws -> [RetentionCandidate] {
        let stmt = try db.prepare(
            """
            SELECT id, timestamp, image_path
            FROM frame
            WHERE timestamp < ?
              AND image_path IS NOT NULL
              AND image_path != ''
            ORDER BY timestamp ASC, id ASC
            """
        )
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, timestampMs)
        var candidates: [RetentionCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            candidates.append(
                RetentionCandidate(
                    kind: .still,
                    id: SQLiteColumn.int64(stmt, 0),
                    timestampMs: SQLiteColumn.int64(stmt, 1),
                    path: SQLiteColumn.text(stmt, 2),
                    sizeBytes: nil
                )
            )
        }
        return candidates
    }

    func markFrameImagePurged(id: Int64, expectedPath: String) throws {
        try withSerializedMutation {
            let stmt = try db.prepare(
                "UPDATE frame SET image_path = NULL WHERE id = ? AND image_path = ?"
            )
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.int64(stmt, 1, id)
            SQLiteBind.text(stmt, 2, expectedPath)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw SQLiteError.step("markFrameImagePurged failed")
            }
            guard db.changes() == 1 else { throw SQLiteError.notFound }
        }
    }

    func restoreFrameImageForRetentionRetry(id: Int64, path: String) throws {
        try withSerializedMutation {
            let stmt = try db.prepare(
                "UPDATE frame SET image_path = ? WHERE id = ? AND image_path IS NULL"
            )
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.text(stmt, 1, path)
            SQLiteBind.int64(stmt, 2, id)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw SQLiteError.step("restoreFrameImageForRetentionRetry failed")
            }
            guard db.changes() == 1 else { throw SQLiteError.notFound }
        }
    }

    /// Status 2 means the associated pixels were purged.
    public func markVideoPurged(id: Int64) throws {
        try withSerializedMutation {
            let stmt = try db.prepare(
                "UPDATE video SET status = 2, size_bytes = 0 WHERE id = ? AND status = 0"
            )
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.int64(stmt, 1, id)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw SQLiteError.step("markVideoPurged failed")
            }
            guard db.changes() == 1 else {
                throw SQLiteError.notFound
            }
        }
    }

    /// Re-activate a video when final removal of its recovery file fails.
    /// Keeping the recovery path in the row makes the failure retryable and leaves
    /// frame extraction pointed at the bytes that still exist.
    public func restoreVideoForRetentionRetry(id: Int64, path: String, sizeBytes: Int64) throws {
        try withSerializedMutation {
            let stmt = try db.prepare(
                "UPDATE video SET status = 0, path = ?, size_bytes = ? WHERE id = ?"
            )
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.text(stmt, 1, path)
            SQLiteBind.int64(stmt, 2, sizeBytes)
            SQLiteBind.int64(stmt, 3, id)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw SQLiteError.step("restoreVideoForRetentionRetry failed")
            }
            guard db.changes() == 1 else {
                throw SQLiteError.notFound
            }
        }
    }
}
