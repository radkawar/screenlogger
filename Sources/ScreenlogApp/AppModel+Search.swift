import AppKit
import Foundation
import ScreenlogCore

/// Explicit ownership for Library clearing. UI labels must map one-to-one to
/// these scopes so a narrow action never discards unrelated search context.
enum LibrarySearchClearScope: Equatable, Sendable {
    case text
    case filters
    case all
}

extension AppModel {
    enum SearchTimeFilter: String, CaseIterable, Identifiable {
        case today, yesterday, lastWeek

        var id: String { rawValue }

        var label: String {
            switch self {
            case .today: return "today"
            case .yesterday: return "yesterday"
            case .lastWeek: return "last week"
            }
        }
    }
}

/// Structured library search, filtering, autocomplete, and catalog discovery.
///
/// Results remain AppModel state because both the standalone Library window and
/// timeline handoff observe them; all query mutation is kept in this feature seam.
@MainActor
extension AppModel {
    // MARK: - Search

    /// Visible hits after every committed constraint (drives chip counts).
    var scopedSearchResults: [FTSResult] {
        searchFacetResults
    }

    /// Every active constraint is applied before the Store's result limit.
    var filteredSearchResults: [FTSResult] {
        searchResults
    }

    var hasActiveLibrarySearchFilters: Bool {
        searchAppFilter != nil
            || searchDomainFilter != nil
            || searchTimeFilter != nil
            || searchContent != .all
            || (searchSessionScoped && selectedSession != nil)
    }

    /// Every committed refinement shown by the Library, including structured
    /// query chips and the sidebar's exact/time/session refinements.
    var activeLibrarySearchFilterCount: Int {
        let parsed = SearchOperatorParser.parse(searchQuery)
        return [
            parsed.appFilter != nil,
            parsed.siteFilter != nil,
            parsed.dayStartMs != nil,
            parsed.beforeMs != nil,
            parsed.sinceMs != nil,
            searchAppFilter != nil,
            searchDomainFilter != nil,
            searchTimeFilter != nil,
            searchContent != .all,
            searchSessionScoped && selectedSession != nil,
        ].filter { $0 }.count
    }

    var canLoadMoreLibrarySearchResults: Bool {
        librarySearchPagePresentation.canLoadMore
    }

    var librarySearchPagePresentation: LibrarySearchPagePresentation {
        LibrarySearchPagePresentation(
            visibleCount: searchResults.count,
            isTruncated: librarySearchResultsAreTruncated,
            hasNextPage: librarySearchNextCursor != nil
        )
    }

    var hasRunnableLibrarySearchCriteria: Bool {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasActiveLibrarySearchFilters
            || (!query.isEmpty && Self.isRunnableSearchQuery(query))
    }

    /// Distinct apps in the scoped hit set (for filter chips).
    var searchResultAppChips: [(bundleID: String, label: String, count: Int)] {
        SearchResultFiltering.appChips(from: scopedSearchResults).map { chip in
            // Prefer localized app name when store only gave a bundle tail.
            let friendly = SLAppIdentity.displayName(bundleID: chip.bundleID)
            let label = (chip.label == chip.bundleID || chip.label.count < 2) ? friendly : chip.label
            // If displayName was present it already won in appChips; still prefer friendly when equal to last path component.
            if chip.label == chip.bundleID.split(separator: ".").last.map(String.init) {
                return (chip.bundleID, friendly, chip.count)
            }
            return (chip.bundleID, label, chip.count)
        }
    }

    /// Distinct website domains in the scoped hit set (favicon chips).
    var searchResultDomainChips: [(domain: String, count: Int)] {
        SearchResultFiltering.domainChips(from: scopedSearchResults)
    }

    /// A non-empty query that is intentionally waiting for more input instead of searching.
    /// Keeping this rule in the model lets the Library distinguish 'keep typing' from a real
    /// zero-result search.
    var searchQueryNeedsMoreInput: Bool {
        let raw = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return !raw.isEmpty && !Self.isRunnableSearchQuery(searchQuery)
    }

    /// Cancelable FTS - strips `app:`/`site:`/`date:`/... operators then MATCH.
    func runSearch() async {
        let task = startLibrarySearch()
        await task?.value
    }

    /// Start one authoritative Store query and retain its worker until SQLite
    /// has actually returned. Cancellation suppresses presentation writes, but
    /// a canceled continuation-backed read must still be drained before restore.
    @discardableResult
    func startLibrarySearch() -> Task<Void, Never>? {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        let generation = invalidateCurrentLibrarySearch()
        librarySearchNextCursor = nil
        guard libraryRestoreState != .restoring else {
            searchResults = []
            searchFacetResults = []
            librarySearchResultsAreTruncated = false
            librarySearchState = .idle
            showSearchOperatorMenu = false
            return nil
        }
        let raw = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !raw.isEmpty || hasActiveLibrarySearchFilters else {
            searchResults = []
            searchFacetResults = []
            librarySearchResultsAreTruncated = false
            lastParsedSearch = ParsedSearchQuery()
            librarySearchState = .idle
            showSearchOperatorMenu = false
            return nil
        }

        guard raw.isEmpty || Self.isRunnableSearchQuery(searchQuery) else {
            searchResults = []
            searchFacetResults = []
            librarySearchResultsAreTruncated = false
            librarySearchState = .idle
            return nil
        }
        guard let store else {
            searchResults = []
            searchFacetResults = []
            librarySearchResultsAreTruncated = false
            librarySearchState =
                libraryStartupIssue == nil ? .failed(.libraryNotReady) : .idle
            return nil
        }

        let parsed = SearchOperatorParser.parse(raw)
        lastParsedSearch = parsed
        guard let query = makeLibrarySearchQuery(parsed: parsed) else {
            searchResults = []
            searchFacetResults = []
            librarySearchResultsAreTruncated = false
            librarySearchState = .idle
            return nil
        }

        librarySearchState = .loading

        #if DEBUG
            if AppUITestFixture.shouldFailLibrarySearch {
                librarySearchState = .failed(.queryFailed)
                return nil
            }
        #endif

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.librarySearchWorkers[generation] = nil
                if self.currentLibrarySearchGeneration == generation {
                    self.searchTask = nil
                    self.currentLibrarySearchGeneration = nil
                }
            }
            do {
                let page = try await store.readAsync { store in
                    try store.searchLibraryPage(
                        query: query,
                        visibleLimit: LibrarySearchInteractionPolicy.pageSize
                    )
                }
                guard
                    LibrarySearchPublicationPolicy.allowsPublication(
                        requestGeneration: generation,
                        currentGeneration: self.librarySearchGeneration,
                        isCancelled: Task.isCancelled
                    )
                else {
                    return
                }
                self.searchResults = page.results
                self.searchFacetResults = page.results
                self.librarySearchNextCursor = page.nextCursor
                self.librarySearchResultsAreTruncated = page.isTruncated
                self.librarySearchState = .complete
                if !raw.isEmpty {
                    self.recentSearchStore.record(raw)
                    self.recentSearchQueries = self.recentSearchStore.all()
                }
                FaviconCache.shared.airgapMode = self.airgapMode
                FaviconCache.shared.remoteFetchingEnabled = self.remoteFaviconsEnabled
                let domains = page.results.compactMap(\.domain)
                Task { await FaviconCache.shared.prefetch(domains: domains) }
            } catch is CancellationError {
                // ignore
            } catch {
                if LibrarySearchPublicationPolicy.allowsPublication(
                    requestGeneration: generation,
                    currentGeneration: self.librarySearchGeneration,
                    isCancelled: Task.isCancelled
                ) {
                    self.librarySearchState = .failed(.queryFailed)
                }
            }
        }
        searchTask = task
        currentLibrarySearchGeneration = generation
        librarySearchWorkers[generation] = task
        return task
    }

    /// Retry only the current Library query. The typed issue remains visible if
    /// the same local operation fails again.
    func retryLibrarySearch() {
        guard librarySearchState.issue != nil else { return }
        startLibrarySearch()
    }

    func loadMoreLibrarySearchResults() {
        guard canLoadMoreLibrarySearchResults, !isSearching else { return }
        guard let store, let cursor = librarySearchNextCursor else { return }
        let parsed = SearchOperatorParser.parse(
            searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard let query = makeLibrarySearchQuery(parsed: parsed) else { return }
        let remaining = LibrarySearchPagePresentation.maximumVisibleResults - searchResults.count
        guard remaining > 0 else { return }
        let requestSize = min(LibrarySearchInteractionPolicy.pageSize, remaining)
        let generation = invalidateCurrentLibrarySearch()
        librarySearchState = .loading

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.librarySearchWorkers[generation] = nil
                if self.currentLibrarySearchGeneration == generation {
                    self.searchTask = nil
                    self.currentLibrarySearchGeneration = nil
                }
            }
            do {
                let page = try await store.readAsync { store in
                    try store.searchLibraryPage(
                        query: query,
                        visibleLimit: requestSize,
                        after: cursor
                    )
                }
                guard
                    LibrarySearchPublicationPolicy.allowsPublication(
                        requestGeneration: generation,
                        currentGeneration: self.librarySearchGeneration,
                        isCancelled: Task.isCancelled
                    )
                else {
                    return
                }
                let existingIDs = Set(self.searchResults.map(\.frameID))
                let newResults = page.results.filter { !existingIDs.contains($0.frameID) }
                self.searchResults.append(contentsOf: newResults)
                self.searchFacetResults = self.searchResults
                self.librarySearchNextCursor = page.nextCursor
                self.librarySearchResultsAreTruncated = page.isTruncated
                self.librarySearchState = .complete
                let domains = page.results.compactMap(\.domain)
                Task { await FaviconCache.shared.prefetch(domains: domains) }
            } catch is CancellationError {
                // Superseded pages never publish.
            } catch {
                if LibrarySearchPublicationPolicy.allowsPublication(
                    requestGeneration: generation,
                    currentGeneration: self.librarySearchGeneration,
                    isCancelled: Task.isCancelled
                ) {
                    self.librarySearchState = .failed(.queryFailed)
                }
            }
        }
        searchTask = task
        currentLibrarySearchGeneration = generation
        librarySearchWorkers[generation] = task
    }

    func clearLibrarySearch(_ scope: LibrarySearchClearScope) {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        invalidateCurrentLibrarySearch()
        librarySearchNextCursor = nil

        switch scope {
        case .text:
            searchQuery = SearchOperatorParser.retainingOnlyValidOperators(in: searchQuery)
        case .filters:
            searchQuery = SearchOperatorParser.removingAllOperators(from: searchQuery)
            clearSearchFilters()
            searchSessionScoped = false
        case .all:
            searchQuery = ""
            clearSearchFilters()
            searchSessionScoped = false
        }

        lastParsedSearch = SearchOperatorParser.parse(searchQuery)
        refreshSearchAutocomplete()
        guard hasRunnableLibrarySearchCriteria else {
            searchResults = []
            searchFacetResults = []
            librarySearchResultsAreTruncated = false
            librarySearchState = .idle
            return
        }
        librarySearchState = .loading
        startLibrarySearch()
    }

    /// Invalidate presentation synchronously while retaining the canceled
    /// worker in `librarySearchWorkers` until its SQLite read really finishes.
    @discardableResult
    func invalidateCurrentLibrarySearch() -> UInt {
        searchTask?.cancel()
        searchTask = nil
        currentLibrarySearchGeneration = nil
        librarySearchGeneration &+= 1
        return librarySearchGeneration
    }

    /// Refresh autocomplete immediately (no debounce) + debounced FTS.
    func scheduleSearchDebounced(autocompleteInput: String? = nil) {
        searchDebounceTask?.cancel()
        invalidateCurrentLibrarySearch()
        librarySearchNextCursor = nil
        let q = searchQuery
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryWillRun =
            trimmed.isEmpty
            ? hasActiveLibrarySearchFilters
            : Self.isRunnableSearchQuery(q)
        // This synchronous state mutation is the input acknowledgement. Keep
        // catalog parsing and every SQLite read after it so typing feedback is
        // not coupled to Library size.
        librarySearchState = queryWillRun ? .loading : .idle
        refreshSearchAutocomplete(for: autocompleteInput)

        if trimmed.isEmpty {
            lastParsedSearch = ParsedSearchQuery()
            showSearchOperatorMenu = false
            searchTask = nil
            if hasActiveLibrarySearchFilters {
                librarySearchState = .loading
                searchDebounceTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(
                        nanoseconds: LibrarySearchInteractionPolicy.debounceNanoseconds
                    )
                    guard let self, !Task.isCancelled else { return }
                    self.searchDebounceTask = nil
                    await self.runSearch()
                }
            } else {
                searchResults = []
                searchFacetResults = []
                librarySearchResultsAreTruncated = false
                librarySearchState = .idle
                searchDebounceTask = nil
            }
            return
        }

        // Results from the previous query are misleading while the current query is an
        // incomplete operator or a single character, neither of which will be submitted.
        if !Self.isRunnableSearchQuery(q) {
            searchResults = []
            searchFacetResults = []
            librarySearchResultsAreTruncated = false
            searchTask = nil
            searchDebounceTask = nil
            return
        }

        librarySearchState = .loading
        searchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: LibrarySearchInteractionPolicy.debounceNanoseconds
            )
            guard let self, !Task.isCancelled else { return }
            // Clear our own handle before entering the authoritative search.
            // `startLibrarySearch` cancels any *older* debounce task; retaining
            // this task there would make it cancel itself and suppress the
            // result publication that follows.
            self.searchDebounceTask = nil
            await self.runSearch()
        }
    }

    private static func isRunnableSearchQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let parsed = SearchOperatorParser.parse(trimmed)
        switch SearchOperatorParser.typingContext(for: query) {
        case .appValue(let prefix) where prefix.isEmpty:
            return false
        case .siteValue(let prefix) where prefix.isEmpty:
            return false
        case .dateValue(_, let prefix) where prefix.isEmpty:
            return false
        case .operators where parsed.ftsText.isEmpty && !parsed.hasOperators:
            return false
        default:
            break
        }

        let hasStructure =
            parsed.appFilter != nil || parsed.siteFilter != nil
            || parsed.dayStartMs != nil || parsed.beforeMs != nil || parsed.sinceMs != nil
        return parsed.ftsText.count >= 2 || hasStructure
    }

    private func makeLibrarySearchQuery(
        parsed: ParsedSearchQuery,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> LibrarySearchQuery? {
        var bounds = SearchOperatorParser.sqlTimeBounds(from: parsed)

        func intersect(from: Int64?, to: Int64?) {
            if let from {
                bounds.fromTimestampMs = bounds.fromTimestampMs.map { max($0, from) } ?? from
            }
            if let to {
                bounds.toTimestampMs = bounds.toTimestampMs.map { min($0, to) } ?? to
            }
        }

        let relativeBounds = relativeSearchTimeBounds(now: now, calendar: calendar)
        intersect(from: relativeBounds.from, to: relativeBounds.to)
        if searchSessionScoped, let session = selectedSession {
            intersect(from: session.startMs, to: session.endMs)
        }

        let results = LibrarySearchQuery(
            text: parsed.ftsText,
            appFilter: parsed.appFilter,
            siteFilter: parsed.siteFilter,
            appBundleID: searchAppFilter,
            domain: searchDomainFilter,
            fromTimestampMs: bounds.fromTimestampMs,
            toTimestampMs: bounds.toTimestampMs,
            content: searchContent,
            sort: searchSort
        )
        guard Self.hasConstraint(results) else { return nil }
        return results
    }

    private func relativeSearchTimeBounds(
        now: Date,
        calendar: Calendar
    ) -> (from: Int64?, to: Int64?) {
        func milliseconds(_ date: Date) -> Int64 {
            Int64(date.timeIntervalSince1970 * 1_000)
        }

        switch searchTimeFilter {
        case .none:
            return (nil, nil)
        case .today?:
            let start = calendar.startOfDay(for: now)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else {
                return (milliseconds(start), milliseconds(now))
            }
            return (milliseconds(start), milliseconds(nextDay) - 1)
        case .yesterday?:
            let today = calendar.startOfDay(for: now)
            guard let start = calendar.date(byAdding: .day, value: -1, to: today) else {
                return (nil, nil)
            }
            return (milliseconds(start), milliseconds(today) - 1)
        case .lastWeek?:
            let today = calendar.startOfDay(for: now)
            guard let start = calendar.date(byAdding: .day, value: -7, to: today) else {
                return (nil, milliseconds(now))
            }
            return (milliseconds(start), milliseconds(now))
        }
    }

    private static func hasConstraint(_ query: LibrarySearchQuery) -> Bool {
        !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || query.appFilter != nil
            || query.siteFilter != nil
            || query.appBundleID != nil
            || query.domain != nil
            || query.fromTimestampMs != nil
            || query.toTimestampMs != nil
            || query.content != .all
    }

    func refreshSearchAutocomplete(for autocompleteInput: String? = nil) {
        // Keep chips in sync with raw text even before FTS finishes.
        lastParsedSearch = SearchOperatorParser.parse(searchQuery)
        let input = autocompleteInput ?? searchQuery
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = SearchOperatorParser.autocompleteRows(
            for: input,
            appCatalog: searchAppCatalog,
            siteCatalog: searchSiteCatalog
        )
        searchAutocompleteRows = rows
        // Show menu when we have rows and search is focused / active.
        // Suggestions should respond to intent, never cover the Library just
        // because its search field became focused.
        showSearchOperatorMenu =
            !trimmed.isEmpty && !rows.isEmpty && shellSearchMode && shellFocusSearch
    }

    func insertSearchOperator(_ kind: SearchOperatorKind) {
        searchQuery = SearchOperatorParser.insertOperator(kind, into: searchQuery)
        enterShellSearch()
        refreshSearchAutocomplete()
    }

    func applyAutocompleteRow(_ row: SearchAutocompleteRow) {
        switch row {
        case .op(let kind):
            insertSearchOperator(kind)
            // Opening a date operator surfaces calendar affordance (presets still in menu).
            if kind == .date || kind == .before || kind == .since {
                searchDatePickerKind = kind
            }
        case .app(let name, _):
            // Free-text picks become `app:Name `; mid `app:` completes the token.
            // Do not also set searchAppFilter - operator matching is fuzzy and chips
            // would force exact bundle IDs that can zero results.
            searchQuery = SearchOperatorParser.applyValueSuggestion(.app, value: name, into: searchQuery)
            enterShellSearch()
            refreshSearchAutocomplete()
            startLibrarySearch()
        case .site(let domain):
            searchQuery = SearchOperatorParser.applyValueSuggestion(.site, value: domain, into: searchQuery)
            enterShellSearch()
            refreshSearchAutocomplete()
            startLibrarySearch()
        case .dateValue(let v):
            // Prefer `date:` when not already typing before:/since:.
            let kind: SearchOperatorKind
            if case .dateValue(let k, _) = SearchOperatorParser.typingContext(for: searchQuery) {
                kind = k
            } else {
                kind = .date
            }
            searchQuery = SearchOperatorParser.applyValueSuggestion(kind, value: v, into: searchQuery)
            enterShellSearch()
            refreshSearchAutocomplete()
            startLibrarySearch()
        case .pickDate:
            openSearchDatePicker()
        }
    }

    /// Open the graphical calendar for the active (or default `date:`) time operator.
    func openSearchDatePicker(
        kind: SearchOperatorKind? = nil,
        origin: LibrarySearchDatePickerOrigin = .search
    ) {
        if let kind, kind == .date || kind == .before || kind == .since {
            searchDatePickerKind = kind
        } else if case .dateValue(let k, _) = SearchOperatorParser.typingContext(for: searchQuery) {
            searchDatePickerKind = k
        } else {
            searchDatePickerKind = .date
        }
        searchDatePickerSelection = Date()
        searchDatePickerOrigin = origin
        showSearchDatePicker = true
        showSearchOperatorMenu = false
        shellSearchMode = true
        shellFocusSearch = false
    }

    /// Commit the graphical calendar selection as `kind:YYYY-MM-DD`.
    func applySearchDatePickerSelection() {
        let df = DateFormatter()
        df.calendar = Calendar.current
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd"
        let value = df.string(from: searchDatePickerSelection)
        let kind = searchDatePickerKind
        // Ensure we are completing/inserting the right operator.
        let ctx = SearchOperatorParser.typingContext(for: searchQuery)
        switch ctx {
        case .dateValue(let k, _) where k == kind:
            searchQuery = SearchOperatorParser.applyValueSuggestion(kind, value: value, into: searchQuery)
        default:
            // Explicit picker choices add a filter without consuming the last
            // ordinary search term, replacing only an existing filter of this kind.
            searchQuery = SearchOperatorParser.replacingOperator(
                kind,
                value: value,
                in: searchQuery
            )
        }
        showSearchDatePicker = false
        enterShellSearch()
        refreshSearchAutocomplete()
        startLibrarySearch()
    }

    func removeSearchOperator(_ kind: SearchOperatorKind) {
        searchQuery = SearchOperatorParser.removeOperator(kind, from: searchQuery)
        lastParsedSearch = SearchOperatorParser.parse(searchQuery)
        refreshSearchAutocomplete()
        startLibrarySearch()
    }

    /// Load app/domain catalogs used by autocomplete (from library + /Applications).
    func refreshSearchCatalogs() async {
        var apps: [(name: String, bundleID: String)] = []
        var sites: [String] = []
        if let store {
            do {
                let listed = try await store.readAsync { try $0.listApplications() }
                for a in listed {
                    let name = a.displayName?.isEmpty == false ? (a.displayName ?? a.bundleID) : a.bundleID
                    apps.append((name, a.bundleID))
                }
                let domains = try await store.readAsync { try $0.listDomains() }
                sites = domains.map(\.normalizedDomain).filter { !$0.isEmpty }
            } catch {
                // fall through to filesystem scan
            }
        }
        // Bundle discovery opens bundle metadata across the Applications
        // directories. Keep that filesystem work off MainActor so first
        // Library presentation and typing remain responsive while autocomplete
        // catalogs warm in the background. Routed UI fixtures use their stable
        // catalog instead of inheriting applications from the test Mac.
        let installed: [(name: String, bundleID: String)]
        #if DEBUG
            if let fixtureApplications = AppUITestFixture.discoveredApplications {
                installed = fixtureApplications.map { ($0.name, $0.bundleID) }
            } else {
                installed = await Task.detached(priority: .utility) {
                    Self.scanAppsForCatalog()
                }.value
            }
        #else
            installed = await Task.detached(priority: .utility) {
                Self.scanAppsForCatalog()
            }.value
        #endif
        var seen = Set(apps.map { $0.bundleID.lowercased() })
        for a in installed where !seen.contains(a.bundleID.lowercased()) {
            seen.insert(a.bundleID.lowercased())
            apps.append(a)
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        searchAppCatalog = apps
        searchSiteCatalog = Array(Set(sites + recordedDomainList)).sorted()
        refreshSearchAutocomplete()
    }

    nonisolated private static func scanAppsForCatalog() -> [(name: String, bundleID: String)] {
        let fm = FileManager.default
        var out: [(String, String)] = []
        var seen = Set<String>()
        for root in [
            "/Applications",
            "/System/Applications",
            NSHomeDirectory() + "/Applications",
        ] {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for name in items where name.hasSuffix(".app") {
                let path = (root as NSString).appendingPathComponent(name)
                guard let bid = Bundle(path: path)?.bundleIdentifier else { continue }
                let key = bid.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                out.append((fm.displayName(atPath: path), bid))
            }
        }
        return out
    }

    var searchOperatorSuggestions: [SearchOperatorKind] {
        searchAutocompleteRows.compactMap {
            if case .op(let k) = $0 { return k }
            return nil
        }
    }

    func setSearchAppFilter(_ bundleID: String?) {
        if searchAppFilter == bundleID {
            searchAppFilter = nil
        } else {
            searchAppFilter = bundleID
        }
        librarySearchFilterDidChange()
    }

    func setSearchDomainFilter(_ domain: String?) {
        let normalized = domain.map { FaviconCache.normalizeDomain($0) }.flatMap { $0.isEmpty ? nil : $0 }
        if searchDomainFilter == normalized {
            searchDomainFilter = nil
        } else {
            searchDomainFilter = normalized
        }
        librarySearchFilterDidChange()
    }

    func applyRecentQuery(_ q: String) {
        searchQuery = q
        enterShellSearch()
        startLibrarySearch()
    }

    func setSearchTimeFilter(_ filter: SearchTimeFilter?) {
        if searchTimeFilter == filter {
            searchTimeFilter = nil
        } else {
            searchTimeFilter = filter
        }
        librarySearchFilterDidChange()
    }

    func setSearchSessionScoped(_ scoped: Bool) {
        searchSessionScoped = scoped && selectedSession != nil
        librarySearchFilterDidChange()
    }

    func setSearchContent(_ content: LibrarySearchContent) {
        guard searchContent != content else { return }
        searchContent = content
        librarySearchFilterDidChange()
    }

    /// Ranked results are a single bounded page, so any cursor from a previous
    /// chronological page is discarded by `librarySearchFilterDidChange`.
    func setSearchSort(_ sort: LibrarySearchSort) {
        guard searchSort != sort else { return }
        searchSort = sort
        librarySearchFilterDidChange()
    }

    func clearAllLibrarySearchFilters() {
        clearLibrarySearch(.filters)
    }

    private func librarySearchFilterDidChange() {
        librarySearchNextCursor = nil
        librarySearchState = .loading
        startLibrarySearch()
    }

}
