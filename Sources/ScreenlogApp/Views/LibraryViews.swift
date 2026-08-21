import ScreenlogCore
import SwiftUI

/// Adaptive Library workspace. The query field remains in `FloatingSearchView`;
/// this view owns refinements, results, selection, and preview presentation.
struct SearchPane: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var focusRequest: Int = 0
    @State private var previousResultIDs: [Int64] = []
    @State private var showCompactFilters = false
    @State private var compactPreviewPopoverActive = false
    @State private var showFilterSidebar = true
    @FocusState private var resultsFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let compactFilters = usesCompactFilters(totalWidth: geometry.size.width)
            let persistentInspector = showsInspector(totalWidth: geometry.size.width)
            if let issue = model.libraryStartupIssue {
                LibraryStartupRecoveryView(issue: issue, surface: .library)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    LibraryContentModeBar(
                        selection: $model.libraryWorkspaceNavigation.contentMode
                    )

                    if let issue = libraryDeletionIssue {
                        TimelineDeletionIssueBannerView(
                            issue: issue,
                            onRetry: { Task { await model.retryLibraryDeletionIssue() } },
                            onDismiss: { model.dismissLibraryDeletionIssue() }
                        )
                        .frame(maxWidth: 620)
                    }

                    if model.libraryWorkspaceNavigation.contentMode == .sessions {
                        LibrarySessionsView()
                    } else {
                        workspace(
                            compactFilters: compactFilters,
                            persistentInspector: persistentInspector
                        )
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(
                            compactFilters
                                ? "library.workspace.compact"
                                : "library.workspace.expanded"
                        )
                    }
                }
            }
        }
        .onAppear {
            model.refreshRecentSearchQueries()
            reconcileSelection(with: model.filteredSearchResults.map(\.frameID))
            compactPreviewPopoverActive =
                model.libraryWorkspaceNavigation.compactPreviewPresented
        }
        // Mapping in the value position built a fresh identifier array on every
        // body pass. The result list is already Equatable and compares its
        // storage first, so the identifiers are derived only when it changes.
        .onChange(of: model.filteredSearchResults) { _, results in
            reconcileSelection(with: results.map(\.frameID))
        }
        .onChange(of: focusRequest) { _, _ in
            model.libraryWorkspaceNavigation.contentMode = .search
            guard !model.filteredSearchResults.isEmpty else { return }
            if model.libraryWorkspaceNavigation.selectedResultID == nil {
                model.libraryWorkspaceNavigation.selectResult(
                    model.filteredSearchResults.first?.frameID
                )
            }
            resultsFocused = true
        }
        .onChange(of: model.searchQuery) { oldValue, newValue in
            guard oldValue != newValue,
                !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            model.libraryWorkspaceNavigation.contentMode = .search
        }
        .onChange(of: model.shellSearchMode) { _, libraryIsActive in
            if libraryIsActive {
                compactPreviewPopoverActive =
                    model.libraryWorkspaceNavigation.compactPreviewPresented
            } else {
                dismissTransientOverlays()
            }
        }
        .sheet(
            item: libraryDeletionReview,
            onDismiss: {
                model.cancelLibraryDeletionReview()
            }
        ) { review in
            LibraryDeletionReviewSheet(
                review: review,
                isDeleting: model.libraryDeletionInProgress,
                issue: reviewDeletionIssue,
                onDelete: { Task { await model.confirmLibraryDeletion() } },
                onCancel: { model.cancelLibraryDeletionReview() }
            )
        }
    }

    @ViewBuilder
    private func workspace(compactFilters: Bool, persistentInspector: Bool) -> some View {
        if compactFilters {
            resultsWorkspace(compactFilters: true, persistentInspector: false)
        } else {
            HSplitView {
                if showFilterSidebar {
                    VStack(spacing: 0) {
                        LibraryFilterPanel(style: .sidebar)
                    }
                    .frame(
                        minWidth: filterPanelMinimumWidth,
                        idealWidth: filterPanelIdealWidth,
                        maxWidth: filterPanelMaximumWidth
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("library.filters.pane")
                }

                resultsWorkspace(
                    compactFilters: false,
                    persistentInspector: persistentInspector
                )
                .frame(minWidth: resultsMinimumWidth)
                .layoutPriority(1)

                if persistentInspector,
                    model.libraryWorkspaceNavigation.inspectorPanePresented,
                    let selectedResult
                {
                    VStack(spacing: 0) {
                        SearchResultInspector(
                            result: selectedResult,
                            presentation: .pane,
                            interactionEnabled: libraryResultsRemainInteractive
                        ) {
                            openResult(selectedResult)
                        }
                    }
                    .frame(
                        minWidth: inspectorMinimumWidth,
                        idealWidth: inspectorIdealWidth,
                        maxWidth: inspectorMaximumWidth
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("library.inspector.pane")
                }
            }
        }
    }

    private func resultsWorkspace(compactFilters: Bool, persistentInspector: Bool) -> some View {
        GeometryReader { resultsGeometry in
            VStack(spacing: 10) {
                if showsResultsHeader || compactFilters || !showFilterSidebar {
                    resultsHeader(
                        compactFilters: compactFilters,
                        persistentInspector: persistentInspector
                    )
                }
                if let issue = model.librarySearchState.issue,
                    !model.filteredSearchResults.isEmpty
                {
                    HStack(spacing: 8) {
                        Label("Couldn't update results", systemImage: "exclamationmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(SLDesign.warning)
                        Text("Showing results from your previous successful search. \(issue.message)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Button("Try Again") {
                            model.retryLibrarySearch()
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(
                        "Couldn't update results. Showing results from your previous successful search. \(issue.message)"
                    )
                    .accessibilityIdentifier("library.results.update-error")
                }
                resultsList(
                    columnCount: gridColumnCount(
                        forResultsWidth: max(
                            0,
                            resultsGeometry.size.width - (resultsContentHorizontalInset * 2)
                        )
                    )
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.results.workspace")
    }

    private func gridColumnCount(forResultsWidth resultsWidth: CGFloat) -> Int {
        return max(1, Int((resultsWidth + 16) / (minimumCardWidth + 16)))
    }

    private var filterPanelMinimumWidth: CGFloat { 175 }
    private var filterPanelIdealWidth: CGFloat { 205 }
    private var filterPanelMaximumWidth: CGFloat { 280 }
    private var resultsMinimumWidth: CGFloat { 360 }
    private var inspectorMinimumWidth: CGFloat { 270 }
    private var inspectorIdealWidth: CGFloat { 300 }
    private var inspectorMaximumWidth: CGFloat { 420 }
    private var resultsContentHorizontalInset: CGFloat { 12 }
    private var minimumCardWidth: CGFloat { dynamicTypeSize.isAccessibilitySize ? 280 : 220 }

    private func showsInspector(totalWidth: CGFloat) -> Bool {
        !dynamicTypeSize.isAccessibilitySize && totalWidth >= 1_020
    }

    /// Deletion raised from a result reports here, not on the Timeline the user
    /// never opened. Confirmation failures stay inside the open review sheet.
    private var libraryDeletionIssue: LibraryDeletionIssue? {
        guard let issue = model.libraryDeletionIssue, issue.origin == .library else { return nil }
        if case .deletionFailed = issue { return nil }
        return issue
    }

    private var reviewDeletionIssue: LibraryDeletionIssue? {
        guard let issue = model.libraryDeletionIssue,
            issue.origin == .library,
            case .deletionFailed = issue
        else { return nil }
        return issue
    }

    private var libraryDeletionReview: Binding<LibraryDeletionReview?> {
        Binding(
            get: {
                guard model.libraryDeletionReview?.origin == .library else { return nil }
                return model.libraryDeletionReview
            },
            set: { review in
                if review == nil { model.cancelLibraryDeletionReview() }
            }
        )
    }

    private func usesCompactFilters(totalWidth: CGFloat) -> Bool {
        dynamicTypeSize.isAccessibilitySize || totalWidth < 940
    }

    private var showsResultsHeader: Bool {
        !model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.filteredSearchResults.isEmpty
            || model.isSearching
            || model.hasActiveLibrarySearchFilters
    }

    private func clearAllFilters() {
        model.clearAllLibrarySearchFilters()
    }

    private func resultsHeader(compactFilters: Bool, persistentInspector: Bool) -> some View {
        let hasNoCriteria =
            model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.hasActiveLibrarySearchFilters
        let title = hasNoCriteria ? "Search" : "Results"
        return HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .accessibilityLabel(title)
                .accessibilityIdentifier("library.results.title")
            if !model.filteredSearchResults.isEmpty {
                Text(resultCountLabel)
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.45), in: Capsule(style: .continuous))
                    .accessibilityLabel("Result count")
                    .accessibilityValue(resultCountLabel)
                    .accessibilityIdentifier("library.results.count")
            }
            Spacer()
            if model.isSearching, !model.filteredSearchResults.isEmpty {
                ProgressView()
                    .controlSize(.small)
                Text("Updating results")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if resultsFocused,
                !compactFilters,
                !dynamicTypeSize.isAccessibilitySize
            {
                Text("Use the arrow keys to browse. Return opens. Escape returns to search.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            if let selectedResult,
                !persistentInspector
                    || !model.libraryWorkspaceNavigation.inspectorPanePresented
            {
                Button {
                    openResult(selectedResult)
                } label: {
                    Label("Open in Timeline", systemImage: "arrow.forward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!libraryResultsRemainInteractive)
                .help("Open the selected moment in Timeline")
                .accessibilityHint(
                    !libraryResultsRemainInteractive
                        ? "Available when Library results are ready"
                        : "Opens the selected moment in Timeline"
                )
                .accessibilityIdentifier("library.result.open-selected")
            }

            if compactFilters {
                Button {
                    showCompactFilters.toggle()
                } label: {
                    Label(
                        model.activeLibrarySearchFilterCount == 0
                            ? "Filters"
                            : "Filters, \(model.activeLibrarySearchFilterCount) active",
                        systemImage: model.activeLibrarySearchFilterCount == 0
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill"
                    )
                }
                .buttonStyle(.borderless)
                .help("Refine results by content, time, website, application, or session")
                .accessibilityValue(
                    model.activeLibrarySearchFilterCount == 0
                        ? "No filters active"
                        : "\(model.activeLibrarySearchFilterCount) active"
                )
                .accessibilityIdentifier("library.filters.toggle")
                .popover(isPresented: $showCompactFilters, arrowEdge: .top) {
                    LibraryFilterPanel(
                        style: .popover,
                        onChooseDate: {
                            showCompactFilters = false
                            DispatchQueue.main.async {
                                model.openSearchDatePicker(
                                    kind: .date,
                                    origin: .compactFilters
                                )
                            }
                        }
                    )
                }
                .background {
                    Color.clear
                        .popover(
                            isPresented: compactDatePickerPresentation,
                            arrowEdge: .top
                        ) {
                            SearchDatePickerPopover()
                                .environmentObject(model)
                        }
                }
            } else {
                Button {
                    showFilterSidebar.toggle()
                } label: {
                    Label(
                        showFilterSidebar ? "Hide Filters" : "Show Filters",
                        systemImage: "sidebar.leading"
                    )
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(showFilterSidebar ? "Hide Filters" : "Show Filters")
                .accessibilityValue(showFilterSidebar ? "Shown" : "Hidden")
                .accessibilityIdentifier("library.filters.toggle")
            }

            if let selectedResult {
                let inspectorVisible =
                    persistentInspector
                    ? model.libraryWorkspaceNavigation.inspectorPanePresented
                    : model.libraryWorkspaceNavigation.compactPreviewPresented
                Button {
                    if persistentInspector {
                        model.libraryWorkspaceNavigation.inspectorPanePresented.toggle()
                    } else {
                        model.libraryWorkspaceNavigation.compactPreviewPresented.toggle()
                        compactPreviewPopoverActive =
                            model.libraryWorkspaceNavigation.compactPreviewPresented
                    }
                } label: {
                    Label(
                        inspectorVisible ? "Hide Preview" : "Show Preview",
                        systemImage: "sidebar.trailing"
                    )
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(inspectorVisible ? "Hide Preview" : "Show Preview")
                .accessibilityLabel(inspectorVisible ? "Hide Preview" : "Show Preview")
                .accessibilityValue(inspectorVisible ? "Shown" : "Hidden")
                .accessibilityIdentifier("library.result.preview.toggle")
                .popover(
                    isPresented: Binding(
                        get: {
                            !persistentInspector && compactPreviewPopoverActive
                        },
                        set: { isPresented in
                            compactPreviewPopoverActive = isPresented
                            // AppKit dismisses the retained Library popover as
                            // its window yields to Timeline. That transient
                            // dismissal must not erase the user's preview
                            // preference before they return to the Library.
                            if model.shellSearchMode {
                                model.libraryWorkspaceNavigation.compactPreviewPresented =
                                    isPresented
                            }
                        }
                    ),
                    arrowEdge: .top
                ) {
                    SearchResultInspector(
                        result: selectedResult,
                        presentation: .popover,
                        interactionEnabled: libraryResultsRemainInteractive
                    ) {
                        openResult(selectedResult)
                    }
                    .frame(width: 360, height: 500)
                }
            }
        }
        .frame(minHeight: 24)
        .padding(.horizontal, resultsContentHorizontalInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search results")
        .accessibilityValue(resultCountLabel)
        .accessibilityIdentifier("library.results.header")
    }

    private var compactDatePickerPresentation: Binding<Bool> {
        Binding(
            get: {
                model.showSearchDatePicker
                    && model.searchDatePickerOrigin == .compactFilters
            },
            set: { isPresented in
                if !isPresented { model.showSearchDatePicker = false }
            }
        )
    }

    private var resultCountLabel: String {
        model.librarySearchPagePresentation.countLabel
    }

    private var libraryResultsRemainInteractive: Bool {
        LibrarySearchInteractionPolicy.resultsRemainInteractive(
            visibleCount: model.filteredSearchResults.count,
            state: model.librarySearchState
        )
    }

    @ViewBuilder
    private func resultsList(columnCount: Int) -> some View {
        let rows = model.filteredSearchResults
        let priorResultsAreUpdating = model.isSearching && !rows.isEmpty
        let resultsRemainInteractive = LibrarySearchInteractionPolicy.resultsRemainInteractive(
            visibleCount: rows.count,
            state: model.librarySearchState
        )

        ScrollViewReader { scrollProxy in
            ScrollView {
                if rows.isEmpty {
                    LibraryResultStateView(
                        state: resultState,
                        onClearSearch: clearSearchTextAndFocusField,
                        onClearFilters: clearAllFilters,
                        onClearAll: clearAllAndFocusField
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .padding(.horizontal, 16)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: minimumCardWidth, maximum: 360), spacing: 16)],
                        spacing: 18
                    ) {
                        ForEach(rows, id: \.frameID) { result in
                            SearchResultCard(
                                result: result,
                                selected:
                                    model.libraryWorkspaceNavigation.selectedResultID
                                    == result.frameID,
                                keyboardFocused: resultsFocused
                                    && model.libraryWorkspaceNavigation.selectedResultID
                                        == result.frameID,
                                interactionEnabled: resultsRemainInteractive,
                                onSelect: {
                                    model.libraryWorkspaceNavigation.selectResult(result.frameID)
                                    resultsFocused = true
                                },
                                onOpen: { openResult(result) },
                                onDelete: {
                                    Task {
                                        await model.prepareLibraryDeletion(
                                            .moment(frameID: result.frameID),
                                            origin: .library,
                                            title: "Delete This Moment?",
                                            detail: result.libraryDeletionDetail
                                        )
                                    }
                                }
                            )
                            .id(result.frameID)
                        }
                    }
                    .padding(.horizontal, resultsContentHorizontalInset)
                    .padding(.bottom, 20)

                    if model.canLoadMoreLibrarySearchResults {
                        Button("Load More") {
                            model.loadMoreLibrarySearchResults()
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isSearching)
                        .padding(.bottom, 20)
                        .accessibilityHint("Loads more matching moments from this Library search")
                        .accessibilityIdentifier("library.results.load-more")
                    }
                }
            }
            .onChange(of: model.libraryWorkspaceNavigation.selectedResultID) { _, frameID in
                guard let frameID, resultsFocused else { return }
                if reduceMotion {
                    scrollProxy.scrollTo(frameID, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.16)) {
                        scrollProxy.scrollTo(frameID, anchor: .center)
                    }
                }
            }
            .onChange(of: model.shellSearchMode) { _, libraryIsActive in
                guard libraryIsActive,
                    let frameID = model.libraryWorkspaceNavigation.resultViewportAnchorID
                else { return }
                DispatchQueue.main.async {
                    scrollProxy.scrollTo(frameID, anchor: .center)
                }
            }
        }
        .focusable(resultsRemainInteractive)
        .focused($resultsFocused)
        .focusEffectDisabled()
        .accessibilityLabel("Library results")
        .accessibilityValue(
            priorResultsAreUpdating
                ? "Previous results remain available while results update"
                : resultCountLabel
        )
        .accessibilityIdentifier("library.results")
        .onChange(of: resultsFocused) { _, focused in
            guard focused, model.libraryWorkspaceNavigation.selectedResultID == nil else {
                return
            }
            model.libraryWorkspaceNavigation.selectResult(
                model.filteredSearchResults.first?.frameID
            )
        }
        .onMoveCommand { direction in
            guard resultsRemainInteractive else { return }
            moveSelection(direction, columnCount: columnCount)
        }
        .onKeyPress(.return) {
            guard resultsRemainInteractive, let selectedResult else { return .ignored }
            openResult(selectedResult)
            return .handled
        }
        .onExitCommand {
            resultsFocused = false
            model.shellFocusSearch = true
        }
    }

    private var selectedResult: FTSResult? {
        guard let selectedResultID = model.libraryWorkspaceNavigation.selectedResultID else {
            return nil
        }
        return model.filteredSearchResults.first { $0.frameID == selectedResultID }
    }

    private func reconcileSelection(with frameIDs: [Int64]) {
        let oldFrameIDs = previousResultIDs
        previousResultIDs = frameIDs

        model.libraryWorkspaceNavigation.reconcileSelection(
            currentResultIDs: frameIDs,
            previousResultIDs: oldFrameIDs
        )
    }

    private func moveSelection(_ direction: MoveCommandDirection, columnCount: Int) {
        let rows = model.filteredSearchResults
        guard !rows.isEmpty else { return }
        guard let selectedResultID = model.libraryWorkspaceNavigation.selectedResultID,
            let currentIndex = rows.firstIndex(where: { $0.frameID == selectedResultID })
        else {
            model.libraryWorkspaceNavigation.selectResult(rows.first?.frameID)
            return
        }

        let nextIndex: Int
        switch direction {
        case .left:
            nextIndex = max(rows.startIndex, currentIndex - 1)
        case .right:
            nextIndex = min(rows.index(before: rows.endIndex), currentIndex + 1)
        case .up:
            nextIndex = currentIndex >= columnCount ? currentIndex - columnCount : currentIndex
        case .down:
            nextIndex = min(rows.index(before: rows.endIndex), currentIndex + columnCount)
        default:
            return
        }
        model.libraryWorkspaceNavigation.selectResult(rows[nextIndex].frameID)
    }

    private var resultState: LibraryResultState {
        let queryEmpty = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let rows = model.filteredSearchResults

        if !rows.isEmpty { return .content }
        if model.isSearching { return .loading }
        if queryEmpty, !model.hasActiveLibrarySearchFilters { return .idle }
        if model.searchQueryNeedsMoreInput { return .needsMoreInput }
        if model.librarySearchState.issue != nil { return .recoverableError }
        if model.activeLibrarySearchFilterCount > 0 { return .filteredEmpty }
        return .noMatches
    }

    private func clearSearchTextAndFocusField() {
        model.clearLibrarySearch(.text)
        resultsFocused = false
        model.shellFocusSearch = true
    }

    private func clearAllAndFocusField() {
        model.clearLibrarySearch(.all)
        resultsFocused = false
        model.shellFocusSearch = true
    }

    private func openResult(_ result: FTSResult) {
        guard libraryResultsRemainInteractive else { return }
        dismissTransientOverlays()
        model.openSearchResult(result)
    }

    private func dismissTransientOverlays() {
        showCompactFilters = false
        compactPreviewPopoverActive = false
        model.showSearchDatePicker = false
    }
}
