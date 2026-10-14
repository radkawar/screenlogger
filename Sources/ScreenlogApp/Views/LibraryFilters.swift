import ScreenlogCore
import SwiftUI

/// Progressive Library filters. Time is always available; app and site filters
/// appear only when the current result set makes them useful.
struct LibraryFilterPanel: View {
    enum Style {
        case sidebar
        case popover
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let style: Style
    var onChooseDate: (() -> Void)?
    @State private var showsAllWebsites = false
    @State private var showsAllApplications = false

    init(style: Style, onChooseDate: (() -> Void)? = nil) {
        self.style = style
        self.onChooseDate = onChooseDate
    }

    @ViewBuilder
    var body: some View {
        switch style {
        case .sidebar:
            filterContent
                .padding(.top, 3)
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("library.filters")
        case .popover:
            filterContent
                .padding(16)
                .frame(
                    width: dynamicTypeSize.isAccessibilitySize ? 360 : 310,
                    height: dynamicTypeSize.isAccessibilitySize ? 520 : 430,
                    alignment: .top
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("library.filters")
        }
    }

    private var filterContent: some View {
        // Every facet list walks the whole scoped hit set, and the operator
        // parse walks the query. Reading each one once per pass keeps a panel
        // redraw off four full passes over the results and a duplicate parse.
        let domainChips = model.searchResultDomainChips
        let appChips = model.searchResultAppChips
        let parsedQuery = SearchOperatorParser.parse(model.searchQuery)
        return ScrollView {
            VStack(alignment: .leading, spacing: SLDesign.space24) {
                HStack(spacing: 8) {
                    Text("Filters")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if model.activeLibrarySearchFilterCount > 0 {
                        Button("Clear") { clearAllFilters() }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(model.accentSwiftUIColor)
                            .accessibilityIdentifier("library.filters.clear")
                    }
                }

                filterSection("Content") {
                    VStack(alignment: .leading, spacing: 2) {
                        contentFilterRow(
                            .all,
                            label: "All content",
                            systemImage: "text.magnifyingglass"
                        )
                        contentFilterRow(
                            .screenText,
                            label: "Screens",
                            systemImage: "text.viewfinder"
                        )
                        contentFilterRow(
                            .transcripts,
                            label: "Transcripts",
                            systemImage: "waveform"
                        )
                    }
                }

                filterSection("When") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(AppModel.SearchTimeFilter.allCases) { tf in
                            filterRow(selected: model.searchTimeFilter == tf) {
                                model.setSearchTimeFilter(tf)
                            } label: {
                                Text(tf.label.capitalized)
                            }
                            .accessibilityIdentifier("library.filter.time.\(tf.rawValue)")
                        }
                        filterRow(selected: parsedQuery.dayStartMs != nil) {
                            if let onChooseDate {
                                onChooseDate()
                            } else {
                                model.openSearchDatePicker(kind: .date, origin: .sidebar)
                            }
                        } label: {
                            Label("Choose Date...", systemImage: "calendar")
                        }
                        .accessibilityIdentifier("library.filter.date.choose")
                        .popover(
                            isPresented: datePickerPresentation(for: .sidebar),
                            arrowEdge: .trailing
                        ) {
                            SearchDatePickerPopover()
                                .environmentObject(model)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if model.canFilterSearchBySession, let session = model.selectedSession {
                    filterSection("Context") {
                        filterRow(selected: model.searchSessionScoped) {
                            model.setSearchSessionScoped(!model.searchSessionScoped)
                        } label: {
                            Label(session.displayTitle, systemImage: "rectangle.stack")
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        }
                        .accessibilityIdentifier("library.filter.session")
                    }
                }

                if !domainChips.isEmpty || !appChips.isEmpty {
                    Text("Where")
                        .font(SLDesign.sectionFont)
                }
                if !domainChips.isEmpty {
                    filterSection("Websites") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(domainChips.prefix(showsAllWebsites ? domainChips.count : 3)), id: \.domain) { chipInfo in
                                filterRow(selected: model.searchDomainFilter == chipInfo.domain) {
                                    model.setSearchDomainFilter(chipInfo.domain)
                                } label: {
                                    HStack(spacing: 7) {
                                        SLFaviconView(domain: chipInfo.domain, size: 14)
                                        Text(chipInfo.domain).lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                                    }
                                }
                            }
                            if domainChips.count > 3 {
                                Button(showsAllWebsites ? "Show Less" : "Show All Websites") {
                                    showsAllWebsites.toggle()
                                }
                                .buttonStyle(.plain)
                                .font(SLDesign.metadataFont)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !appChips.isEmpty {
                    filterSection("Applications") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(appChips.prefix(showsAllApplications ? appChips.count : 3)), id: \.bundleID) { chipInfo in
                                filterRow(selected: model.searchAppFilter == chipInfo.bundleID) {
                                    model.setSearchAppFilter(chipInfo.bundleID)
                                } label: {
                                    HStack(spacing: 7) {
                                        SLAppIconView(bundleID: chipInfo.bundleID, size: 16)
                                        Text(chipInfo.label).lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                                    }
                                }
                            }
                            if appChips.count > 3 {
                                Button(showsAllApplications ? "Show Less" : "Show All Applications") {
                                    showsAllApplications.toggle()
                                }
                                .buttonStyle(.plain)
                                .font(SLDesign.metadataFont)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func clearAllFilters() {
        model.clearAllLibrarySearchFilters()
    }

    private func contentFilterRow(
        _ content: LibrarySearchContent,
        label: String,
        systemImage: String
    ) -> some View {
        filterRow(selected: model.searchContent == content) {
            model.setSearchContent(content)
        } label: {
            Label(label, systemImage: systemImage)
        }
        .accessibilityIdentifier("library.filter.content.\(content.rawValue)")
        .disabled(!model.canSelectSearchContent(content))
        .help(
            model.canSelectSearchContent(content)
                ? label
                : "Enable text sources in Search Settings to search transcripts."
        )
    }

    private func datePickerPresentation(
        for origin: LibrarySearchDatePickerOrigin
    ) -> Binding<Bool> {
        Binding(
            get: {
                model.showSearchDatePicker && model.searchDatePickerOrigin == origin
            },
            set: { isPresented in
                if !isPresented, model.showSearchDatePicker, model.searchDatePickerOrigin == origin {
                    model.showSearchDatePicker = false
                }
            }
        )
    }

    private func filterSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SLDesign.space8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func filterRow<Label: View>(
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            HStack(spacing: SLDesign.space8) {
                label()
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .font(.callout)
            .foregroundStyle(selected ? model.accentSwiftUIColor : Color.primary)
            .padding(.horizontal, SLDesign.space8)
            .padding(.vertical, SLDesign.space4)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(
                selected ? model.accentSwiftUIColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: SLDesign.thumbRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}
