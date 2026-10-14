import ScreenlogCore
import SwiftUI

enum LibrarySearchDatePickerOrigin: Equatable {
    case search
    case sidebar
    case compactFilters
}

struct SearchActiveOperatorChips: View {
    @EnvironmentObject var model: AppModel
    let values: [SearchOperatorKind: String]
    var compact: Bool = false
    var excluding: [SearchOperatorKind] = []
    let onRemove: (SearchOperatorKind) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: compact ? 4 : 6) {
                if !excluding.contains(.app), let app = values[.app] {
                    let bid = resolveBundleID(for: app)
                    dismissibleChip(
                        kind: .app,
                        label: app,
                        filterName: "Application",
                        systemImage: "app.badge",
                        bundleID: bid
                    ) {
                        onRemove(.app)
                    }
                }
                if !excluding.contains(.site), let site = values[.site] {
                    dismissibleChip(
                        kind: .site,
                        label: site,
                        filterName: "Website",
                        systemImage: "globe",
                        domain: site
                    ) {
                        onRemove(.site)
                    }
                }
                if !excluding.contains(.date), let date = values[.date] {
                    dismissibleChip(
                        kind: .date,
                        label: Self.localizedDateToken(date),
                        filterName: "Date",
                        systemImage: "calendar"
                    ) {
                        onRemove(.date)
                    }
                }
                if !excluding.contains(.since), let since = values[.since] {
                    dismissibleChip(
                        kind: .since,
                        label: "since \(Self.localizedDateToken(since))",
                        filterName: "Since date",
                        systemImage: "calendar.badge.plus"
                    ) {
                        onRemove(.since)
                    }
                }
                if !excluding.contains(.before), let before = values[.before] {
                    dismissibleChip(
                        kind: .before,
                        label: "before \(Self.localizedDateToken(before))",
                        filterName: "Before date",
                        systemImage: "calendar.badge.minus"
                    ) {
                        onRemove(.before)
                    }
                }
            }
        }
    }

    private static func localizedDateToken(_ token: String) -> String {
        guard let date = storageDateFormatter.date(from: token) else { return token }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private static let storageDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func resolveBundleID(for appToken: String) -> String? {
        let q = appToken.lowercased()
        if let hit = model.searchAppCatalog.first(where: {
            $0.bundleID.lowercased() == q
                || $0.name.lowercased() == q
                || $0.name.lowercased().contains(q)
                || $0.bundleID.lowercased().contains(q)
        }) {
            return hit.bundleID
        }
        return nil
    }

    private func dismissibleChip(
        kind: SearchOperatorKind,
        label: String,
        filterName: String,
        systemImage: String,
        bundleID: String? = nil,
        domain: String? = nil,
        onRemove: @escaping () -> Void
    ) -> some View {
        Button(action: onRemove) {
            HStack(spacing: compact ? 3 : 4) {
                if let domain, !domain.isEmpty {
                    SLFaviconView(domain: domain, size: compact ? 11 : 12)
                } else if let bundleID {
                    SLAppIconView(bundleID: bundleID, size: compact ? 11 : 12)
                } else {
                    Image(systemName: systemImage)
                }
                Text(label)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: compact ? 8 : 9, weight: .bold))
            }
            .font(compact ? .system(size: 11, weight: .semibold) : .system(size: 12, weight: .semibold))
            .padding(.horizontal, compact ? 8 : 11)
            .padding(.vertical, compact ? 4 : 6)
            .background(model.accentSwiftUIColor.opacity(0.12), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(model.accentSwiftUIColor.opacity(0.28), lineWidth: 1)
            )
            .foregroundStyle(model.accentSwiftUIColor)
        }
        .buttonStyle(.plain)
        .help("Remove \(filterName.lowercased()) filter")
        .accessibilityLabel("Remove \(filterName) filter: \(label)")
        .accessibilityHint("Removes this filter from Library search")
        .accessibilityIdentifier("library.search.operator.\(kind.rawValue)")
    }
}

/// Multi-section operators, sites, apps, and dates autocomplete menu.
struct SearchAutocompleteMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selectedRowID: String?
    let onApply: (SearchAutocompleteRow) -> Void

    private var sections: [(title: String, rows: [SearchAutocompleteRow])] {
        var ops: [SearchAutocompleteRow] = []
        var sites: [SearchAutocompleteRow] = []
        var apps: [SearchAutocompleteRow] = []
        var dates: [SearchAutocompleteRow] = []
        for row in model.searchAutocompleteRows {
            switch row {
            case .op: ops.append(row)
            case .site: sites.append(row)
            case .app: apps.append(row)
            case .dateValue, .pickDate: dates.append(row)
            }
        }
        var out: [(String, [SearchAutocompleteRow])] = []
        if !ops.isEmpty { out.append(("Filters", ops)) }
        if !sites.isEmpty { out.append(("Websites", sites)) }
        if !apps.isEmpty { out.append(("Applications", apps)) }
        if !dates.isEmpty { out.append(("Dates", dates)) }
        return out
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, index == 0 ? 12 : 10)
                            .padding(.bottom, 4)

                        ForEach(section.rows) { row in
                            Button {
                                onApply(row)
                            } label: {
                                HStack(spacing: 12) {
                                    leading(row)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(row.title)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        if let sub = row.subtitle, !sub.isEmpty, sub != row.title {
                                            Text(sub)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    selectedRowID == row.id
                                        ? Color.accentColor.opacity(0.14)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 6)
                            .id(row.id)
                            .onHover { hovering in
                                if hovering { selectedRowID = row.id }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(accessibilityValue(for: row))
                            .accessibilityHint("Use this search suggestion")
                            .accessibilityIdentifier("library.search.suggestion.\(row.id)")
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            .onChange(of: selectedRowID) { _, rowID in
                guard let rowID else { return }
                if reduceMotion {
                    proxy.scrollTo(rowID, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(rowID, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 300, alignment: .leading)
        .slElevatedPanel()
        .accessibilityLabel("Search suggestions")
        .accessibilityValue("\(model.searchAutocompleteRows.count) available")
        .accessibilityIdentifier("library.search.suggestions")
    }

    private func accessibilityValue(for row: SearchAutocompleteRow) -> String {
        let rows = sections.flatMap(\.rows)
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return "" }
        let position = "\(index + 1) of \(rows.count)"
        return selectedRowID == row.id ? "Selected, \(position)" : position
    }

    @ViewBuilder
    private func leading(_ row: SearchAutocompleteRow) -> some View {
        switch row {
        case .op(let k):
            Image(systemName: k.systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .app(_, let bid):
            SLAppIconView(bundleID: bid, size: 22)
        case .site(let d):
            SLFaviconView(domain: d, size: 18)
        case .dateValue, .pickDate:
            Image(systemName: "calendar")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// Graphical calendar for date:/before:/since: structured search.
struct SearchDatePickerPopover: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kindLabel)
                .font(.headline)
            DatePicker(
                "",
                selection: $model.searchDatePickerSelection,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .accessibilityLabel(kindLabel)
            .accessibilityIdentifier("library.search.date-picker.calendar")
            .frame(minWidth: 280)

            HStack {
                Button("Cancel") {
                    model.showSearchDatePicker = false
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("library.search.date-picker.cancel")
                Spacer()
                Button("Apply") {
                    model.applySearchDatePickerSelection()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("library.search.date-picker.apply")
            }
        }
        .padding(16)
    }

    private var kindLabel: String {
        switch model.searchDatePickerKind {
        case .before: return "Before date"
        case .since: return "Since date"
        default: return "Pick a date"
        }
    }
}

/// Chooses between ranked and chronological results.
///
/// Relevance is the default because a Library search is usually a question
/// about something specific rather than a request for the newest activity.
/// Recency remains available, and is the only order that pages through an
/// unbounded history, so it stays a peer rather than a hidden fallback.
struct LibrarySearchSortPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker("Sort", selection: sortBinding) {
            ForEach(LibrarySearchSort.allCases, id: \.self) { sort in
                Text(Self.label(for: sort)).tag(sort)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .disabled(model.librarySearchEngine == .related)
        .help(model.librarySearchEngine == .related ? "Meaning results are ordered by similarity." : "Choose the result order.")
        .accessibilityIdentifier("library.search.sort")
        .accessibilityLabel("Sort results")
    }

    private var sortBinding: Binding<LibrarySearchSort> {
        Binding(
            get: { model.librarySearchEngine == .related ? .relevance : model.searchSort },
            set: { model.setSearchSort($0) }
        )
    }

    static func label(for sort: LibrarySearchSort) -> String {
        switch sort {
        case .relevance: return "Relevance"
        case .recent: return "Recent"
        }
    }
}
