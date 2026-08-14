import Foundation
import SQLite3

/// Which indexed text source participates in a Library search. The default
/// preserves Screenlogger's unified search across visible and spoken content.
public enum LibrarySearchContent: String, Codable, CaseIterable, Sendable {
    case all
    case screenText = "screen"
    case transcripts
}

/// Constraints for one Library query.
///
/// Every non-nil field is applied by SQLite before ordering and limiting the
/// result set. `appFilter` matches a bundle identifier or display name, while
/// `siteFilter` matches a normalized domain or one of its subdomains. The
/// `appBundleID` and `domain` fields are exact selected-chip constraints and
/// are intersected with the fuzzy filters when both are present.
public struct LibrarySearchQuery: Equatable, Sendable {
    public var text: String
    public var appFilter: String?
    public var siteFilter: String?
    public var appBundleID: String?
    public var domain: String?
    public var fromTimestampMs: Int64?
    public var toTimestampMs: Int64?
    public var content: LibrarySearchContent

    public init(
        text: String = "",
        appFilter: String? = nil,
        siteFilter: String? = nil,
        appBundleID: String? = nil,
        domain: String? = nil,
        fromTimestampMs: Int64? = nil,
        toTimestampMs: Int64? = nil,
        content: LibrarySearchContent = .all
    ) {
        self.text = text
        self.appFilter = appFilter
        self.siteFilter = siteFilter
        self.appBundleID = appBundleID
        self.domain = domain
        self.fromTimestampMs = fromTimestampMs
        self.toTimestampMs = toTimestampMs
        self.content = content
    }
}

/// One bounded Library page plus truthful knowledge that additional matches
/// exist. The sentinel row used to determine truncation is never exposed.
public struct LibrarySearchPage: Equatable, Sendable {
    public static let maximumVisibleResults = 500

    public let results: [FTSResult]
    public let isTruncated: Bool
    /// Stable keyset cursor for the next page. Offset pagination becomes
    /// increasingly expensive as a Library grows and can skip/duplicate rows
    /// when capture inserts a newer frame between requests.
    public let nextCursor: LibrarySearchCursor?

    public init(
        results: [FTSResult],
        isTruncated: Bool,
        nextCursor: LibrarySearchCursor? = nil
    ) {
        self.results = results
        self.isTruncated = isTruncated
        self.nextCursor = nextCursor
    }
}

/// Exclusive lower bound for Library keyset pagination. Search results are
/// ordered newest-first by moment timestamp. `frameID` identifies the exact
/// display selected for that moment and remains available for compatibility.
public struct LibrarySearchCursor: Equatable, Sendable {
    public let timestampMs: Int64
    public let frameID: Int64

    public init(timestampMs: Int64, frameID: Int64) {
        self.timestampMs = timestampMs
        self.frameID = frameID
    }
}

extension Store {
    // MARK: - Query: FTS

    /// Full-text search over OCR. Optional `fromTimestampMs` / `toTimestampMs` are applied
    /// in SQL (inclusive) so `date:` / `since:` / `before:` are not limited to post-filtering
    /// the newest `LIMIT` hits.
    public func ftsSearch(
        query: String,
        limit: Int = 50,
        fromTimestampMs: Int64? = nil,
        toTimestampMs: Int64? = nil
    ) throws -> [FTSResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try searchLibrary(
            query: LibrarySearchQuery(
                text: trimmed,
                fromTimestampMs: fromTimestampMs,
                toTimestampMs: toTimestampMs
            ),
            limit: limit
        )
    }

    /// Search OCR text with optional app, site, and inclusive timestamp
    /// constraints. Filter-only and time-only queries are supported; a query
    /// with no usable constraint returns no rows instead of scanning the whole
    /// Library accidentally.
    public func searchLibrary(
        query: LibrarySearchQuery,
        limit requestedLimit: Int = 50
    ) throws -> [FTSResult] {
        try ScreenlogPerformanceSignposts.measure(.warmLibrarySearch) {
            try executeLibrarySearch(
                query: query,
                limit: requestedLimit,
                maximumLimit: LibrarySearchPage.maximumVisibleResults
            )
        }
    }

    /// Search a visible app page and privately request one additional row to
    /// determine whether the count must be presented as truncated.
    public func searchLibraryPage(
        query: LibrarySearchQuery,
        visibleLimit requestedLimit: Int,
        after cursor: LibrarySearchCursor? = nil
    ) throws -> LibrarySearchPage {
        try ScreenlogPerformanceSignposts.measure(.warmLibrarySearch) {
            let visibleLimit = min(
                LibrarySearchPage.maximumVisibleResults,
                max(1, requestedLimit)
            )
            let rows = try executeLibrarySearch(
                query: query,
                limit: visibleLimit + 1,
                maximumLimit: LibrarySearchPage.maximumVisibleResults + 1,
                after: cursor
            )
            let visibleResults = Array(rows.prefix(visibleLimit))
            let isTruncated = rows.count > visibleLimit
            return LibrarySearchPage(
                results: visibleResults,
                isTruncated: isTruncated,
                nextCursor: isTruncated
                    ? visibleResults.last.map {
                        LibrarySearchCursor(
                            timestampMs: $0.timestampMs,
                            frameID: $0.frameID
                        )
                    }
                    : nil
            )
        }
    }

    private func executeLibrarySearch(
        query: LibrarySearchQuery,
        limit requestedLimit: Int,
        maximumLimit: Int,
        after cursor: LibrarySearchCursor? = nil
    ) throws -> [FTSResult] {
        let trimmedText = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = Self.ftsMatchExpression(from: query.text)
        guard trimmedText.isEmpty || !match.isEmpty else { return [] }
        let appFilter = Self.nonemptySearchFilter(query.appFilter)?.lowercased()
        let siteFilter: String? = {
            guard let raw = Self.nonemptySearchFilter(query.siteFilter) else { return nil }
            let normalized = FaviconCache.normalizeDomain(raw)
            return normalized.isEmpty ? nil : normalized
        }()
        let appBundleID = Self.nonemptySearchFilter(query.appBundleID)?.lowercased()
        let domain: String? = {
            guard let raw = Self.nonemptySearchFilter(query.domain) else { return nil }
            let normalized = FaviconCache.normalizeDomain(raw)
            return normalized.isEmpty ? nil : normalized
        }()

        if let from = query.fromTimestampMs, let to = query.toTimestampMs, from > to {
            return []
        }
        let hasTimeConstraint = query.fromTimestampMs != nil || query.toTimestampMs != nil
        guard
            !match.isEmpty || appFilter != nil || siteFilter != nil
                || appBundleID != nil || domain != nil || hasTimeConstraint
                || query.content != .all
        else {
            return []
        }

        let usesFTS = !match.isEmpty
        var whereParts: [String] = []
        if appFilter != nil {
            whereParts.append(
                "(instr(lower(coalesce(a.bundle_id, '')), ?) > 0 "
                    + "OR instr(lower(coalesce(a.display_name, '')), ?) > 0)"
            )
        }
        if siteFilter != nil {
            whereParts.append(
                "(lower(coalesce(d.normalized_domain, '')) = ? "
                    + "OR lower(coalesce(d.normalized_domain, '')) LIKE ? ESCAPE '\\')"
            )
        }
        if appBundleID != nil {
            whereParts.append("lower(coalesce(a.bundle_id, '')) = ?")
        }
        if domain != nil {
            whereParts.append("lower(coalesce(d.normalized_domain, '')) = ?")
        }
        if query.fromTimestampMs != nil {
            whereParts.append("f.timestamp >= ?")
        }
        if query.toTimestampMs != nil {
            whereParts.append("f.timestamp <= ?")
        }
        if cursor != nil {
            whereParts.append("f.timestamp < ?")
        }
        let whereSQL = whereParts.joined(separator: " AND ")
        let filterWhereSQL = whereSQL.isEmpty ? "1 = 1" : whereSQL
        let limit = min(maximumLimit, max(1, requestedLimit))
        let sql: String
        if usesFTS {
            let constrainedWhere = whereSQL.isEmpty ? "" : " AND \(whereSQL)"
            let screenTextCandidates = """
                SELECT
                    f.id AS frame_id,
                    f.timestamp AS timestamp_ms,
                    snippet(ocr_fts, 0, '[', ']', '...', 16) AS snippet_foreground,
                    snippet(ocr_fts, 1, '[', ']', '...', 16) AS snippet_background,
                    snippet(ocr_fts, 2, '[', ']', '...', 16) AS snippet_title,
                    NULL AS snippet_transcript,
                    NULL AS transcript_id,
                    NULL AS transcript_source,
                    NULL AS transcript_start,
                    NULL AS transcript_end
                FROM ocr_fts
                JOIN frame f ON f.id = ocr_fts.rowid
                LEFT JOIN segment s ON s.id = f.segment
                LEFT JOIN application a ON a.id = s.application
                LEFT JOIN domain d ON d.id = s.domain
                WHERE ocr_fts MATCH ?\(constrainedWhere)
                """
            let transcriptCandidates = """
                SELECT
                    f.id AS frame_id,
                    f.timestamp AS timestamp_ms,
                    NULL AS snippet_foreground,
                    NULL AS snippet_background,
                    NULL AS snippet_title,
                    snippet(transcript_fts, 0, '[', ']', '...', 16) AS snippet_transcript,
                    ts.id AS transcript_id,
                    ts.source AS transcript_source,
                    ts.start_timestamp AS transcript_start,
                    ts.end_timestamp AS transcript_end
                FROM transcript_fts
                JOIN transcript_segment ts ON ts.id = transcript_fts.rowid
                JOIN frame f ON f.id = ts.frame_id
                LEFT JOIN segment s ON s.id = f.segment
                LEFT JOIN application a ON a.id = s.application
                LEFT JOIN domain d ON d.id = s.domain
                WHERE transcript_fts MATCH ?\(constrainedWhere)
                """
            let candidates =
                switch query.content {
                case .all:
                    screenTextCandidates + "\nUNION ALL\n" + transcriptCandidates
                case .screenText:
                    screenTextCandidates
                case .transcripts:
                    transcriptCandidates
                }
            sql = """
                WITH candidate_matches AS (
                    \(candidates)
                ), ranked_matches AS (
                    SELECT *,
                        ROW_NUMBER() OVER (
                            PARTITION BY timestamp_ms
                            ORDER BY (transcript_id IS NOT NULL) DESC, frame_id DESC, transcript_id DESC
                        ) AS moment_rank
                    FROM candidate_matches
                ), matching_moments AS (
                    SELECT * FROM ranked_matches
                    WHERE moment_rank = 1
                    ORDER BY timestamp_ms DESC, frame_id DESC
                    LIMIT ?
                )
                SELECT
                    f.id,
                    f.timestamp,
                    f.title,
                    a.bundle_id,
                    a.display_name,
                    d.normalized_domain,
                    m.snippet_foreground,
                    m.snippet_background,
                    m.snippet_title,
                    m.snippet_transcript,
                    f.image_path,
                    CASE WHEN v.status = 0 THEN f.video ELSE NULL END,
                    m.transcript_id,
                    m.transcript_source,
                    m.transcript_start,
                    m.transcript_end
                FROM matching_moments m
                JOIN frame f ON f.id = m.frame_id
                LEFT JOIN segment s ON s.id = f.segment
                LEFT JOIN application a ON a.id = s.application
                LEFT JOIN domain d ON d.id = s.domain
                LEFT JOIN video v ON v.id = f.video
                ORDER BY f.timestamp DESC, f.id DESC
                """
        } else if query.content == .transcripts {
            sql = """
                SELECT
                    f.id,
                    f.timestamp,
                    f.title,
                    a.bundle_id,
                    a.display_name,
                    d.normalized_domain,
                    NULL,
                    NULL,
                    NULL,
                    substr(ts.text, 1, 161),
                    f.image_path,
                    CASE WHEN v.status = 0 THEN f.video ELSE NULL END,
                    ts.id,
                    ts.source,
                    ts.start_timestamp,
                    ts.end_timestamp
                FROM frame f
                JOIN transcript_segment ts ON ts.id = (
                    SELECT newest.id
                    FROM transcript_segment newest
                    WHERE newest.frame_id = f.id
                    ORDER BY newest.id DESC
                    LIMIT 1
                )
                LEFT JOIN segment s ON s.id = f.segment
                LEFT JOIN application a ON a.id = s.application
                LEFT JOIN domain d ON d.id = s.domain
                LEFT JOIN video v ON v.id = f.video
                WHERE \(filterWhereSQL)
                ORDER BY f.timestamp DESC, f.id DESC
                LIMIT ?
                """
        } else {
            sql = """
                WITH matching_moments AS (
                    SELECT MAX(f.id) AS frame_id, f.timestamp AS timestamp_ms
                    FROM frame f
                    LEFT JOIN segment s ON s.id = f.segment
                    LEFT JOIN application a ON a.id = s.application
                    LEFT JOIN domain d ON d.id = s.domain
                    WHERE \(filterWhereSQL)
                    GROUP BY f.timestamp
                    ORDER BY f.timestamp DESC
                    LIMIT ?
                )
                SELECT
                    f.id,
                    f.timestamp,
                    f.title,
                    a.bundle_id,
                    a.display_name,
                    d.normalized_domain,
                    substr(f.foreground, 1, 161),
                    substr(f.background, 1, 161),
                    substr(f.title, 1, 161),
                    NULL,
                    f.image_path,
                    CASE WHEN v.status = 0 THEN f.video ELSE NULL END,
                    NULL,
                    NULL,
                    NULL,
                    NULL
                FROM matching_moments m
                JOIN frame f ON f.id = m.frame_id
                LEFT JOIN segment s ON s.id = f.segment
                LEFT JOIN application a ON a.id = s.application
                LEFT JOIN domain d ON d.id = s.domain
                LEFT JOIN video v ON v.id = f.video
                ORDER BY f.timestamp DESC, f.id DESC
                """
        }
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var bind: Int32 = 1
        func bindConstraints() {
            if let appFilter {
                SQLiteBind.text(stmt, bind, appFilter)
                SQLiteBind.text(stmt, bind + 1, appFilter)
                bind += 2
            }
            if let siteFilter {
                SQLiteBind.text(stmt, bind, siteFilter)
                SQLiteBind.text(stmt, bind + 1, "%.\(Self.escapedLikeLiteral(siteFilter))")
                bind += 2
            }
            if let appBundleID {
                SQLiteBind.text(stmt, bind, appBundleID)
                bind += 1
            }
            if let domain {
                SQLiteBind.text(stmt, bind, domain)
                bind += 1
            }
            if let from = query.fromTimestampMs {
                SQLiteBind.int64(stmt, bind, from)
                bind += 1
            }
            if let to = query.toTimestampMs {
                SQLiteBind.int64(stmt, bind, to)
                bind += 1
            }
            if let cursor {
                SQLiteBind.int64(stmt, bind, cursor.timestampMs)
                bind += 1
            }
        }
        if usesFTS {
            if query.content != .transcripts {
                SQLiteBind.text(stmt, bind, match)
                bind += 1
                bindConstraints()
            }
            if query.content != .screenText {
                SQLiteBind.text(stmt, bind, match)
                bind += 1
                bindConstraints()
            }
        } else {
            bindConstraints()
        }
        SQLiteBind.int(stmt, bind, limit)
        var results: [FTSResult] = []
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            let snipFG = SQLiteColumn.text(stmt, 6)
            let snipBG = SQLiteColumn.text(stmt, 7)
            let snipTitle = SQLiteColumn.text(stmt, 8)
            let transcriptSnippet = SQLiteColumn.text(stmt, 9)
            let imagePath = SQLiteColumn.text(stmt, 10)
            let videoID = SQLiteColumn.int64Optional(stmt, 11)
            let transcriptID = SQLiteColumn.int64Optional(stmt, 12)
            let transcriptSource = SQLiteColumn.text(stmt, 13).flatMap(TranscriptSource.init(rawValue:))
            let stillMissing = imagePath.map { $0.isEmpty } ?? true
            results.append(
                FTSResult(
                    frameID: SQLiteColumn.int64(stmt, 0),
                    timestampMs: SQLiteColumn.int64(stmt, 1),
                    title: SQLiteColumn.text(stmt, 2),
                    bundleID: SQLiteColumn.text(stmt, 3),
                    displayName: SQLiteColumn.text(stmt, 4),
                    domain: SQLiteColumn.text(stmt, 5),
                    snippet: transcriptSnippet
                        ?? Self.preferredFTSSnippet(
                            foreground: snipFG,
                            background: snipBG,
                            title: snipTitle
                        ),
                    imagePath: imagePath,
                    isCompacted: stillMissing && videoID != nil,
                    transcriptSegmentID: transcriptID,
                    transcriptSource: transcriptSource,
                    transcriptStartTimestampMs: SQLiteColumn.int64Optional(stmt, 14),
                    transcriptEndTimestampMs: SQLiteColumn.int64Optional(stmt, 15)
                )
            )
            stepResult = sqlite3_step(stmt)
        }
        guard stepResult == SQLITE_DONE else {
            throw SQLiteError.step("library search failed")
        }
        return results
    }

    private static func nonemptySearchFilter(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func escapedLikeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Pick the FTS5 snippet column that actually contains match markers (`[...]`).
    static func preferredFTSSnippet(foreground: String?, background: String?, title: String?) -> String? {
        let candidates = [foreground, background, title]
        if let marked = candidates.first(where: { ($0 ?? "").contains("[") }) {
            return marked
        }
        return candidates.first(where: { !($0 ?? "").isEmpty }) ?? nil
    }

    /// Build a safe FTS5 MATCH expression from free-form user text.
    /// Hyphenated tokens become separate AND terms; quotes/specials stripped.
    public static func ftsMatchExpression(from raw: String) -> String {
        let separators = CharacterSet.alphanumerics.inverted
        let tokens =
            raw
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        // Cap token count to keep queries cheap.
        let limited = Array(tokens.prefix(12))
        guard !limited.isEmpty else { return "" }
        // AND is default FTS5; join explicitly for clarity.
        return limited.joined(separator: " ")
    }

}
