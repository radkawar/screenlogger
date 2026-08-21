import Foundation

extension Store {
    /// Search the local library with the same plain-language operators used by
    /// the app: `app:`, `site:`, `date:`, `since:`, and `before:`.
    ///
    /// Keeping this at the Store boundary gives the app, socket bridge, XPC,
    /// CLI, and assistant integrations one result contract instead of subtly
    /// different query behavior.
    public func searchLibrary(
        query rawQuery: String,
        limit requestedLimit: Int = 50,
        content: LibrarySearchContent = .all,
        literalText: Bool = false
    ) throws -> [FTSResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let limit = min(500, max(1, requestedLimit))
        let parsed = SearchOperatorParser.parse(query)
        let hasStructure =
            parsed.appFilter != nil
            || parsed.siteFilter != nil
            || parsed.dayStartMs != nil
            || parsed.beforeMs != nil
            || parsed.sinceMs != nil
        guard !parsed.ftsText.isEmpty || hasStructure else { return [] }

        let bounds = SearchOperatorParser.sqlTimeBounds(from: parsed)
        return try searchLibrary(
            query: LibrarySearchQuery(
                text: parsed.ftsText,
                appFilter: parsed.appFilter,
                siteFilter: parsed.siteFilter,
                fromTimestampMs: bounds.fromTimestampMs,
                toTimestampMs: bounds.toTimestampMs,
                content: content,
                literalText: literalText
            ),
            limit: limit
        )
    }
}
