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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
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
                            label: "Screen text",
                            systemImage: "text.viewfinder"
                        )
                        contentFilterRow(
                            .transcripts,
                            label: "Transcripts",
                            systemImage: "waveform"
                        )
                    }
                }

                filterSection("Time") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(AppModel.SearchTimeFilter.allCases) { tf in
                            filterRow(selected: model.searchTimeFilter == tf) {
                                model.setSearchTimeFilter(tf)
                            } label: {
                                Label(tf.label, systemImage: "clock")
                            }
                            .accessibilityIdentifier("library.filter.time.\(tf.rawValue)")
                        }
                        filterRow(selected: exactDateFilterIsActive) {
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
                            Label("\(session.appLabel) session", systemImage: "rectangle.stack")
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        }
                        .accessibilityIdentifier("library.filter.session")
                    }
                }

                if !model.searchResultDomainChips.isEmpty {
                    filterSection("Websites") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.searchResultDomainChips.prefix(8), id: \.domain) { chipInfo in
                                filterRow(selected: model.searchDomainFilter == chipInfo.domain) {
                                    model.setSearchDomainFilter(chipInfo.domain)
                                } label: {
                                    HStack(spacing: 7) {
                                        SLFaviconView(domain: chipInfo.domain, size: 14)
                                        Text(chipInfo.domain).lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                                    }
                                }
                            }
                        }
                    }
                }

                if !model.searchResultAppChips.isEmpty {
                    filterSection("Applications") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(model.searchResultAppChips.prefix(9), id: \.bundleID) { chipInfo in
                                filterRow(selected: model.searchAppFilter == chipInfo.bundleID) {
                                    model.setSearchAppFilter(chipInfo.bundleID)
                                } label: {
                                    HStack(spacing: 7) {
                                        SLAppIconView(bundleID: chipInfo.bundleID, size: 16)
                                        Text(chipInfo.label).lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                                    }
                                }
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
    }

    private var exactDateFilterIsActive: Bool {
        SearchOperatorParser.parse(model.searchQuery).dayStartMs != nil
    }

    private func datePickerPresentation(
        for origin: LibrarySearchDatePickerOrigin
    ) -> Binding<Bool> {
        Binding(
            get: {
                model.showSearchDatePicker && model.searchDatePickerOrigin == origin
            },
            set: { isPresented in
                if !isPresented { model.showSearchDatePicker = false }
            }
        )
    }

    private func filterSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
            HStack(spacing: 7) {
                label()
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .font(.callout)
            .foregroundStyle(selected ? model.accentSwiftUIColor : Color.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? model.accentSwiftUIColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}
