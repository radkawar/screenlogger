import Foundation
import SQLite3

extension Store {
    /// Rank only live, filtered sources. Related search never writes a query
    /// cache, FTS row, or model state into the Library.
    public func semanticSearch(
        vector: [Float], query: LibrarySearchQuery, mode: SemanticSearchMode, limit: Int,
        appFilter: String? = nil, siteFilter: String? = nil
    ) throws -> [SemanticSearchHit] {
        try Self.validateSemanticVector(vector)
        guard limit > 0 else { return [] }
        if let from = query.fromTimestampMs, let to = query.toTimestampMs, from > to { return [] }
        return try withReadConnection {
            let consent = try db.prepare("SELECT enabled FROM semantic_config WHERE id = 1")
            defer { sqlite3_finalize(consent) }
            guard sqlite3_step(consent) == SQLITE_ROW, SQLiteColumn.bool(consent, 0) else {
                throw SemanticSearchError.disabled
            }
            var predicates = [
                "s.state = 'indexed'", "c.enabled = 1", "s.pipeline_id = c.pipeline_id",
                Self.semanticKinds(mode, alias: "s"), Self.semanticConsent("s"),
                "(s.kind != 'image' OR \(SemanticSchema.mediaAvailable("f")))",
            ]
            var bindings: [SemanticFilterBinding] = []
            for raw in [query.appFilter, appFilter] {
                if let value = Self.semanticNonempty(raw)?.lowercased() {
                    predicates.append(
                        "(instr(lower(coalesce(a.bundle_id, '')), ?) > 0 OR instr(lower(coalesce(a.display_name, '')), ?) > 0)")
                    bindings.append(.text(value))
                    bindings.append(.text(value))
                }
            }
            for raw in [query.siteFilter, siteFilter] {
                if let raw = Self.semanticNonempty(raw) {
                    let value = FaviconCache.normalizeDomain(raw)
                    if !value.isEmpty {
                        predicates.append(
                            "(lower(coalesce(d.normalized_domain, '')) = ? OR lower(coalesce(d.normalized_domain, '')) LIKE ? ESCAPE '\\')")
                        bindings.append(.text(value))
                        bindings.append(.text("%." + Self.semanticLikeEscape(value)))
                    }
                }
            }
            if let value = Self.semanticNonempty(query.appBundleID)?.lowercased() {
                predicates.append("lower(coalesce(a.bundle_id, '')) = ?")
                bindings.append(.text(value))
            }
            if let raw = Self.semanticNonempty(query.domain) {
                predicates.append("lower(coalesce(d.normalized_domain, '')) = ?")
                bindings.append(.text(FaviconCache.normalizeDomain(raw)))
            }
            if let from = query.fromTimestampMs {
                predicates.append("f.timestamp >= ?")
                bindings.append(.integer(from))
            }
            if let to = query.toTimestampMs {
                predicates.append("f.timestamp <= ?")
                bindings.append(.integer(to))
            }
            switch query.content {
            case .all: break
            case .screenText: predicates.append("s.kind IN ('image', 'screenText')")
            case .transcripts: predicates.append("s.kind = 'transcript'")
            }
            let eligible = """
                FROM semantic_source s
                JOIN semantic_config c ON c.id = 1
                LEFT JOIN semantic_occurrence o ON o.source_id = s.id
                JOIN frame f ON f.id = CASE WHEN s.kind = 'transcript' THEN s.frame_id ELSE o.frame_id END
                LEFT JOIN transcript_segment t ON t.id = s.transcript_id AND t.frame_id = f.id
                LEFT JOIN segment sg ON sg.id = f.segment
                LEFT JOIN application a ON a.id = sg.application
                LEFT JOIN domain d ON d.id = sg.domain
                LEFT JOIN video media ON media.id = f.video
                WHERE \(predicates.joined(separator: " AND "))
                """
            // Compute each unique vector dot product once. Do not decode or copy
            // a float array for each occurrence or each document chunk link.
            let scoresStatement = try db.prepare(
                """
                WITH eligible AS (SELECT DISTINCT s.id, s.revision \(eligible))
                SELECT e.id, e.revision, ch.hash, v.value
                FROM eligible e JOIN semantic_chunk ch ON ch.source_id = e.id
                JOIN semantic_vector v ON v.pipeline_id = ch.pipeline_id AND v.hash = ch.hash
                """)
            defer { sqlite3_finalize(scoresStatement) }
            Self.bindSemanticFilters(bindings, to: scoresStatement)
            var vectorScores: [String: Double] = [:]
            var sourceScores: [Int64: (revision: Int64, score: Double)] = [:]
            var rc = sqlite3_step(scoresStatement)
            while rc == SQLITE_ROW {
                let sourceID = SQLiteColumn.int64(scoresStatement, 0)
                let revision = SQLiteColumn.int64(scoresStatement, 1)
                guard let hash = SQLiteColumn.text(scoresStatement, 2) else {
                    throw SemanticSearchError.unavailable("A semantic vector hash is missing.")
                }
                let score: Double
                if let cached = vectorScores[hash] {
                    score = cached
                } else {
                    guard sqlite3_column_bytes(scoresStatement, 3) == SemanticPipeline.dimensions * 4,
                        let bytes = sqlite3_column_blob(scoresStatement, 3)
                    else {
                        throw SemanticSearchError.unavailable("A semantic vector has invalid data.")
                    }
                    var dot = 0.0
                    for index in vector.indices {
                        let value = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
                        dot += Double(value) * Double(vector[index])
                    }
                    guard dot.isFinite else { throw SemanticSearchError.unavailable("A semantic score is invalid.") }
                    score = min(1, max(-1, dot))
                    vectorScores[hash] = score
                }
                if sourceScores[sourceID].map({ score > $0.score }) ?? true {
                    sourceScores[sourceID] = (revision, score)
                }
                rc = sqlite3_step(scoresStatement)
            }
            guard rc == SQLITE_DONE else { throw SQLiteError.step("semantic ranking failed") }
            guard !sourceScores.isEmpty else { return [] }
            vectorScores.removeAll(keepingCapacity: false)

            // Hydrate after scoring, from current rows. A source changed or
            // deleted between the reads cannot reuse its prior score.
            let rows = try db.prepare(
                """
                SELECT s.id, s.revision, s.kind, s.content_hash,
                       f.id, f.timestamp, f.title, a.bundle_id, a.display_name, d.normalized_domain,
                       CASE WHEN s.kind = 'transcript' THEN substr(t.text, 1, 360)
                            WHEN s.kind = 'screenText' THEN substr(coalesce(f.foreground, '') || char(10) || coalesce(f.background, ''), 1, 360)
                            ELSE NULL END,
                       f.image_path, (f.video IS NOT NULL AND f.video_index IS NOT NULL AND media.status = 0),
                       t.id, t.source, t.start_timestamp, t.end_timestamp
                \(eligible)
                ORDER BY f.id, s.id
                """)
            defer { sqlite3_finalize(rows) }
            Self.bindSemanticFilters(bindings, to: rows)
            let maximum = min(500, limit)
            var ranked: [SemanticSearchHit] = []
            var images: [String: SemanticSearchHit] = [:]
            var frameBest: SemanticSearchHit?
            var frameImageHash: String?
            func collectFrame() {
                guard let hit = frameBest else { return }
                if hit.kind == .image, let hash = frameImageHash {
                    if var prior = images[hash] {
                        let count = prior.occurrenceCount + 1
                        if Self.semanticRanksBefore(hit, prior) { prior = hit }
                        prior.occurrenceCount = count
                        images[hash] = prior
                    } else {
                        images[hash] = hit
                    }
                } else {
                    Self.insertSemanticHit(hit, into: &ranked, maximum: maximum)
                }
            }
            rc = sqlite3_step(rows)
            while rc == SQLITE_ROW {
                let sourceID = SQLiteColumn.int64(rows, 0)
                let revision = SQLiteColumn.int64(rows, 1)
                if let source = sourceScores[sourceID], source.revision == revision,
                    let rawKind = SQLiteColumn.text(rows, 2), let kind = SemanticSourceKind(rawValue: rawKind)
                {
                    let frameID = SQLiteColumn.int64(rows, 4)
                    if frameBest?.result.frameID != frameID {
                        collectFrame()
                        frameBest = nil
                        frameImageHash = nil
                    }
                    let hit = SemanticSearchHit(
                        result: FTSResult(
                            frameID: frameID, timestampMs: SQLiteColumn.int64(rows, 5),
                            title: SQLiteColumn.text(rows, 6), bundleID: SQLiteColumn.text(rows, 7),
                            displayName: SQLiteColumn.text(rows, 8), domain: SQLiteColumn.text(rows, 9),
                            snippet: SQLiteColumn.text(rows, 10), imagePath: SQLiteColumn.text(rows, 11),
                            isCompacted: SQLiteColumn.bool(rows, 12), transcriptSegmentID: SQLiteColumn.int64Optional(rows, 13),
                            transcriptSource: SQLiteColumn.text(rows, 14).flatMap(TranscriptSource.init(rawValue:)),
                            transcriptStartTimestampMs: SQLiteColumn.int64Optional(rows, 15),
                            transcriptEndTimestampMs: SQLiteColumn.int64Optional(rows, 16)
                        ), kind: kind, score: source.score)
                    if frameBest.map({ Self.semanticRanksBefore(hit, $0) }) ?? true {
                        frameBest = hit
                        frameImageHash = kind == .image ? SQLiteColumn.text(rows, 3) : nil
                    }
                }
                rc = sqlite3_step(rows)
            }
            guard rc == SQLITE_DONE else { throw SQLiteError.step("semantic result hydration failed") }
            collectFrame()
            for hit in images.values { Self.insertSemanticHit(hit, into: &ranked, maximum: maximum) }
            return ranked
        }
    }

    private static func semanticRanksBefore(_ lhs: SemanticSearchHit, _ rhs: SemanticSearchHit) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.result.timestampMs != rhs.result.timestampMs { return lhs.result.timestampMs > rhs.result.timestampMs }
        if lhs.result.frameID != rhs.result.frameID { return lhs.result.frameID > rhs.result.frameID }
        // Prefer a visual match when the same frame has equal text similarity.
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        return (lhs.result.transcriptSegmentID ?? 0) > (rhs.result.transcriptSegmentID ?? 0)
    }

    private static func insertSemanticHit(_ hit: SemanticSearchHit, into hits: inout [SemanticSearchHit], maximum: Int) {
        if hits.count == maximum, let last = hits.last, !semanticRanksBefore(hit, last) { return }
        var lower = 0
        var upper = hits.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if semanticRanksBefore(hit, hits[middle]) { upper = middle } else { lower = middle + 1 }
        }
        hits.insert(hit, at: lower)
        if hits.count > maximum { hits.removeLast() }
    }

    private static func semanticNonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func semanticLikeEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func bindSemanticFilters(_ bindings: [SemanticFilterBinding], to stmt: OpaquePointer) {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .text(let value): SQLiteBind.text(stmt, index, value)
            case .integer(let value): SQLiteBind.int64(stmt, index, value)
            }
        }
    }
}

private enum SemanticFilterBinding {
    case text(String)
    case integer(Int64)
}
