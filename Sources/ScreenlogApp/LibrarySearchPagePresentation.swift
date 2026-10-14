import Foundation
import ScreenlogCore

enum LibrarySearchFilterRules {
    static func timeRangeIsValid(from: Int64?, to: Int64?) -> Bool {
        guard let from, let to else { return true }
        return from <= to
    }

    static func reconcileQueryFacets(
        from old: ParsedSearchQuery, to parsed: ParsedSearchQuery,
        appName: String?, app: inout String?, domain: inout String?
    ) {
        if parsed.appFilter != old.appFilter,
            appFilterConflicts(parsed.appFilter, bundleID: app, name: appName)
        {
            app = nil
        }
        if parsed.siteFilter != old.siteFilter, siteFilterConflicts(parsed.siteFilter, domain: domain) {
            domain = nil
        }
    }

    static func appFilterConflicts(_ filter: String?, bundleID: String?, name: String?) -> Bool {
        guard let filter, let bundleID else { return false }
        let value = filter.lowercased()
        return !bundleID.lowercased().contains(value) && !(name?.lowercased().contains(value) ?? false)
    }

    static func siteFilterConflicts(_ filter: String?, domain: String?) -> Bool {
        guard let filter, let domain else { return false }
        let wanted = FaviconCache.normalizeDomain(filter)
        let selected = FaviconCache.normalizeDomain(domain)
        return selected != wanted && !selected.hasSuffix(".\(wanted)")
    }

    /// A clicked facet replaces only a conflicting operator of the same kind.
    /// App and website are independent constraints, including for browser apps.
    static func selectingApp(
        _ bundleID: String?, name: String?, query: inout String, selected: inout String?
    ) {
        selected = selected == bundleID ? nil : bundleID
        if appFilterConflicts(SearchOperatorParser.parse(query).appFilter, bundleID: selected, name: name) {
            query = SearchOperatorParser.removeOperator(.app, from: query)
        }
    }

    static func selectingDomain(_ domain: String?, query: inout String, selected: inout String?) {
        let normalized = domain.map { FaviconCache.normalizeDomain($0) }.flatMap { $0.isEmpty ? nil : $0 }
        selected = selected == normalized ? nil : normalized
        if siteFilterConflicts(SearchOperatorParser.parse(query).siteFilter, domain: selected) {
            query = SearchOperatorParser.removeOperator(.site, from: query)
        }
    }

    static func timeRangesOverlap(
        from firstFrom: Int64?, to firstTo: Int64?, otherFrom: Int64?, otherTo: Int64?
    ) -> Bool {
        timeRangeIsValid(
            from: SemanticSearchPresentation.lowerBound(firstFrom, otherFrom),
            to: SemanticSearchPresentation.upperBound(firstTo, otherTo)
        )
    }

    /// Keep compatible typed boundaries when a date preset or session is chosen.
    static func removingConflictingTimeOperators(from query: String, lower: Int64?, upper: Int64?) -> String {
        let parsed = SearchOperatorParser.parse(query)
        var result = query
        for (kind, from, to) in [
            (SearchOperatorKind.date, parsed.dayStartMs, parsed.dayEndMs),
            (.since, parsed.sinceMs, nil),
            (.before, nil, parsed.beforeMs),
        ] {
            if !timeRangesOverlap(from: from, to: to, otherFrom: lower, otherTo: upper) {
                result = SearchOperatorParser.removeOperator(kind, from: result)
            }
        }
        let bounds = SearchOperatorParser.sqlTimeBounds(from: SearchOperatorParser.parse(result))
        if !timeRangeIsValid(from: bounds.fromTimestampMs, to: bounds.toTimestampMs) {
            for kind in [SearchOperatorKind.date, .before, .since] {
                result = SearchOperatorParser.removeOperator(kind, from: result)
            }
        }
        return result
    }

    /// UI choices replace conflicting time criteria; typed contradictions stay
    /// in the editor so validation can explain what needs to change.
    static func replacingTimeOperator(_ kind: SearchOperatorKind, value: String, in raw: String) -> String {
        var query = raw
        if kind == .date {
            query = SearchOperatorParser.removeOperator(.since, from: query)
            query = SearchOperatorParser.removeOperator(.before, from: query)
        } else {
            query = SearchOperatorParser.removeOperator(.date, from: query)
        }
        query = SearchOperatorParser.replacingOperator(kind, value: value, in: query)
        let bounds = SearchOperatorParser.sqlTimeBounds(from: SearchOperatorParser.parse(query))
        if !timeRangeIsValid(from: bounds.fromTimestampMs, to: bounds.toTimestampMs) {
            query = SearchOperatorParser.removeOperator(kind == .since ? .before : .since, from: query)
        }
        return query
    }
}

/// Privacy-safe reasons a Library query can be retried locally.
/// Underlying SQLite and filesystem errors never cross this boundary.
enum LibrarySearchIssue: Equatable, Sendable {
    case libraryNotReady
    case queryFailed

    var title: String {
        switch self {
        case .libraryNotReady: return "Library is not ready"
        case .queryFailed: return "Could not search your Library"
        }
    }

    var message: String {
        switch self {
        case .libraryNotReady:
            return "Your saved history is still on this Mac. Wait a moment. Then try again."
        case .queryFailed:
            return "Your saved history is still on this Mac. Try the search again."
        }
    }
}

/// Operation state for Library search. Query shape, filters, and result counts
/// remain separate data so cancellation never fabricates an empty result.
enum LibrarySearchState: Equatable, Sendable {
    case idle
    case loading
    case complete
    case failed(LibrarySearchIssue)

    var isLoading: Bool { self == .loading }

    var issue: LibrarySearchIssue? {
        guard case .failed(let issue) = self else { return nil }
        return issue
    }
}

enum LibraryContentMode: String, CaseIterable, Identifiable, Sendable {
    case search
    case sessions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .search: return "Search"
        case .sessions: return "Sessions"
        }
    }
}

/// Durable presentation state for the Library results workspace.
///
/// Query criteria already live on `AppModel`; keeping the remaining navigation
/// state there as well makes a Library -> Timeline -> Library round trip
/// independent of whether AppKit retained or rebuilt the SwiftUI hierarchy.
struct LibraryWorkspaceNavigationState: Equatable, Sendable {
    var selectedResultID: Int64?
    var resultViewportAnchorID: Int64?
    var compactPreviewPresented = false
    var inspectorPanePresented = true
    var contentMode = LibraryContentMode.search
    var selectedSessionStartMs: Int64?

    mutating func selectResult(_ frameID: Int64?) {
        selectedResultID = frameID
        resultViewportAnchorID = frameID
    }

    /// Only Find changes sections. Native focus restoration and queued focus
    /// callbacks must not turn a retained Sessions workspace back into Search.
    var acceptsSearchFocus: Bool { contentMode == .search }

    @discardableResult
    mutating func prepareSearchFocus(selectingExistingQuery: Bool) -> Bool {
        if selectingExistingQuery { contentMode = .search }
        return acceptsSearchFocus
    }

    /// A session lookup may suspend. Never replace a newer navigation choice
    /// when the context action's lookup finally returns.
    @discardableResult
    mutating func showSelectedResult(inSession startMs: Int64, ifUnchangedSince navigation: Self) -> Bool {
        guard self == navigation, selectedResultID != nil else { return false }
        selectedSessionStartMs = startMs
        contentMode = .sessions
        return true
    }

    /// Keep the exact selection when possible. If filtering removes it, choose
    /// the nearest surviving result from the previous ordering instead of
    /// unexpectedly jumping to the first card.
    mutating func reconcileSelection(
        currentResultIDs: [Int64],
        previousResultIDs: [Int64]
    ) {
        guard !currentResultIDs.isEmpty else {
            selectResult(nil)
            return
        }
        if let selectedResultID, currentResultIDs.contains(selectedResultID) {
            resultViewportAnchorID = selectedResultID
            return
        }

        if let selectedResultID,
            let previousIndex = previousResultIDs.firstIndex(of: selectedResultID)
        {
            let visibleIDs = Set(currentResultIDs)
            if let nearest = previousResultIDs.enumerated()
                .filter({ visibleIDs.contains($0.element) })
                .min(by: {
                    abs($0.offset - previousIndex) < abs($1.offset - previousIndex)
                })
            {
                selectResult(nearest.element)
                return
            }
        }

        selectResult(currentResultIDs.first)
    }
}

/// Bounded work and interaction rules for the Library search pipeline.
/// Keyboard input is acknowledged synchronously by setting `.loading`; Store
/// work starts only after the debounce and always runs off MainActor.
enum LibrarySearchInteractionPolicy {
    static let inputAcknowledgementBudgetMilliseconds = 100
    static let debounceNanoseconds: UInt64 = 240_000_000
    static let pageSize = 80

    static func resultsRemainInteractive(
        visibleCount: Int,
        state: LibrarySearchState
    ) -> Bool {
        switch state {
        case .idle, .loading, .complete, .failed:
            return visibleCount > 0
        }
    }
}

/// One publication gate for every asynchronous Library result. Cancellation
/// and generation checks must stay coupled so no superseded page or facet scan
/// can mutate the retained workspace.
enum LibrarySearchPublicationPolicy {
    static func allowsPublication(
        requestGeneration: UInt,
        currentGeneration: UInt,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && requestGeneration == currentGeneration
    }
}

/// Truthful presentation for one bounded Library result page. A page never
/// claims its visible count is the total when SQLite returned a sentinel row.
struct LibrarySearchPagePresentation: Equatable, Sendable {
    static let maximumVisibleResults = 500

    let visibleCount: Int
    let isTruncated: Bool
    let hasNextPage: Bool

    init(visibleCount: Int, isTruncated: Bool, hasNextPage: Bool = false) {
        self.visibleCount = visibleCount
        self.isTruncated = isTruncated
        self.hasNextPage = hasNextPage
    }

    var countLabel: String {
        let suffix = isTruncated ? "+" : ""
        let noun = visibleCount == 1 && !isTruncated ? "result" : "results"
        return "\(visibleCount)\(suffix) \(noun)"
    }

    var canLoadMore: Bool {
        isTruncated && hasNextPage && visibleCount < Self.maximumVisibleResults
    }

}
