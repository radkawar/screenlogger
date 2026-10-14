import Foundation
import SQLite3

extension Store {
    public func configureSemanticIndex(
        enabled: Bool, mode: SemanticSearchMode, pipelineID: String = SemanticPipeline.identity
    ) throws {
        guard !pipelineID.isEmpty else { throw SemanticSearchError.invalidRequest("The semantic pipeline is empty.") }
        try withSerializedMutation {
            try db.transaction {
                let old = try semanticConfiguration()
                if old.pipeline != pipelineID {
                    try db.exec("DELETE FROM semantic_source")
                    try db.exec(
                        "UPDATE semantic_config SET images_watermark = 0, text_watermark = 0, transcripts_watermark = 0, images_initialized = 0, text_initialized = 0"
                    )
                } else if old.enabled != enabled || old.mode != mode {
                    // Invalidate work handed out before consent or mode changed,
                    // including a disable/re-enable cycle with the same pipeline.
                    try db.exec("UPDATE semantic_source SET revision = revision + 1")
                }
                let update = try db.prepare("UPDATE semantic_config SET enabled = ?, mode = ?, pipeline_id = ? WHERE id = 1")
                defer { sqlite3_finalize(update) }
                SQLiteBind.bool(update, 1, enabled)
                SQLiteBind.text(update, 2, mode.rawValue)
                SQLiteBind.text(update, 3, pipelineID)
                try semanticStep(update)
                guard enabled else { return }

                // Historical admission runs in bounded background transactions.
                // Capture triggers remain active while those batches catch up.
                try db.exec(
                    "UPDATE semantic_source SET state = 'pending', error = NULL, revision = revision + 1 WHERE state = 'failed' AND \(Self.semanticKinds(mode))"
                )
            }
        }
    }

    /// Admit at most `limit` historical source candidates for the active mode.
    /// Return true when no history remains at this transaction's snapshot.
    /// Capture triggers admit new sources without advancing these watermarks.
    public func admitSemanticHistory(limit: Int = 256) throws -> Bool {
        guard limit > 0 else {
            throw SemanticSearchError.invalidRequest("The semantic admission limit must be greater than zero.")
        }
        return try withSerializedMutation {
            try db.transaction {
                let configuration = try semanticConfiguration()
                guard configuration.enabled else { return true }
                var remaining = min(limit, 512)
                if configuration.mode.includesImages {
                    remaining -= try admitSemanticCandidates(
                        kind: "image", table: "frame", watermark: "images_watermark", limit: remaining)
                    try db.exec("UPDATE semantic_config SET images_initialized = 1 WHERE id = 1")
                }
                if configuration.mode.includesText {
                    remaining -= try admitSemanticCandidates(
                        kind: "screenText", table: "frame", watermark: "text_watermark", limit: remaining)
                    remaining -= try admitSemanticCandidates(
                        kind: "transcript", table: "transcript_segment", watermark: "transcripts_watermark", limit: remaining)
                    try db.exec("UPDATE semantic_config SET text_initialized = 1 WHERE id = 1")
                }
                let completion = try db.prepare(
                    """
                    SELECT (mode = 'text' OR NOT EXISTS (SELECT 1 FROM frame WHERE id > images_watermark))
                       AND (mode = 'images' OR
                            (NOT EXISTS (SELECT 1 FROM frame WHERE id > text_watermark)
                             AND NOT EXISTS (SELECT 1 FROM transcript_segment WHERE id > transcripts_watermark)))
                    FROM semantic_config WHERE id = 1
                    """)
                defer { sqlite3_finalize(completion) }
                guard sqlite3_step(completion) == SQLITE_ROW else {
                    throw SQLiteError.step("semantic admission completion query failed")
                }
                return SQLiteColumn.bool(completion, 0)
            }
        }
    }

    public func semanticWork(mode: SemanticSearchMode, limit: Int = 8) throws -> [SemanticWorkItem] {
        guard limit > 0 else { return [] }
        return try withReadConnection {
            let stmt = try db.prepare(
                """
                SELECT s.id, s.revision, s.kind, s.frame_id, s.transcript_id, f.title,
                       CASE WHEN s.kind = 'transcript' THEN t.text
                            ELSE coalesce(f.foreground, '') || char(10) || coalesce(f.background, '') END,
                       f.timestamp, f.image_path, v.path, f.video_index, v.status
                FROM semantic_source s
                JOIN semantic_config c ON c.id = 1 AND c.enabled = 1 AND c.pipeline_id = s.pipeline_id
                JOIN frame f ON f.id = s.frame_id
                LEFT JOIN transcript_segment t ON t.id = s.transcript_id AND t.frame_id = f.id
                LEFT JOIN video v ON v.id = f.video
                WHERE s.state = 'pending' AND \(Self.semanticKinds(mode, alias: "s"))
                  AND \(Self.semanticConsent("s"))
                  AND (s.kind != 'image' OR \(SemanticSchema.mediaAvailable("f")))
                ORDER BY s.kind, s.id LIMIT ?
                """)
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.int(stmt, 1, min(64, limit))
            var work: [SemanticWorkItem] = []
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                guard let rawKind = SQLiteColumn.text(stmt, 2), let kind = SemanticSourceKind(rawValue: rawKind) else {
                    throw SemanticSearchError.unavailable("The semantic source is invalid.")
                }
                let frameID = SQLiteColumn.int64(stmt, 3)
                var preview: FramePreviewDescriptor?
                if kind == .image {
                    let source: FramePreviewSource
                    if let path = SQLiteColumn.text(stmt, 8), !path.isEmpty {
                        source = .still(path: path)
                    } else if let path = SQLiteColumn.text(stmt, 9),
                        let index = SQLiteColumn.intOptional(stmt, 10), SQLiteColumn.int64(stmt, 11) == 0
                    {
                        source = .video(path: path, index: index)
                    } else {
                        source = .unavailable
                    }
                    preview = FramePreviewDescriptor(frameID: frameID, timestampMs: SQLiteColumn.int64(stmt, 7), source: source)
                }
                work.append(
                    SemanticWorkItem(
                        id: SQLiteColumn.int64(stmt, 0), revision: SQLiteColumn.int64(stmt, 1), kind: kind,
                        frameID: frameID, transcriptID: SQLiteColumn.int64Optional(stmt, 4),
                        title: SQLiteColumn.text(stmt, 5), text: kind == .image ? nil : SQLiteColumn.text(stmt, 6), preview: preview
                    ))
                rc = sqlite3_step(stmt)
            }
            guard rc == SQLITE_DONE else { throw SQLiteError.step("semantic work query failed") }
            return work
        }
    }

    public func reuseSemanticWork(_ work: SemanticWorkItem, contentHash: String) throws -> Bool {
        try Self.validateSemanticHash(contentHash)
        return try withSerializedMutation {
            try db.transaction {
                guard let pipeline = try liveSemanticPipeline(work) else { return false }
                let donor = try db.prepare(
                    """
                    SELECT id FROM semantic_source
                    WHERE pipeline_id = ? AND kind = ? AND content_hash = ? AND state = 'indexed'
                      AND EXISTS (SELECT 1 FROM semantic_chunk WHERE source_id = semantic_source.id)
                    LIMIT 1
                    """)
                defer { sqlite3_finalize(donor) }
                SQLiteBind.text(donor, 1, pipeline)
                SQLiteBind.text(donor, 2, work.kind.rawValue)
                SQLiteBind.text(donor, 3, contentHash)
                let rc = sqlite3_step(donor)
                guard rc == SQLITE_ROW else {
                    if rc != SQLITE_DONE { throw SQLiteError.step("semantic reuse query failed") }
                    return false
                }
                let donorID = SQLiteColumn.int64(donor, 0)
                let links = try db.prepare(
                    "INSERT INTO semantic_chunk(source_id, ordinal, pipeline_id, hash) SELECT ?, ordinal, pipeline_id, hash FROM semantic_chunk WHERE source_id = ?"
                )
                defer { sqlite3_finalize(links) }
                SQLiteBind.int64(links, 1, work.id)
                SQLiteBind.int64(links, 2, donorID)
                try semanticStep(links)
                try markSemanticIndexed(work.id, contentHash: contentHash)
                return true
            }
        }
    }

    public func completeSemanticWork(
        _ work: SemanticWorkItem, contentHash: String, chunks: [SemanticVectorChunk]
    ) throws -> Bool {
        try Self.validateSemanticHash(contentHash)
        guard !chunks.isEmpty, chunks.count <= 4096, work.kind != .image || chunks.count == 1 else {
            throw SemanticSearchError.invalidRequest("The semantic chunk count is invalid.")
        }
        // Encoding and validation do not hold the database writer.
        let blobs = try chunks.map { chunk -> Data in
            try Self.validateSemanticHash(chunk.hash)
            try Self.validateSemanticVector(chunk.values)
            return Self.semanticVectorData(chunk.values)
        }
        return try withSerializedMutation {
            try db.transaction {
                guard let pipeline = try liveSemanticPipeline(work) else { return false }
                let vector = try db.prepare(
                    "INSERT OR IGNORE INTO semantic_vector(pipeline_id, hash, dimensions, value) VALUES(?, ?, ?, ?)")
                let existing = try db.prepare("SELECT value = ? FROM semantic_vector WHERE pipeline_id = ? AND hash = ?")
                let link = try db.prepare("INSERT INTO semantic_chunk(source_id, ordinal, pipeline_id, hash) VALUES(?, ?, ?, ?)")
                defer {
                    sqlite3_finalize(vector)
                    sqlite3_finalize(existing)
                    sqlite3_finalize(link)
                }
                for (ordinal, chunk) in chunks.enumerated() {
                    sqlite3_reset(vector)
                    SQLiteBind.text(vector, 1, pipeline)
                    SQLiteBind.text(vector, 2, chunk.hash)
                    SQLiteBind.int(vector, 3, SemanticPipeline.dimensions)
                    SQLiteBind.blob(vector, 4, blobs[ordinal])
                    try semanticStep(vector)
                    if db.changes() == 0 {
                        sqlite3_reset(existing)
                        SQLiteBind.blob(existing, 1, blobs[ordinal])
                        SQLiteBind.text(existing, 2, pipeline)
                        SQLiteBind.text(existing, 3, chunk.hash)
                        guard sqlite3_step(existing) == SQLITE_ROW, SQLiteColumn.bool(existing, 0) else {
                            throw SemanticSearchError.invalidRequest("A semantic chunk hash has different vector data.")
                        }
                    }
                    sqlite3_reset(link)
                    SQLiteBind.int64(link, 1, work.id)
                    SQLiteBind.int(link, 2, ordinal)
                    SQLiteBind.text(link, 3, pipeline)
                    SQLiteBind.text(link, 4, chunk.hash)
                    try semanticStep(link)
                }
                try markSemanticIndexed(work.id, contentHash: contentHash)
                return true
            }
        }
    }

    public func failSemanticWork(_ work: SemanticWorkItem, message: String) throws {
        try withSerializedMutation {
            try db.transaction {
                guard try liveSemanticPipeline(work) != nil else { return }
                let stmt = try db.prepare("UPDATE semantic_source SET state = 'failed', error = ? WHERE id = ?")
                defer { sqlite3_finalize(stmt) }
                SQLiteBind.text(stmt, 1, String(message.prefix(2048)))
                SQLiteBind.int64(stmt, 2, work.id)
                try semanticStep(stmt)
            }
        }
    }

    /// A narrow chunk cache lookup lets the caller avoid another native forward.
    /// The source commit still performs its own live revision and consent check.
    public func semanticVectorChunk(hash: String) throws -> SemanticVectorChunk? {
        try Self.validateSemanticHash(hash)
        return try withReadConnection {
            let stmt = try db.prepare(
                """
                SELECT v.value FROM semantic_vector v JOIN semantic_config c
                    ON c.id = 1 AND c.enabled = 1 AND c.pipeline_id = v.pipeline_id
                WHERE v.hash = ?
                """)
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.text(stmt, 1, hash)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return nil }
            guard rc == SQLITE_ROW, let pointer = sqlite3_column_blob(stmt, 0),
                sqlite3_column_bytes(stmt, 0) == SemanticPipeline.dimensions * 4
            else {
                throw SQLiteError.step("semantic vector read failed")
            }
            let values = (0..<SemanticPipeline.dimensions).map { offset in
                Float(bitPattern: UInt32(littleEndian: pointer.loadUnaligned(fromByteOffset: offset * 4, as: UInt32.self)))
            }
            try Self.validateSemanticVector(values)
            return SemanticVectorChunk(hash: hash, values: values)
        }
    }

    public func semanticStatistics(mode: SemanticSearchMode) throws -> SemanticIndexStatistics {
        try withReadConnection {
            let stmt = try db.prepare(
                """
                SELECT kind, state, COUNT(*) FROM semantic_source s
                JOIN semantic_config c ON c.id = 1 AND c.pipeline_id = s.pipeline_id
                WHERE \(Self.semanticKinds(mode, alias: "s")) GROUP BY kind, state
                """)
            defer { sqlite3_finalize(stmt) }
            var stats = SemanticIndexStatistics()
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                let count = Int(SQLiteColumn.int64(stmt, 2))
                switch SQLiteColumn.text(stmt, 0) {
                case "image": stats.imageSources += count
                case "screenText": stats.textSources += count
                case "transcript": stats.transcriptSources += count
                default: break
                }
                switch SQLiteColumn.text(stmt, 1) {
                case "pending": stats.pendingSources += count
                case "indexed": stats.indexedSources += count
                case "failed": stats.failedSources += count
                default: break
                }
                rc = sqlite3_step(stmt)
            }
            guard rc == SQLITE_DONE else { throw SQLiteError.step("semantic statistics failed") }
            // History that has not reached a batch is still pending. Count only
            // eligible, unadmitted candidates; aliases disappear from this count
            // as admission links them to their existing source.
            let history = try db.prepare(
                """
                SELECT
                    CASE WHEN c.mode IN ('images', 'both') AND \(mode.includesImages ? 1 : 0) THEN
                        (SELECT COUNT(*) FROM frame f WHERE f.id > c.images_watermark
                         AND \(SemanticSchema.frameEligible("image"))
                         AND NOT EXISTS (SELECT 1 FROM semantic_occurrence o WHERE o.frame_id = f.id AND o.kind = 'image'))
                    ELSE 0 END,
                    CASE WHEN c.mode IN ('text', 'both') AND \(mode.includesText ? 1 : 0) THEN
                        (SELECT COUNT(*) FROM frame f WHERE f.id > c.text_watermark
                         AND \(SemanticSchema.frameEligible("screenText"))
                         AND NOT EXISTS (SELECT 1 FROM semantic_occurrence o WHERE o.frame_id = f.id AND o.kind = 'screenText'))
                    ELSE 0 END,
                    CASE WHEN c.mode IN ('text', 'both') AND \(mode.includesText ? 1 : 0) THEN
                        (SELECT COUNT(*) FROM transcript_segment t WHERE t.id > c.transcripts_watermark
                         AND length(trim(t.text)) > 0
                         AND NOT EXISTS (SELECT 1 FROM semantic_source s WHERE s.transcript_id = t.id))
                    ELSE 0 END
                FROM semantic_config c WHERE c.id = 1 AND c.enabled = 1
                """)
            defer { sqlite3_finalize(history) }
            let historyRC = sqlite3_step(history)
            if historyRC == SQLITE_ROW {
                let images = Int(SQLiteColumn.int64(history, 0))
                let text = Int(SQLiteColumn.int64(history, 1))
                let transcripts = Int(SQLiteColumn.int64(history, 2))
                stats.imageSources += images
                stats.textSources += text
                stats.transcriptSources += transcripts
                stats.pendingSources += images + text + transcripts
            } else if historyRC != SQLITE_DONE {
                throw SQLiteError.step("semantic history statistics failed")
            }
            let vectors = try db.prepare(
                """
                SELECT COUNT(*), coalesce(SUM(length(v.value)), 0) FROM semantic_vector v
                JOIN semantic_config c ON c.id = 1 AND c.pipeline_id = v.pipeline_id
                WHERE EXISTS (SELECT 1 FROM semantic_chunk ch JOIN semantic_source s ON s.id = ch.source_id
                              WHERE ch.pipeline_id = v.pipeline_id AND ch.hash = v.hash AND \(Self.semanticKinds(mode, alias: "s")))
                """)
            defer { sqlite3_finalize(vectors) }
            guard sqlite3_step(vectors) == SQLITE_ROW else { throw SQLiteError.step("semantic vector statistics failed") }
            stats.vectorCount = Int(SQLiteColumn.int64(vectors, 0))
            stats.vectorBytes = SQLiteColumn.int64(vectors, 1)
            return stats
        }
    }

    public func removeSemanticIndex() throws {
        try withSerializedMutation {
            try db.transaction {
                try db.exec("DELETE FROM semantic_source")
                try db.exec("DELETE FROM semantic_vector")
                try db.exec(
                    "UPDATE semantic_config SET enabled = 0, images_watermark = 0, text_watermark = 0, transcripts_watermark = 0, images_initialized = 0, text_initialized = 0 WHERE id = 1"
                )
            }
        }
    }

    private func admitSemanticCandidates(kind: String, table: String, watermark: String, limit: Int) throws -> Int {
        guard limit > 0 else { return 0 }
        let candidates = try db.prepare(
            """
            SELECT id FROM \(table)
            WHERE id > (SELECT \(watermark) FROM semantic_config WHERE id = 1)
            ORDER BY id LIMIT ?
            """)
        defer { sqlite3_finalize(candidates) }
        SQLiteBind.int(candidates, 1, limit)
        // Prepare once per bounded batch, not once per historical source.
        let admission =
            kind == "transcript"
            ? SemanticSchema.admitTranscript(predicate: "t.id = ?")
            : SemanticSchema.admitFrame(frame: "?", kind: kind)
        var statements: [OpaquePointer] = []
        defer { statements.forEach { sqlite3_finalize($0) } }
        for sql in admission.split(separator: ";") {
            let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { statements.append(try db.prepare(trimmed)) }
        }
        var maximum: Int64?
        var count = 0
        var rc = sqlite3_step(candidates)
        while rc == SQLITE_ROW {
            let id = SQLiteColumn.int64(candidates, 0)
            for statement in statements {
                sqlite3_reset(statement)
                SQLiteBind.int64(statement, 1, id)
                try semanticStep(statement)
            }
            maximum = id
            count += 1
            rc = sqlite3_step(candidates)
        }
        guard rc == SQLITE_DONE else { throw SQLiteError.step("semantic admission failed") }
        if let maximum {
            let update = try db.prepare("UPDATE semantic_config SET \(watermark) = ? WHERE id = 1")
            defer { sqlite3_finalize(update) }
            SQLiteBind.int64(update, 1, maximum)
            try semanticStep(update)
        }
        return count
    }

    private func semanticConfiguration() throws -> (enabled: Bool, mode: SemanticSearchMode, pipeline: String) {
        let stmt = try db.prepare("SELECT enabled, mode, pipeline_id FROM semantic_config WHERE id = 1")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
            let mode = SQLiteColumn.text(stmt, 1).flatMap(SemanticSearchMode.init(rawValue:))
        else {
            throw SemanticSearchError.unavailable("The semantic index configuration is missing.")
        }
        return (SQLiteColumn.bool(stmt, 0), mode, SQLiteColumn.text(stmt, 2) ?? "")
    }

    private func liveSemanticPipeline(_ work: SemanticWorkItem) throws -> String? {
        let stmt = try db.prepare(
            """
            SELECT s.pipeline_id FROM semantic_source s
            JOIN frame f ON f.id = s.frame_id
            JOIN semantic_config c ON c.id = 1 AND c.enabled = 1 AND c.pipeline_id = s.pipeline_id
            WHERE s.id = ? AND s.revision = ? AND s.kind = ? AND s.frame_id = ? AND s.transcript_id IS ?
              AND s.state = 'pending' AND \(Self.semanticConsent("s"))
              AND (s.kind != 'image' OR \(SemanticSchema.mediaAvailable("f")))
            """)
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, work.id)
        SQLiteBind.int64(stmt, 2, work.revision)
        SQLiteBind.text(stmt, 3, work.kind.rawValue)
        SQLiteBind.int64(stmt, 4, work.frameID)
        SQLiteBind.int64(stmt, 5, work.transcriptID)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw SQLiteError.step("semantic source validation failed") }
        return SQLiteColumn.text(stmt, 0)
    }

    private func markSemanticIndexed(_ id: Int64, contentHash: String) throws {
        let stmt = try db.prepare("UPDATE semantic_source SET state = 'indexed', content_hash = ?, error = NULL WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.text(stmt, 1, contentHash)
        SQLiteBind.int64(stmt, 2, id)
        try semanticStep(stmt)
    }

    private func semanticStep(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteError.step("semantic index mutation failed: \(String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt))))")
        }
    }

    static func semanticKinds(_ mode: SemanticSearchMode, alias: String = "") -> String {
        let column = alias.isEmpty ? "kind" : "\(alias).kind"
        switch mode {
        case .images: return "\(column) = 'image'"
        case .text: return "\(column) IN ('screenText', 'transcript')"
        case .both: return "\(column) IN ('image', 'screenText', 'transcript')"
        }
    }

    static func semanticConsent(_ source: String) -> String {
        "((\(source).kind = 'image' AND c.mode IN ('images', 'both')) OR (\(source).kind != 'image' AND c.mode IN ('text', 'both')))"
    }

    static func validateSemanticHash(_ hash: String) throws {
        guard !hash.isEmpty, hash.utf8.count <= 256 else {
            throw SemanticSearchError.invalidRequest("The semantic content hash is invalid.")
        }
    }

    static func validateSemanticVector(_ values: [Float]) throws {
        guard values.count == SemanticPipeline.dimensions else {
            throw SemanticSearchError.invalidRequest("The semantic vector dimension is invalid.")
        }
        var norm = 0.0
        for value in values {
            guard value.isFinite else { throw SemanticSearchError.invalidRequest("The semantic vector has a non-finite value.") }
            norm += Double(value) * Double(value)
        }
        guard norm > 0, abs(norm - 1) <= 0.002 else {
            throw SemanticSearchError.invalidRequest("The semantic vector is not normalized.")
        }
    }

    static func semanticVectorData(_ values: [Float]) -> Data {
        var data = Data(count: values.count * 4)
        data.withUnsafeMutableBytes { raw in
            for (index, value) in values.enumerated() {
                raw.storeBytes(of: value.bitPattern.littleEndian, toByteOffset: index * 4, as: UInt32.self)
            }
        }
        return data
    }
}
