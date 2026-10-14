import Foundation

public enum SearchQueryValidationError: Error, LocalizedError, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

/// Structured search operators: `app:`, `site:`, `date:`, `before:`, `since:`.
/// Free-text remainder is what goes to FTS5 MATCH.
public struct ParsedSearchQuery: Equatable, Sendable {
    public var ftsText: String
    public var appFilter: String?
    public var siteFilter: String?
    public var dayStartMs: Int64?
    public var dayEndMs: Int64?
    public var beforeMs: Int64?
    public var sinceMs: Int64?
    /// Raw operator values as typed (for chip labels / remove).
    public var rawApp: String?
    public var rawSite: String?
    public var rawDate: String?
    public var rawBefore: String?
    public var rawSince: String?
    /// Invalid drafts must not run with silently discarded constraints.
    public var validationIssue: String?

    public init(
        ftsText: String = "",
        appFilter: String? = nil,
        siteFilter: String? = nil,
        dayStartMs: Int64? = nil,
        dayEndMs: Int64? = nil,
        beforeMs: Int64? = nil,
        sinceMs: Int64? = nil,
        rawApp: String? = nil,
        rawSite: String? = nil,
        rawDate: String? = nil,
        rawBefore: String? = nil,
        rawSince: String? = nil,
        validationIssue: String? = nil
    ) {
        self.ftsText = ftsText
        self.appFilter = appFilter
        self.siteFilter = siteFilter
        self.dayStartMs = dayStartMs
        self.dayEndMs = dayEndMs
        self.beforeMs = beforeMs
        self.sinceMs = sinceMs
        self.rawApp = rawApp
        self.rawSite = rawSite
        self.rawDate = rawDate
        self.rawBefore = rawBefore
        self.rawSince = rawSince
        self.validationIssue = validationIssue
    }

    public var highlightTokens: [String] {
        let seps = CharacterSet.alphanumerics.inverted
        return
            ftsText
            .components(separatedBy: seps)
            .map { $0.lowercased() }
            .filter { $0.count >= 2 }
    }

    public var hasOperators: Bool {
        appFilter != nil || siteFilter != nil || dayStartMs != nil
            || beforeMs != nil || sinceMs != nil
    }
}

public enum SearchOperatorKind: String, CaseIterable, Hashable, Sendable, Identifiable {
    case app, site, date, before, since

    public var id: String { rawValue }
    public var prefix: String { "\(rawValue):" }
    public var title: String {
        switch self {
        case .app: return "Application"
        case .site: return "Website"
        case .date: return "Date"
        case .before: return "Before date"
        case .since: return "Since date"
        }
    }

    public var subtitle: String {
        switch self {
        case .app: return "Limit results to one app"
        case .site: return "Limit results to one website"
        case .date: return "Show results from one day"
        case .before: return "Show results before a date"
        case .since: return "Show results since a date"
        }
    }

    public var systemImage: String {
        switch self {
        case .app: return "app.badge"
        case .site: return "globe"
        case .date: return "calendar"
        case .before: return "calendar.badge.minus"
        case .since: return "calendar.badge.plus"
        }
    }
}

/// Unified autocomplete row for the OPERATORS / values menu.
public enum SearchAutocompleteRow: Equatable, Sendable, Identifiable {
    case op(SearchOperatorKind)
    case app(name: String, bundleID: String?)
    case site(domain: String)
    case dateValue(String)  // today / yesterday / YYYY-MM-DD
    /// Opens the graphical date picker.
    case pickDate

    public var id: String {
        switch self {
        case .op(let k): return "op-\(k.rawValue)"
        case .app(let n, let b): return "app-\(b ?? n)"
        case .site(let d): return "site-\(d)"
        case .dateValue(let v): return "date-\(v)"
        case .pickDate: return "date-pick"
        }
    }

    public var title: String {
        switch self {
        case .op(let k): return k.title
        case .app(let n, _): return n
        case .site(let d): return d
        case .dateValue(let v): return v
        case .pickDate: return "Pick a date..."
        }
    }

    public var subtitle: String? {
        switch self {
        case .op(let k): return k.subtitle
        case .app(_, let bid): return bid
        case .site: return "Filter by website"
        case .dateValue(let v):
            switch v {
            case "today": return "Today"
            case "yesterday": return "Yesterday"
            default: return "Use as date"
            }
        case .pickDate: return "Open calendar"
        }
    }
}

/// What the user is currently typing at the end of the query.
public enum SearchTypingContext: Equatable, Sendable {
    /// Empty query or after a space - offer operator kinds.
    case operators(partial: String)
    /// Typing `app:` or `app:Saf...`
    case appValue(partial: String)
    /// Typing `site:` or `site:en...`
    case siteValue(partial: String)
    /// Typing `date:` / `before:` / `since:` value
    case dateValue(kind: SearchOperatorKind, partial: String)
    /// Free-text FTS term - no operator menu
    case freeText
}

public enum SearchOperatorParser {
    /// Matches complete `key:value` tokens with optional quotes.
    private static let opPattern = try? NSRegularExpression(
        pattern: #"(?i)\b(app|site|date|before|since):(?:"([^"]*)"|([^\s"]+))"#,
        options: []
    )

    /// An opening quote without its closing quote remains an editable draft.
    private static let unfinishedQuotedOpPattern = try? NSRegularExpression(
        pattern: #"(?i)\b(app|site|date|before|since):"([^"]*)$"#,
        options: []
    )

    public static func parse(
        _ raw: String,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> ParsedSearchQuery {
        var cal = calendar
        cal.timeZone = timeZone
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ParsedSearchQuery() }

        var app: String?
        var site: String?
        var dayStart: Int64?
        var dayEnd: Int64?
        var before: Int64?
        var since: Int64?
        var rawApp: String?
        var rawSite: String?
        var rawDate: String?
        var rawBefore: String?
        var rawSince: String?
        var validationIssue: String?
        var seenOperators = Set<String>()

        guard let opPattern else {
            // The expression is a source-controlled constant, but search must
            // remain usable as plain text if it is ever edited incorrectly.
            return ParsedSearchQuery(ftsText: trimmed)
        }

        let ns = trimmed as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = opPattern.matches(in: trimmed, options: [], range: full)

        for m in matches {
            guard m.numberOfRanges >= 4 else { continue }
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            if !seenOperators.insert(key).inserted {
                validationIssue = validationIssue ?? "Use one \(key): filter."
            }
            let val: String
            if m.range(at: 2).location != NSNotFound {
                val = ns.substring(with: m.range(at: 2))
            } else if m.range(at: 3).location != NSNotFound {
                val = ns.substring(with: m.range(at: 3))
            } else {
                val = ""
            }
            guard !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                validationIssue = validationIssue ?? "Enter a value after \(key):."
                continue
            }
            switch key {
            case "app":
                app = val
                rawApp = val
            case "site":
                site = FaviconCache.normalizeDomain(val)
                rawSite = val
                if site?.isEmpty != false {
                    validationIssue = validationIssue ?? "Enter a website after site:."
                }
            case "date":
                rawDate = val
                if let day = parseDay(val, calendar: cal) {
                    dayStart = day.start
                    dayEnd = day.end
                } else {
                    validationIssue = validationIssue ?? "Enter a valid date, such as date:2026-10-15."
                }
            case "before":
                rawBefore = val
                if let day = parseDay(val, calendar: cal) {
                    before = day.end
                } else {
                    validationIssue = validationIssue ?? "Enter a valid end date, such as before:2026-10-15."
                }
            case "since":
                rawSince = val
                if let day = parseDay(val, calendar: cal) {
                    since = day.start
                } else {
                    validationIssue = validationIssue ?? "Enter a valid start date, such as since:2026-10-15."
                }
            default:
                break
            }
        }

        var fts = trimmed
        if let unfinishedQuotedOpPattern {
            let range = NSRange(location: 0, length: (fts as NSString).length)
            if unfinishedQuotedOpPattern.firstMatch(in: fts, range: range) != nil {
                validationIssue = validationIssue ?? "Close the quote to finish this filter."
            }
            fts = unfinishedQuotedOpPattern.stringByReplacingMatches(
                in: fts,
                options: [],
                range: range,
                withTemplate: " "
            )
        }
        fts = opPattern.stringByReplacingMatches(
            in: fts,
            options: [],
            range: NSRange(location: 0, length: (fts as NSString).length),
            withTemplate: " "
        )
        if fts.range(of: #"(?i)\b(app|site|date|before|since):"#, options: .regularExpression) != nil {
            validationIssue = validationIssue ?? "Enter a value after the filter name."
        }
        // Also strip incomplete trailing operators like `app:` with no value
        fts = fts.replacingOccurrences(
            of: #"(?i)\b(app|site|date|before|since):\s*"#,
            with: " ",
            options: .regularExpression
        )
        fts =
            fts
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let lowerBound = max(dayStart ?? Int64.min, since ?? Int64.min)
        let upperBound = min(dayEnd ?? Int64.max, before ?? Int64.max)
        if lowerBound > upperBound {
            validationIssue = validationIssue ?? "These dates don't overlap. Change or remove a date filter."
        }
        return ParsedSearchQuery(
            ftsText: fts,
            appFilter: app,
            siteFilter: site?.isEmpty == true ? nil : site,
            dayStartMs: dayStart,
            dayEndMs: dayEnd,
            beforeMs: before,
            sinceMs: since,
            rawApp: rawApp,
            rawSite: rawSite,
            rawDate: rawDate,
            rawBefore: rawBefore,
            rawSince: rawSince,
            validationIssue: validationIssue
        )
    }

    // MARK: - Autocomplete

    public static func typingContext(for raw: String) -> SearchTypingContext {
        if let context = unfinishedQuotedTypingContext(for: raw) {
            return context
        }
        // Trailing incomplete operator is the focus (even mid-query).
        if raw.hasSuffix(" ") || raw.isEmpty {
            return .operators(partial: "")
        }
        // Last token: after last space, or whole string
        let last: String
        if let r = raw.range(of: " ", options: .backwards) {
            last = String(raw[r.upperBound...])
        } else {
            last = raw
        }
        let lower = last.lowercased()

        // `app:` / `app:partial`
        if lower.hasPrefix("app:") {
            return .appValue(partial: String(last.dropFirst(4)))
        }
        if lower.hasPrefix("site:") {
            return .siteValue(partial: String(last.dropFirst(5)))
        }
        if lower.hasPrefix("date:") {
            return .dateValue(kind: .date, partial: String(last.dropFirst(5)))
        }
        if lower.hasPrefix("before:") {
            return .dateValue(kind: .before, partial: String(last.dropFirst(7)))
        }
        if lower.hasPrefix("since:") {
            return .dateValue(kind: .since, partial: String(last.dropFirst(6)))
        }

        // Partial operator name without colon: "ap", "sit", "dat"
        let opNames = SearchOperatorKind.allCases.map(\.rawValue)
        if opNames.contains(where: { $0.hasPrefix(lower) && lower.count < $0.count + 1 }) {
            // Don't treat long free text as op prefix (e.g. "application")
            if lower.count <= 6, CharacterSet.letters.isSuperset(of: CharacterSet(charactersIn: lower)) {
                return .operators(partial: lower)
            }
        }

        // Free text - hide operator menu while typing a word
        return .freeText
    }

    private static func unfinishedQuotedTypingContext(
        for raw: String
    ) -> SearchTypingContext? {
        guard let unfinishedQuotedOpPattern else { return nil }
        let ns = raw as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard
            let match = unfinishedQuotedOpPattern.firstMatch(
                in: raw,
                options: [],
                range: full
            ), match.numberOfRanges >= 3
        else { return nil }

        let key = ns.substring(with: match.range(at: 1)).lowercased()
        let partial = ns.substring(with: match.range(at: 2))
        switch key {
        case "app": return .appValue(partial: partial)
        case "site": return .siteValue(partial: partial)
        case "date": return .dateValue(kind: .date, partial: partial)
        case "before": return .dateValue(kind: .before, partial: partial)
        case "since": return .dateValue(kind: .since, partial: partial)
        default: return nil
        }
    }

    /// Last whitespace-delimited token (empty when raw ends with space).
    public static func lastToken(in raw: String) -> String {
        if raw.isEmpty || raw.hasSuffix(" ") { return "" }
        if let r = raw.range(of: " ", options: .backwards) {
            return String(raw[r.upperBound...])
        }
        return raw
    }

    /// Build autocomplete rows given typing context + optional catalog of apps/sites.
    ///
    /// Free text surfaces only matching SITES / APPS for the last token.
    /// Operator rows appear after whitespace, for an operator-name prefix, or
    /// while completing an explicit `kind:` token so ordinary searches stay quiet.
    public static func autocompleteRows(
        for raw: String,
        appCatalog: [(name: String, bundleID: String)],
        siteCatalog: [String],
        maxValues: Int = 8
    ) -> [SearchAutocompleteRow] {
        switch typingContext(for: raw) {
        case .freeText:
            // A normal query should not open the full advanced-operator menu.
            // Matching catalog values remain useful as direct refinements.
            let token = lastToken(in: raw)
            var rows: [SearchAutocompleteRow] = []
            rows.append(contentsOf: appRows(matching: token, catalog: appCatalog, max: maxValues))
            rows.append(contentsOf: siteRows(matching: token, catalog: siteCatalog, max: maxValues))
            return rows
        case .operators(let partial):
            let kinds: [SearchOperatorKind]
            if partial.isEmpty {
                kinds = SearchOperatorKind.allCases
            } else {
                // Prefix match (e.g. "ap" to app:). Short tokens like "a" still
                // Match operators while still filtering site and app suggestions below.
                kinds = SearchOperatorKind.allCases.filter {
                    $0.rawValue.hasPrefix(partial.lowercased())
                }
                // If nothing matched as op prefix, still show full operator list
                // so free-text-ish partials never blank the menu.
                if kinds.isEmpty {
                    // Unreachable with current typingContext, but keep safe.
                }
            }
            var rows = kinds.map { SearchAutocompleteRow.op($0) }
            // Catalog values for empty query (preview) or partial filter token.
            let valueFilter = partial
            let valueCap = partial.isEmpty ? min(4, maxValues) : maxValues
            rows.append(contentsOf: siteRows(matching: valueFilter, catalog: siteCatalog, max: valueCap))
            rows.append(contentsOf: appRows(matching: valueFilter, catalog: appCatalog, max: valueCap))
            return rows
        case .appValue(let partial):
            return appRows(matching: partial, catalog: appCatalog, max: maxValues)
        case .siteValue(let partial):
            return siteRows(matching: partial, catalog: siteCatalog, max: maxValues)
        case .dateValue(_, let partial):
            let presets = ["today", "yesterday"]
            let p = partial.lowercased()
            var rows =
                presets
                .filter { p.isEmpty || $0.hasPrefix(p) }
                .map { SearchAutocompleteRow.dateValue($0) }
            // A typed ISO date becomes actionable only once it is complete.
            // Incomplete fragments stay editable and retain the calendar option.
            if !partial.isEmpty, rows.isEmpty,
                parseDay(partial, calendar: .current) != nil
            {
                rows.append(.dateValue(partial))
            }
            // The date suggestion opens the graphical calendar.
            rows.append(.pickDate)
            return rows
        }
    }

    private static func appRows(
        matching partial: String,
        catalog: [(name: String, bundleID: String)],
        max: Int
    ) -> [SearchAutocompleteRow] {
        let p = partial.lowercased()
        let filtered = catalog.filter { app in
            if p.isEmpty { return true }
            return app.name.lowercased().contains(p)
                || app.bundleID.lowercased().contains(p)
                || (app.bundleID.split(separator: ".").last.map { String($0).lowercased().hasPrefix(p) } ?? false)
        }
        return Array(filtered.prefix(max)).map {
            .app(name: $0.name, bundleID: $0.bundleID)
        }
    }

    private static func siteRows(
        matching partial: String,
        catalog: [String],
        max: Int
    ) -> [SearchAutocompleteRow] {
        let p = FaviconCache.normalizeDomain(partial)
        let filtered = catalog.filter { site in
            if p.isEmpty { return true }
            let n = FaviconCache.normalizeDomain(site)
            return n.contains(p) || n.hasPrefix(p)
        }
        var seen = Set<String>()
        var rows: [SearchAutocompleteRow] = []
        for s in filtered {
            let n = FaviconCache.normalizeDomain(s)
            guard !n.isEmpty, !seen.contains(n) else { continue }
            seen.insert(n)
            rows.append(.site(domain: n))
            if rows.count >= max { break }
        }
        return rows
    }

    /// Insert operator prefix, replacing incomplete last token.
    public static func insertOperator(_ kind: SearchOperatorKind, into raw: String) -> String {
        if raw.isEmpty || raw.hasSuffix(" ") {
            return raw + kind.prefix
        }
        if let r = raw.range(of: " ", options: .backwards) {
            let head = String(raw[..<r.upperBound])
            let last = String(raw[r.upperBound...])
            // Mid free-text token to keep free text, append operator after it.
            if case .freeText = typingContext(for: raw) {
                return raw + " " + kind.prefix
            }
            // Partial op name ("ap") or empty last to replace last token.
            if last.contains(":") {
                return head + kind.prefix
            }
            return head + kind.prefix
        }
        // Whole string is partial op name or free text
        let ctx = typingContext(for: raw)
        if case .operators = ctx {
            return kind.prefix
        }
        if case .freeText = ctx {
            return raw + " " + kind.prefix
        }
        return kind.prefix
    }

    /// Complete the current `op:partial` token with a chosen value.
    public static func completeValue(_ value: String, into raw: String) -> String {
        let safe = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return raw }

        // Quote if value has spaces
        let token = safe.contains(" ") ? "\"\(safe)\"" : safe

        if raw.isEmpty { return token + " " }

        // Replace last token after space, or whole string if it's an op:value
        if let space = raw.range(of: " ", options: .backwards) {
            let head = String(raw[..<space.upperBound])
            let last = String(raw[space.upperBound...])
            if let colon = last.firstIndex(of: ":") {
                let key = String(last[..<colon])
                return head + key + ":" + token + " "
            }
            return head + token + " "
        }
        // No space - whole query is op:partial
        if let colon = raw.firstIndex(of: ":") {
            let key = String(raw[..<colon])
            return key + ":" + token + " "
        }
        return token + " "
    }

    /// Apply a site/app/date suggestion from autocomplete.
    /// - Mid `op:value` to complete that token.
    /// - Free text / empty to replace the last free token with `kind:value `.
    public static func applyValueSuggestion(
        _ kind: SearchOperatorKind,
        value: String,
        into raw: String
    ) -> String {
        let safe = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return raw }
        let token = safe.contains(" ") ? "\"\(safe)\"" : safe
        let piece = kind.prefix + token + " "

        if let completed = completeUnfinishedQuotedOperator(
            kind,
            with: piece,
            in: raw
        ) {
            return completed
        }

        let ctx = typingContext(for: raw)
        switch ctx {
        case .appValue:
            guard kind == .app else { break }
            return completeValue(safe, into: raw)
        case .siteValue:
            guard kind == .site else { break }
            return completeValue(safe, into: raw)
        case .dateValue(let k, _):
            guard k == kind else { break }
            return completeValue(safe, into: raw)
        case .operators(let partial) where !partial.isEmpty:
            // "invoice a" / "ap" + Safari to keep prior tokens, replace last with app:Safari
            if let space = raw.range(of: " ", options: .backwards) {
                return String(raw[..<space.upperBound]) + piece
            }
            return piece
        case .freeText:
            // "invoice wiki" + github.com to "invoice site:github.com "
            if let space = raw.range(of: " ", options: .backwards) {
                return String(raw[..<space.upperBound]) + piece
            }
            return piece
        case .operators:
            break
        }
        if raw.isEmpty || raw.hasSuffix(" ") {
            return raw + piece
        }
        return raw + " " + piece
    }

    private static func completeUnfinishedQuotedOperator(
        _ kind: SearchOperatorKind,
        with replacement: String,
        in raw: String
    ) -> String? {
        guard let unfinishedQuotedOpPattern else { return nil }
        let ns = raw as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard
            let match = unfinishedQuotedOpPattern.firstMatch(
                in: raw,
                options: [],
                range: full
            ), match.numberOfRanges >= 2,
            ns.substring(with: match.range(at: 1)).lowercased() == kind.rawValue,
            let range = Range(match.range, in: raw)
        else { return nil }

        return String(raw[..<range.lowerBound]) + replacement
    }

    /// Remove one operator key from the query string.
    public static func removeOperator(_ kind: SearchOperatorKind, from raw: String) -> String {
        let pattern = #"(?i)\b\#(kind.rawValue):(?:"[^"]*"|[^\s]*)\s*"#
        let cleaned = raw.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
        return
            cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keep only complete, valid structured constraints from a mixed query.
    /// This is the model-side contract behind 'Clear Search': authored text is
    /// removed without silently discarding filters the user can still see.
    public static func retainingOnlyValidOperators(in raw: String) -> String {
        let parsed = parse(raw)
        let values: [(SearchOperatorKind, String?)] = [
            (.app, parsed.appFilter == nil ? nil : parsed.rawApp),
            (.site, parsed.siteFilter == nil ? nil : parsed.rawSite),
            (.date, parsed.dayStartMs == nil ? nil : parsed.rawDate),
            (.before, parsed.beforeMs == nil ? nil : parsed.rawBefore),
            (.since, parsed.sinceMs == nil ? nil : parsed.rawSince),
        ]
        return values.reduce(into: "") { query, entry in
            guard let value = entry.1 else { return }
            query = replacingOperator(entry.0, value: value, in: query)
        }
    }

    /// Remove every structured constraint while preserving the authored text.
    /// Parsing also drops unfinished operator drafts, which are filter input
    /// rather than words the user intended Screenlogger to search for.
    public static func removingAllOperators(from raw: String) -> String {
        parse(raw).ftsText
    }

    /// Set one operator without treating ordinary query text as a replaceable
    /// autocomplete fragment. This is the safe path for explicit filter UI such
    /// as the graphical date picker.
    public static func replacingOperator(
        _ kind: SearchOperatorKind,
        value: String,
        in raw: String
    ) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return raw }

        let base = removeOperator(kind, from: raw)
        let safeValue = value.contains(where: \.isWhitespace) ? "\"\(value)\"" : value
        let token = kind.prefix + safeValue
        return base.isEmpty ? token : base + " " + token
    }

    // MARK: - Match helpers

    /// Inclusive SQL time window for `date:` / `since:` / `before:` (AND of all set bounds).
    public static func sqlTimeBounds(
        from parsed: ParsedSearchQuery
    ) -> (fromTimestampMs: Int64?, toTimestampMs: Int64?) {
        var from: Int64?
        var to: Int64?
        if let s = parsed.dayStartMs {
            from = s
        }
        if let e = parsed.dayEndMs {
            to = e
        }
        if let s = parsed.sinceMs {
            from = from.map { max($0, s) } ?? s
        }
        if let b = parsed.beforeMs {
            to = to.map { min($0, b) } ?? b
        }
        return (from, to)
    }

    public static func matchesTimeBounds(_ result: FTSResult, parsed: ParsedSearchQuery) -> Bool {
        let ts = result.timestampMs
        let bounds = sqlTimeBounds(from: parsed)
        if let s = bounds.fromTimestampMs, ts < s { return false }
        if let e = bounds.toTimestampMs, ts > e { return false }
        return true
    }

    public static func matchesApp(_ result: FTSResult, appFilter: String?) -> Bool {
        guard let appFilter, !appFilter.isEmpty else { return true }
        let q = appFilter.lowercased()
        if let bid = result.bundleID?.lowercased(), bid == q || bid.contains(q) { return true }
        if let dn = result.displayName?.lowercased(), dn == q || dn.contains(q) { return true }
        if let bid = result.bundleID?.lowercased(),
            let last = bid.split(separator: ".").last,
            last == q || String(last).contains(q)
        {
            return true
        }
        return false
    }

    public static func matchesSite(_ result: FTSResult, siteFilter: String?) -> Bool {
        guard let siteFilter, !siteFilter.isEmpty else { return true }
        let want = FaviconCache.normalizeDomain(siteFilter)
        let got = FaviconCache.normalizeDomain(result.domain ?? "")
        if got.isEmpty { return false }
        return got == want || got.hasSuffix(".\(want)")
    }

    // MARK: - Day parse

    private static func parseDay(_ raw: String, calendar: Calendar) -> (start: Int64, end: Int64)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let df = DateFormatter()
        df.calendar = calendar
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = calendar.timeZone
        df.dateFormat = "yyyy-MM-dd"
        df.isLenient = false
        if let day = df.date(from: s), df.string(from: day) == s {
            return dayBounds(day, calendar: calendar)
        }
        let lower = s.lowercased()
        let now = Date()
        if lower == "today" {
            return dayBounds(now, calendar: calendar)
        }
        if lower == "yesterday", let y = calendar.date(byAdding: .day, value: -1, to: now) {
            return dayBounds(y, calendar: calendar)
        }
        return nil
    }

    private static func dayBounds(_ day: Date, calendar: Calendar) -> (start: Int64, end: Int64) {
        let start = calendar.startOfDay(for: day)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        let endMs = Int64(nextDay.timeIntervalSince1970 * 1000)
        return (startMs, max(startMs, endMs - 1))
    }
}
