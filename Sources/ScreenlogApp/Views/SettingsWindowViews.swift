import AppKit
import SwiftUI

// MARK: - Settings shell

/// Root for both the SwiftUI `Settings` scene and the app-owned settings window.
/// A real split view keeps selection, keyboard navigation, resizing, and
/// accessibility behavior consistent with other macOS settings windows.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchQuery = ""
    @State private var highlightedAnchor: SettingsAnchor?
    @State private var highlightedRequestID: UUID?
    @State private var destinationFocusRequest: SettingsDestinationFocusRequest?
    @State private var selectedSearchResultID: String?
    @State private var activatedSearchRequest: SettingsNavigationRequest?
    // Do not publish AppModel changes from a native List update.
    @State private var pendingSidebarSelection: SettingsSidebarSelection?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                SettingsSearchField(
                    text: $searchQuery,
                    onSubmit: activateSelectedOrFirstSearchResult,
                    onMoveSelection: moveSearchSelection,
                    onEscape: clearSearch
                )
                .frame(height: 28)
                .padding(.horizontal, SLDesign.space8)
                .padding(.top, SLDesign.space8)
                .padding(.bottom, SLDesign.space8)

                List(selection: sidebarSelection) {
                    if normalizedSearchQuery.isEmpty {
                        ForEach(SettingsSidebarSection.all) { section in
                            Section(section.title) {
                                ForEach(section.items) { item in
                                    Label {
                                        Text(item.title)
                                    } icon: {
                                        Image(systemName: item.systemImage)
                                            .foregroundStyle(.secondary)
                                    }
                                    .tag(SettingsSidebarSelection.section(item))
                                    .accessibilityHint(item.accessibilityHint)
                                    .accessibilityIdentifier("settings.sidebar.\(item.rawValue)")
                                }
                            }
                        }
                    } else if searchResults.isEmpty {
                        Text("No settings found")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("No settings found for \(searchQuery)")
                    } else {
                        Text(
                            "\(searchResults.count) matching \(searchResults.count == 1 ? "result" : "results")"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.search.summary")

                        Section("Search Results") {
                            ForEach(searchResults) { result in
                                Label {
                                    VStack(alignment: .leading, spacing: SLDesign.space4) {
                                        Text(result.title)
                                        Text(result.subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                } icon: {
                                    Image(systemName: result.systemImage)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(SettingsSidebarSelection.searchResult(result.id))
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(result.title)
                                .accessibilityValue(result.subtitle)
                                .accessibilityHint("Show this result in Settings")
                                .accessibilityIdentifier(result.accessibilityIdentifier)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 184, ideal: 208, max: 240)
            .accessibilityLabel("Settings sections and search results")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Divider()
                SettingsSidebarCaptureState(
                    presentation: model.captureStatusPresentation()
                ) { destination in
                    switch destination {
                    case .setup:
                        model.showPermissions(origin: .settings)
                    case .storage:
                        navigate(to: .storageManagement)
                    case .exclusions:
                        navigate(to: .exclusionsWebsites)
                    case .capture:
                        navigate(to: .captureStatus)
                    }
                }
            }
        } detail: {
            settingsDetail
                .buttonStyle(SettingsSecondaryButtonStyle())
                .environment(\.settingsHighlightedAnchor, highlightedAnchor)
                .environment(\.settingsDestinationFocusRequest, destinationFocusRequest)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: SettingsWindowLayout.minimumContentSize.width,
            idealWidth: SettingsWindowLayout.defaultContentSize.width,
            minHeight: SettingsWindowLayout.minimumContentSize.height,
            idealHeight: SettingsWindowLayout.defaultContentSize.height
        )
        .tint(model.accentSwiftUIColor)
        .accentColor(model.accentSwiftUIColor)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.openSearchWindow()
                } label: {
                    Label("Library", systemImage: "books.vertical")
                }
                .labelStyle(.iconOnly)
                .help("Show Library")
                .accessibilityLabel("Show Library")
                .accessibilityIdentifier("navigation.settings.library")

                Button {
                    model.openMainShell(origin: .direct)
                } label: {
                    Label("Timeline", systemImage: "clock")
                }
                .labelStyle(.iconOnly)
                .help("Show Timeline")
                .accessibilityLabel("Show Timeline")
                .accessibilityIdentifier("navigation.settings.timeline")
            }
        }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
        .onExitCommand {
            _ = clearSearch()
        }
        .onChange(of: pendingSidebarSelection) { _, selection in
            guard let selection else { return }
            pendingSidebarSelection = nil
            switch selection {
            case .section(let section):
                model.settingsSelection = section
            case .searchResult(let id):
                guard let result = searchResults.first(where: { $0.id == id }) else { return }
                activate(result)
            }
        }
        .onChange(of: model.settingsSelection) { _, selection in
            if destinationFocusRequest?.anchor.section != selection {
                destinationFocusRequest = nil
            }
        }
        .onChange(of: searchQuery) { _, _ in
            selectedSearchResultID = nil
            // A contextual route clears the search as it arrives. Keep that
            // route's highlight and focus request alive until it is consumed.
            if model.settingsNavigationRequest == nil {
                highlightedAnchor = nil
                highlightedRequestID = nil
                destinationFocusRequest = nil
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var settingsDetail: some View {
        if !normalizedSearchQuery.isEmpty, searchResults.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Label("Settings Search", systemImage: "magnifyingglass")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                Divider()

                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No Settings Found")
                        .font(.title3.weight(.semibold))
                    Text("Try a different word or clear the Settings search.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Clear Search") {
                        searchQuery = ""
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("settings.search.clear")
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("No settings found for \(normalizedSearchQuery)")
                .accessibilityIdentifier("settings.search.empty")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            VStack(spacing: 0) {
                SettingsPaneHeader(item: model.settingsSelection)
                Divider()
                detailScroll
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    @ViewBuilder
    private var detailScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch model.settingsSelection {
                    case .general: GeneralSettingsPane()
                    case .appearance: AppearanceSettingsPane()
                    case .shortcuts: KeyboardShortcutsSettingsPane()
                    case .capture: CaptureSettingsPane()
                    case .privacy:
                        PrivacySettingsPane(
                            openExclusions: { navigate(to: .exclusionsApplications) },
                            openStorage: { navigate(to: .storageManagement) }
                        )
                    case .storage: StorageSettingsPane()
                    case .search: SearchSettingsPane()
                    case .exclusions: ExclusionsSettingsPane()
                    case .integrations: IntegrationsSettingsPane()
                    case .support: SupportSettingsPane()
                    }
                }
                .padding(SLDesign.space24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .id(SettingsScrollTarget.top(model.settingsSelection))
            }
            .onReceive(model.$settingsNavigationRequest.compactMap { $0 }) { request in
                reveal(request, origin: .navigationRequest, with: proxy)
            }
            .onChange(of: activatedSearchRequest) { _, request in
                guard let request else { return }
                reveal(request, origin: .settingsSearch, with: proxy)
            }
            .onChange(of: model.settingsSelection) { _, selection in
                guard model.settingsNavigationRequest?.destination.section != selection,
                    activatedSearchRequest?.destination.section != selection
                else {
                    return
                }
                DispatchQueue.main.async {
                    proxy.scrollTo(SettingsScrollTarget.top(selection), anchor: .top)
                }
            }
        }
    }

    private var searchResults: [SettingsSearchResult] {
        SettingsSearchResult.matching(normalizedSearchQuery)
    }

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sidebarSelection: Binding<SettingsSidebarSelection?> {
        Binding(
            get: {
                if let pendingSidebarSelection { return pendingSidebarSelection }
                if normalizedSearchQuery.isEmpty {
                    return .section(model.settingsSelection)
                }
                return selectedSearchResultID.map(SettingsSidebarSelection.searchResult)
            },
            set: { pendingSidebarSelection = $0 }
        )
    }

    private func activateSelectedOrFirstSearchResult() {
        let result =
            selectedSearchResultID.flatMap { selectedID in
                searchResults.first(where: { $0.id == selectedID })
            }
            ?? searchResults.first
        guard let result else { return }
        activate(result)
    }

    private func moveSearchSelection(_ direction: Int) {
        guard !searchResults.isEmpty else { return }
        let currentIndex = selectedSearchResultID.flatMap { selectedID in
            searchResults.firstIndex(where: { $0.id == selectedID })
        }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = min(max(currentIndex + direction, 0), searchResults.count - 1)
        } else {
            nextIndex = direction < 0 ? searchResults.count - 1 : 0
        }
        selectedSearchResultID = searchResults[nextIndex].id
    }

    private func activate(_ result: SettingsSearchResult) {
        selectedSearchResultID = result.id
        activatedSearchRequest = SettingsNavigationRequest(
            destination: result.destination
        )
    }

    @discardableResult
    private func clearSearch() -> Bool {
        guard !normalizedSearchQuery.isEmpty else { return false }
        searchQuery = ""
        return true
    }

    private func navigate(to destination: SettingsDestination) {
        searchQuery = ""
        model.requestSettingsNavigation(to: destination)
    }

    private func reveal(
        _ request: SettingsNavigationRequest,
        origin: SettingsRevealOrigin,
        with proxy: ScrollViewProxy
    ) {
        if origin == .navigationRequest {
            searchQuery = ""
        }
        model.settingsSelection = request.destination.section
        let anchor = request.destination.anchor
        let target =
            anchor.map(SettingsScrollTarget.anchor)
            ?? SettingsScrollTarget.top(request.destination.section)
        highlightedAnchor = request.focusedElementIdentifier == nil ? anchor : nil
        highlightedRequestID = request.id
        destinationFocusRequest = anchor.map {
            SettingsDestinationFocusRequest(
                id: request.id,
                anchor: $0,
                focusedElementIdentifier: request.focusedElementIdentifier
            )
        }
        DispatchQueue.main.async {
            if reduceMotion {
                proxy.scrollTo(target, anchor: scrollAlignment(for: anchor))
            } else {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(target, anchor: scrollAlignment(for: anchor))
                }
            }
            // Keep the request alive for one additional run-loop turn so a
            // newly selected pane can consume presentation details first.
            if origin == .navigationRequest {
                DispatchQueue.main.async {
                    model.completeSettingsNavigation(request.id)
                }
            }
        }

        guard anchor != nil else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            guard highlightedRequestID == request.id else { return }
            if reduceMotion {
                highlightedAnchor = nil
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    highlightedAnchor = nil
                }
            }
        }
    }

    private func scrollAlignment(for anchor: SettingsAnchor?) -> UnitPoint {
        switch anchor {
        case .exclusionsApplications, .exclusionsWebsites:
            // These destinations begin with an input. Aligning a tall task to
            // its center can place that input above the visible scroll area.
            return .top
        case .some:
            return .center
        case nil:
            return .top
        }
    }
}

private enum SettingsRevealOrigin {
    case navigationRequest
    case settingsSearch
}

private enum SettingsSidebarSelection: Hashable {
    case section(SettingsSidebarItem)
    case searchResult(String)
}

private enum SettingsSidebarCaptureDestination {
    case setup
    case storage
    case exclusions
    case capture
}

private struct SettingsSidebarCaptureState: View {
    let presentation: CaptureStatusPresentation
    let action: (SettingsSidebarCaptureDestination) -> Void

    var body: some View {
        Button {
            action(destination)
        } label: {
            HStack(spacing: SLDesign.space8) {
                Image(systemName: presentation.symbolName)
                    .font(SLDesign.bodyFont)
                    .foregroundStyle(.secondary)
                    .frame(width: SettingsChrome.iconSize)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: SLDesign.space4) {
                    Text(presentation.compactLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(presentation.compactDetail ?? presentation.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(SLDesign.space16)
        .background(.bar)
        .accessibilityLabel(presentation.compactLabel)
        .accessibilityValue(presentation.compactDetail ?? presentation.detail)
        .accessibilityHint(destinationHint)
        .accessibilityIdentifier("settings.sidebar.capture-state")
    }

    private var destination: SettingsSidebarCaptureDestination {
        switch presentation.inspectionDestination {
        case .setup: return .setup
        case .storage, .libraryRecovery: return .storage
        case .websiteExclusions: return .exclusions
        case .capture: return .capture
        }
    }

    private var destinationHint: String {
        switch destination {
        case .setup: return "Open setup for the required macOS permission"
        case .storage: return "Open Storage settings for Library and disk-space options"
        case .exclusions: return "Open Exclusions settings to review website protection"
        case .capture: return "Open Capture settings"
        }
    }
}

private struct SettingsPaneHeader: View {
    let item: SettingsSidebarItem

    var body: some View {
        identity
            .padding(.horizontal, SLDesign.space24)
            .padding(.vertical, SLDesign.space16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.pane.\(item.rawValue)")
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: SLDesign.space4) {
            Text(item.title)
                .font(SLDesign.titleFont)
            Text(item.subtitle)
                .font(SLDesign.metadataFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.subtitle)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("settings.pane.\(item.rawValue).heading")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Chrome tokens

enum SettingsChrome {
    static let cardRadius: CGFloat = 8
    static let iconSize: CGFloat = 24
    static let cardSpacing = SLDesign.space16
    static let sectionSpacing = SLDesign.space24
    static let rowSeparatorInset: CGFloat = 56

}

private struct SettingsHighlightedAnchorKey: EnvironmentKey {
    static let defaultValue: SettingsAnchor? = nil
}

private struct SettingsDestinationFocusRequestKey: EnvironmentKey {
    static let defaultValue: SettingsDestinationFocusRequest? = nil
}

private enum SettingsScrollTarget: Hashable {
    case top(SettingsSidebarItem)
    case anchor(SettingsAnchor)
}

extension EnvironmentValues {
    fileprivate var settingsHighlightedAnchor: SettingsAnchor? {
        get { self[SettingsHighlightedAnchorKey.self] }
        set { self[SettingsHighlightedAnchorKey.self] = newValue }
    }

    var settingsDestinationFocusRequest: SettingsDestinationFocusRequest? {
        get { self[SettingsDestinationFocusRequestKey.self] }
        set { self[SettingsDestinationFocusRequestKey.self] = newValue }
    }
}

private struct SettingsDestinationAnchorModifier: ViewModifier {
    @Environment(\.settingsHighlightedAnchor) private var highlightedAnchor
    @Environment(\.settingsDestinationFocusRequest) private var focusRequest
    @EnvironmentObject private var model: AppModel
    @FocusState private var keyboardFocused: Bool
    @AccessibilityFocusState private var accessibilityFocused: Bool

    let anchor: SettingsAnchor
    let focusesGroup: Bool

    func body(content: Content) -> some View {
        // An anchor represents one vertical Settings section. Giving it an
        // explicit layout contract prevents a ViewBuilder with several root
        // children from inheriting overlay semantics and collapsing those
        // children on top of one another.
        VStack(alignment: .leading, spacing: SettingsChrome.cardSpacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            if highlightedAnchor == anchor {
                RoundedRectangle(cornerRadius: SettingsChrome.cardRadius)
                    .strokeBorder(model.accentSwiftUIColor.opacity(0.5), lineWidth: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .id(SettingsScrollTarget.anchor(anchor))
        // A programmatic deep-link needs a real focus destination, not only a
        // scroll position. Ordinary Settings browsing does not gain another
        // keyboard stop because only the requested group becomes focusable.
        .focusable(
            focusesGroup && focusRequest?.anchor == anchor
                && focusRequest?.focusedElementIdentifier == nil
        )
        .focused($keyboardFocused)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(anchor.accessibilityLabel)
        .accessibilityFocused($accessibilityFocused)
        .accessibilityIdentifier(anchor.accessibilityIdentifier)
        .onAppear {
            focusIfRequested(focusRequest)
        }
        .onChange(of: focusRequest) { _, request in
            focusIfRequested(request)
        }
    }

    private func focusIfRequested(_ request: SettingsDestinationFocusRequest?) {
        guard request?.anchor == anchor,
            request?.focusedElementIdentifier == nil
        else { return }
        // Scrolling and pane replacement settle on the next run-loop turn.
        // Move both keyboard and assistive-technology focus afterwards so the
        // destination is immediately understandable without hunting for it.
        DispatchQueue.main.async {
            if focusesGroup {
                keyboardFocused = true
            }
            accessibilityFocused = true
        }
    }
}

extension View {
    func settingsDestinationAnchor(
        _ anchor: SettingsAnchor,
        focusesGroup: Bool = true
    ) -> some View {
        modifier(
            SettingsDestinationAnchorModifier(
                anchor: anchor,
                focusesGroup: focusesGroup
            )
        )
    }
}

// MARK: - Grouped form helpers

/// The shared vertical rhythm for a Settings destination made from several
/// titled groups. Use this instead of repeating pane-local `VStack` geometry.
struct SettingsSectionStack<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.sectionSpacing) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Native grouped container for a related set of preferences.
struct SettingsCard<Content: View>: View {
    var padding: CGFloat = SLDesign.space16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: SettingsChrome.cardRadius)
            )
    }
}

/// A compact form row with a quiet symbol and a trailing native control.
struct SettingsCardRow<Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let icon: String
    var iconColor: Color = .secondary
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stackedContent
            } else {
                ViewThatFits(in: .horizontal) {
                    horizontalContent
                    stackedContent
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var horizontalContent: some View {
        HStack(alignment: .center, spacing: SLDesign.space16) {
            identity
            trailingControl
        }
    }

    private var stackedContent: some View {
        VStack(alignment: .leading, spacing: SLDesign.space8) {
            identity
            trailingControl
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: SLDesign.space16) {
            Image(systemName: icon)
                .font(SLDesign.bodyFont)
                .foregroundStyle(iconColor)
                .frame(width: SettingsChrome.iconSize, height: SettingsChrome.iconSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: SLDesign.space4) {
                Text(title)
                    .font(SLDesign.bodyFont.weight(.medium))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(SLDesign.metadataFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
    }

    private var trailingControl: some View {
        trailing()
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// A compact standalone preference row. Bordered groups are reserved for
/// settings that are meaningfully related rather than decorating every row.
struct SettingsRow<Trailing: View>: View {
    let icon: String
    var iconColor: Color = .secondary
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        SettingsCardRow(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle) {
            trailing()
        }
        .padding(.horizontal, SLDesign.space4)
        .padding(.vertical, SLDesign.space8)
    }
}

/// Compact key or unassigned-shortcut badge.
struct SettingsShortcutBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(SLDesign.metadataFont.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        text
            .replacingOccurrences(of: "Command-", with: "Command ")
            .replacingOccurrences(of: "Option-", with: "Option ")
            .replacingOccurrences(of: "Control-", with: "Control ")
            .replacingOccurrences(of: "Shift-", with: "Shift ")
    }
}

/// Secondary actions retain native button behavior without competing with
/// selected controls and explicitly prominent primary actions.
private struct SettingsSecondaryButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.bordered)
            .tint(.primary)
    }
}
