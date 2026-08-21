import AppKit
import ScreenlogCore
import SwiftUI

/// Screenlogger Library: fast query, progressive refinements, and visual results.
struct FloatingSearchView: View {
    @EnvironmentObject var model: AppModel
    @State private var searchFocused = false
    @State private var focusResultsRequest = 0
    @State private var selectedSuggestionID: String?
    @State private var presentedSearchText = ""
    @State private var committedOperatorValues: [SearchOperatorKind: String] = [:]
    @State private var lastRawQueryWrittenByEditor: String?
    @State private var suppressAutocompleteUntilEditorChanges = false
    @State private var assistantHandoffRequest: AssistantHandoffSheetRequest?
    @State private var assistantHandoffValidationMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .zIndex(3)

            Divider()

            if let issue = model.captureIssue {
                SLCaptureIssueBanner(issue: issue, context: "library")
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            // Actions taken here, such as deleting a found moment, previously
            // confirmed only into a status string no view rendered. The notice
            // channel is shared with the Timeline window; the type keeps its
            // original name.
            if let notice = model.timelineNotice {
                TimelineNoticeView(
                    notice: notice,
                    onDismiss: { model.dismissTimelineNotice() }
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            SearchPane(focusRequest: focusResultsRequest)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.bottom, 12)
        .frame(
            minWidth: SLDesign.workspaceMinimumWidth,
            minHeight: SLDesign.workspaceMinimumHeight
        )
        .tint(model.accentSwiftUIColor)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.showSearchOperatorMenu = false
            synchronizePresentationFromRawQuery(model.searchQuery)
            searchFocused = true
            model.refreshIntegrationSettings(automatic: true)
        }
        .onChange(of: model.shellFocusSearch) { _, focus in
            if focus {
                searchFocused = true
            } else if model.showSearchDatePicker || !model.shellSearchMode {
                searchFocused = false
            }
        }
        .onChange(of: model.showSearchOperatorMenu) { _, isVisible in
            if !isVisible { selectedSuggestionID = nil }
        }
        .onChange(of: model.showSearchDatePicker) { wasVisible, isVisible in
            if wasVisible, !isVisible, model.shellSearchMode {
                restoreSearchFocus(reopeningAutocomplete: false)
            }
        }
        .onChange(of: model.searchAutocompleteRows.map(\.id)) { _, rowIDs in
            guard let selectedSuggestionID else { return }
            if !rowIDs.contains(selectedSuggestionID) {
                self.selectedSuggestionID = nil
            }
        }
        .onExitCommand {
            handleExitCommand()
        }
        .sheet(item: $assistantHandoffRequest) { request in
            AssistantHandoffSheet(request: request)
                .environmentObject(model)
        }
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchInput

            if let assistantHandoffValidationMessage {
                Label(assistantHandoffValidationMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("library.assistant.validation")
            }

            if hasPresentedOperatorChips {
                SearchActiveOperatorChips(
                    values: committedOperatorValues,
                    compact: true,
                    excluding: draftedOperatorKinds,
                    onRemove: removeCommittedOperator
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("library.search.operators")
                .padding(.horizontal, 2)
            }

            if model.searchSessionScoped {
                sessionScopeRow
                    .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: 680)
        .popover(isPresented: searchDatePickerPresentation, arrowEdge: .top) {
            SearchDatePickerPopover()
                .environmentObject(model)
        }
    }

    private var searchInput: some View {
        HStack(spacing: 8) {
            LibrarySearchField(
                text: presentedSearchBinding,
                isFocused: $searchFocused,
                placeholder: searchPlaceholder,
                isEnabled: model.libraryStartupIssue == nil,
                onKeyEquivalent: handleSearchKeyEquivalent,
                onSubmit: submitSearch,
                onMoveSelection: moveSearchSelection,
                onTab: moveAutocompleteSelectionForTab,
                onDeleteWhenEmpty: removeLastCommittedOperator,
                onEscape: handleSearchFieldEscape
            )
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
            .onChange(of: model.searchQuery) { _, query in
                assistantHandoffValidationMessage = nil
                synchronizePresentedText(afterRawQueryChangedTo: query)
            }
            .onChange(of: searchFocused) { _, focused in
                model.shellFocusSearch = focused
                if focused {
                    if suppressAutocompleteUntilEditorChanges {
                        model.showSearchOperatorMenu = false
                    } else {
                        model.refreshSearchAutocomplete(for: presentedSearchText)
                    }
                } else {
                    commitRecognizedOperatorDrafts()
                    model.showSearchOperatorMenu = false
                }
            }
            .overlay(alignment: .topLeading) {
                if model.showSearchOperatorMenu, !model.searchAutocompleteRows.isEmpty {
                    SearchAutocompleteMenu(
                        selectedRowID: $selectedSuggestionID,
                        onApply: applyAutocompleteRow
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: autocompleteMenuHeight, alignment: .top)
                    .offset(y: 34)
                    .accessibilitySortPriority(2)
                }
            }

            if LibraryAssistantAskPolicy.isPrimaryControlVisible(hasQuery: hasAssistantQuery) {
                Button {
                    presentAssistantHandoff()
                } label: {
                    Label("Ask Assistant", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize()
                .disabled(model.libraryStartupIssue != nil)
                .help(
                    "Ask an Assistant (\(model.keyboardShortcutDisplayLabel(for: .askAssistant)))"
                )
                .accessibilityHint("Reviews the exact search context before opening an assistant")
                .accessibilityIdentifier("library.assistant.open")
            }
        }
        .zIndex(3)
    }

    private var autocompleteMenuHeight: CGFloat {
        let rows = model.searchAutocompleteRows
        var sectionKinds = Set<String>()
        for row in rows {
            switch row {
            case .op: sectionKinds.insert("filters")
            case .site: sectionKinds.insert("websites")
            case .app: sectionKinds.insert("applications")
            case .dateValue, .pickDate: sectionKinds.insert("dates")
            }
        }
        let contentHeight = CGFloat(rows.count * 48 + sectionKinds.count * 24 + 10)
        return min(300, max(72, contentHeight))
    }

    private func handleSearchKeyEquivalent(_ event: NSEvent) -> Bool {
        guard let binding = model.keyboardShortcutBinding(for: .askAssistant),
            binding.matches(event)
        else { return false }
        presentAssistantHandoff()
        return true
    }

    private func submitSearch() {
        if applySelectedAutocompleteRow() { return }
        commitRecognizedOperatorDrafts()
        model.showSearchOperatorMenu = false
        model.startLibrarySearch()
    }

    private func moveSearchSelection(_ direction: Int) -> Bool {
        if moveAutocompleteSelection(by: direction) { return true }
        guard direction > 0, !model.filteredSearchResults.isEmpty else { return false }
        searchFocused = false
        focusResultsRequest &+= 1
        return true
    }

    private func removeLastCommittedOperator() -> Bool {
        guard presentedSearchText.isEmpty,
            let kind = SearchOperatorKind.allCases.reversed().first(where: {
                committedOperatorValues[$0] != nil
            })
        else { return false }
        removeCommittedOperator(kind)
        return true
    }

    private func handleSearchFieldEscape() -> Bool {
        if model.showSearchOperatorMenu {
            selectedSuggestionID = nil
            model.showSearchOperatorMenu = false
            return true
        }
        if !presentedSearchText.isEmpty {
            clearSearchTextAndRestoreFocus()
            return true
        }
        SearchWindowController.shared.hide()
        return true
    }

    private var searchPlaceholder: String {
        if model.libraryStartupIssue != nil {
            return "Library unavailable"
        }
        if !committedOperatorValues.isEmpty || model.searchSessionScoped {
            return "Add search terms..."
        }
        return "Search your screen history..."
    }

    private var searchDatePickerPresentation: Binding<Bool> {
        Binding(
            get: {
                model.showSearchDatePicker && model.searchDatePickerOrigin == .search
            },
            set: { isPresented in
                if !isPresented { model.showSearchDatePicker = false }
            }
        )
    }

    private var sessionScopeRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack.fill")
                    .accessibilityHidden(true)
                Text("Current Session")
                    .fontWeight(.semibold)
                if let session = model.selectedSession {
                    Text(session.appLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(model.accentSwiftUIColor)
            .background(model.accentSwiftUIColor.opacity(0.12), in: Capsule(style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current Session")
            .accessibilityValue(sessionScopeAccessibilityValue)
            .accessibilityIdentifier("library.search.scope.session")

            Spacer(minLength: 4)

            Button {
                model.setSearchSessionScoped(false)
                searchFocused = true
                model.shellFocusSearch = true
            } label: {
                Label("Search All Library", systemImage: "books.vertical")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Remove the current-session limit and search your entire Library")
            .accessibilityHint("Removes the current-session search limit")
            .accessibilityIdentifier("library.search.scope.all-library")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.search.scope")
    }

    private var sessionScopeAccessibilityValue: String {
        guard let session = model.selectedSession else {
            return "Search limited to the Timeline session"
        }
        return "Search limited to the \(session.appLabel) session"
    }

    private func handleExitCommand() {
        if model.showSearchDatePicker {
            model.showSearchDatePicker = false
        } else if model.showSearchOperatorMenu {
            selectedSuggestionID = nil
            model.showSearchOperatorMenu = false
            restoreSearchFocus()
        } else {
            SearchWindowController.shared.hide()
        }
    }

    private func restoreSearchFocus(reopeningAutocomplete: Bool = true) {
        suppressAutocompleteUntilEditorChanges = !reopeningAutocomplete
        model.shellFocusSearch = false
        DispatchQueue.main.async {
            model.shellFocusSearch = true
        }
    }

    private func clearSearchTextAndRestoreFocus() {
        selectedSuggestionID = nil
        presentedSearchText = ""
        lastRawQueryWrittenByEditor = nil
        model.clearLibrarySearch(.text)
        DispatchQueue.main.async {
            searchFocused = true
            model.shellFocusSearch = true
        }
    }

    private var hasAssistantQuery: Bool {
        (try? model.buildLibraryAssistantHandoffPrompt()) != nil
    }

    private func presentAssistantHandoff() {
        assistantHandoffValidationMessage = nil
        commitRecognizedOperatorDrafts()

        guard !model.searchQueryNeedsMoreInput else {
            assistantHandoffValidationMessage =
                "Finish the search word or filter before asking an assistant."
            return
        }

        let prompt: LibraryAssistantHandoffPrompt
        do {
            prompt = try model.buildLibraryAssistantHandoffPrompt()
        } catch {
            assistantHandoffValidationMessage =
                "Enter a search or add a filter before asking an assistant."
            return
        }

        let destinations = model.assistantHandoffDestinations()
        if destinations.isEmpty, model.integrationRefreshIsActive {
            assistantHandoffValidationMessage =
                "Checking Assistant Connections... Try again in a moment."
            return
        }

        switch LibraryAssistantAskPolicy.resolve(
            hasQuery: true,
            connectionCount: destinations.count
        ) {
        case .hidden:
            return
        case .openIntegrations:
            let focusedIdentifier = model.assistantSettingsRecoveryTarget().map {
                "settings.integration.\($0.rawValue)"
            }
            model.requestSettingsNavigation(
                to: .integrationsAssistantConnections,
                focusedElementIdentifier: focusedIdentifier
            )
            model.openProductSettings()
            return
        case .openHandoff:
            break
        }

        selectedSuggestionID = nil
        model.showSearchOperatorMenu = false
        assistantHandoffRequest = AssistantHandoffSheetRequest(
            prompt: prompt,
            destinations: destinations,
            decision: model.assistantHandoffRoutingDecision(for: destinations)
        )
    }

    private func removeCommittedOperator(_ kind: SearchOperatorKind) {
        committedOperatorValues[kind] = nil
        writeComposedRawQuery()
        restoreSearchFocus(reopeningAutocomplete: false)
    }

    private func moveAutocompleteSelection(by delta: Int) -> Bool {
        let rows = model.searchAutocompleteRows
        guard model.showSearchOperatorMenu, !rows.isEmpty else { return false }

        let nextIndex: Int
        if let selectedSuggestionID,
            let current = rows.firstIndex(where: { $0.id == selectedSuggestionID })
        {
            // Down from the final suggestion continues into the current result
            // set. Returning false lets the field's Down Arrow handler perform
            // that focus handoff; Tab keeps its separate native traversal path.
            if delta > 0, current == rows.index(before: rows.endIndex) {
                return false
            }
            nextIndex = min(max(rows.startIndex, current + delta), rows.index(before: rows.endIndex))
        } else {
            nextIndex = delta < 0 ? rows.index(before: rows.endIndex) : rows.startIndex
        }
        selectedSuggestionID = rows[nextIndex].id
        return true
    }

    private func moveAutocompleteSelectionForTab(backward: Bool) -> Bool {
        let rows = model.searchAutocompleteRows
        guard model.showSearchOperatorMenu, !rows.isEmpty else { return false }

        if let selectedSuggestionID,
            let current = rows.firstIndex(where: { $0.id == selectedSuggestionID })
        {
            if backward {
                guard current > rows.startIndex else {
                    self.selectedSuggestionID = nil
                    return false
                }
                self.selectedSuggestionID = rows[rows.index(before: current)].id
            } else {
                let next = rows.index(after: current)
                guard next < rows.endIndex else {
                    self.selectedSuggestionID = nil
                    return false
                }
                self.selectedSuggestionID = rows[next].id
            }
        } else {
            guard !backward else { return false }
            selectedSuggestionID = rows[rows.startIndex].id
        }
        return true
    }

    private func applySelectedAutocompleteRow() -> Bool {
        guard model.showSearchOperatorMenu,
            let selectedSuggestionID,
            let row = model.searchAutocompleteRows.first(where: { $0.id == selectedSuggestionID })
        else { return false }
        applyAutocompleteRow(row)
        return true
    }

    private func applyAutocompleteRow(_ row: SearchAutocompleteRow) {
        selectedSuggestionID = nil

        switch row {
        case .op(let kind):
            presentedSearchText = SearchOperatorParser.insertOperator(
                kind,
                into: presentedSearchText
            )
            if kind == .date || kind == .before || kind == .since {
                model.searchDatePickerKind = kind
            }
            writeComposedRawQuery()
            model.enterShellSearch()
            model.refreshSearchAutocomplete(for: presentedSearchText)
        case .app, .site, .dateValue:
            model.applyAutocompleteRow(row)
            synchronizePresentationFromRawQuery(model.searchQuery)
            model.refreshSearchAutocomplete(for: presentedSearchText)
        case .pickDate:
            model.applyAutocompleteRow(row)
        }

        if case .pickDate = row {
            searchFocused = false
            model.shellFocusSearch = false
        } else {
            DispatchQueue.main.async {
                searchFocused = true
                model.shellFocusSearch = true
            }
        }
    }

    private var presentedSearchBinding: Binding<String> {
        Binding(
            get: { presentedSearchText },
            set: { newValue in
                suppressAutocompleteUntilEditorChanges = false
                presentedSearchText = newValue
                writeComposedRawQuery(from: newValue)

                var autocompleteInput = newValue
                if newValue.last?.isWhitespace == true,
                    !draftedOperatorKinds(in: newValue).isEmpty,
                    hasBalancedQuotes(in: newValue)
                {
                    autocompleteInput = commitRecognizedOperatorDrafts(in: newValue)
                }
                // This binding is written only by the native editor. Starting
                // its bounded debounce here avoids relying on SwiftUI to
                // distinguish a rapid AppKit edit from a model-owned rewrite.
                model.scheduleSearchDebounced(autocompleteInput: autocompleteInput)
            }
        )
    }

    private var draftedOperatorKinds: [SearchOperatorKind] {
        draftedOperatorKinds(in: presentedSearchText)
    }

    private func draftedOperatorKinds(in editorText: String) -> [SearchOperatorKind] {
        SearchOperatorKind.allCases.filter { kind in
            editorText.range(
                of: #"(?i)\b\#(kind.rawValue):"#,
                options: .regularExpression
            ) != nil
        }
    }

    private var hasPresentedOperatorChips: Bool {
        SearchOperatorKind.allCases.contains { kind in
            committedOperatorValues[kind] != nil && !draftedOperatorKinds.contains(kind)
        }
    }

    private func composeRawQuery(from editorText: String) -> String {
        var operatorTokens: [String] = []
        let editorDraftKinds = Set(draftedOperatorKinds(in: editorText))

        for kind in SearchOperatorKind.allCases {
            guard !editorDraftKinds.contains(kind),
                let value = committedOperatorValues[kind]
            else { continue }
            operatorTokens.append(operatorToken(kind, value: value))
        }

        let operatorPrefix = operatorTokens.joined(separator: " ")
        guard !operatorPrefix.isEmpty else { return editorText }
        guard !editorText.isEmpty else { return operatorPrefix }
        return operatorPrefix + " " + editorText
    }

    private func operatorToken(_ kind: SearchOperatorKind, value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeValue = value.contains(where: \.isWhitespace) ? "\"\(value)\"" : value
        return kind.prefix + safeValue
    }

    private func hasBalancedQuotes(in text: String) -> Bool {
        text.reduce(into: 0) { count, character in
            if character == "\"" { count += 1 }
        }.isMultiple(of: 2)
    }

    private func writeComposedRawQuery(from editorText: String? = nil) {
        let rawQuery = composeRawQuery(from: editorText ?? presentedSearchText)
        // AppKit can report the same editor value more than once before
        // SwiftUI delivers the corresponding model change. Keep the routing
        // marker alive until `onChange` consumes it, or the final keystroke can
        // lose both autocomplete and the debounced Library query.
        guard rawQuery != model.searchQuery else { return }
        lastRawQueryWrittenByEditor = rawQuery
        model.searchQuery = rawQuery
    }

    private func synchronizePresentedText(afterRawQueryChangedTo query: String) {
        if query == lastRawQueryWrittenByEditor {
            lastRawQueryWrittenByEditor = nil
            return
        }
        synchronizePresentationFromRawQuery(query)
    }

    private func synchronizePresentationFromRawQuery(_ rawQuery: String) {
        lastRawQueryWrittenByEditor = nil
        let recognizedValues = recognizedOperatorValues(
            from: SearchOperatorParser.parse(rawQuery)
        )
        committedOperatorValues = recognizedValues
        presentedSearchText = editorText(
            removing: recognizedValues,
            from: rawQuery
        )
    }

    @discardableResult
    private func commitRecognizedOperatorDrafts(in editorText: String? = nil) -> String {
        let editorText = editorText ?? presentedSearchText
        let recognizedValues = recognizedOperatorValues(
            from: SearchOperatorParser.parse(editorText)
        )
        guard !recognizedValues.isEmpty else {
            writeComposedRawQuery(from: editorText)
            return editorText
        }

        for (kind, value) in recognizedValues {
            committedOperatorValues[kind] = value
        }
        let remainingText = self.editorText(
            removing: recognizedValues,
            from: editorText
        )
        presentedSearchText = remainingText
        writeComposedRawQuery(from: remainingText)
        return remainingText
    }

    private func recognizedOperatorValues(
        from parsed: ParsedSearchQuery
    ) -> [SearchOperatorKind: String] {
        var values: [SearchOperatorKind: String] = [:]

        if let value = parsed.rawApp ?? parsed.appFilter,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            values[.app] = value
        }
        if let value = parsed.rawSite ?? parsed.siteFilter,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            values[.site] = value
        }
        if let value = parsed.rawDate, parsed.dayStartMs != nil {
            values[.date] = value
        }
        if let value = parsed.rawBefore, parsed.beforeMs != nil {
            values[.before] = value
        }
        if let value = parsed.rawSince, parsed.sinceMs != nil {
            values[.since] = value
        }

        return values
    }

    private func editorText(
        removing recognizedValues: [SearchOperatorKind: String],
        from rawQuery: String
    ) -> String {
        var editorText = rawQuery
        for kind in SearchOperatorKind.allCases where recognizedValues[kind] != nil {
            editorText = SearchOperatorParser.removeOperator(kind, from: editorText)
        }
        return editorText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

/// Leading location marker hosted by the native Library window toolbar.
struct LibraryToolbarLocationView: View {
    var body: some View {
        Label("Library", systemImage: "books.vertical")
            .labelStyle(.titleAndIcon)
            .font(.headline)
            .foregroundStyle(.primary)
            .fixedSize()
            .accessibilityIdentifier("library.location")
    }
}

/// State-aware capture status hosted by AppKit's toolbar. Window destinations
/// are separate native toolbar items so they keep stable alignment.
struct LibraryToolbarActionsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            captureStatus(labelStyle: .titleAndIcon)
                .fixedSize(horizontal: true, vertical: false)
            captureStatus(labelStyle: .iconOnly)
                .fixedSize(horizontal: true, vertical: false)
        }
        .tint(model.accentSwiftUIColor)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.chrome.toolbar-actions")
    }

    @ViewBuilder
    private func captureStatus(labelStyle: ToolbarLabelStyle) -> some View {
        if labelStyle == .titleAndIcon {
            SLCaptureStatusToolbarView(
                setupOrigin: .library,
                accessibilityIdentifier: "library.capture.status"
            )
            .labelStyle(.titleAndIcon)
        } else {
            SLCaptureStatusToolbarView(
                setupOrigin: .library,
                accessibilityIdentifier: "library.capture.status"
            )
            .labelStyle(.iconOnly)
        }
    }

    private enum ToolbarLabelStyle: Equatable {
        case titleAndIcon
        case iconOnly
    }

}
