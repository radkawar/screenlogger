import ScreenlogCore
import SwiftUI

/// Shared recovery surface used by both Library and Timeline. It deliberately
/// offers local actions only: retry opening the same Library, reveal its files,
/// or reveal the bootstrap log for support.
struct LibraryStartupRecoveryView: View {
    enum Surface: Equatable {
        case library
        case timeline
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let issue: LibraryStartupIssue
    let surface: Surface

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 30, weight: .regular))
                .frame(width: 36, height: 36)
                .foregroundStyle(SLDesign.warning)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(issue.title)
                    .font(.title2.weight(.semibold))
                Text(issue.message)
                    .font(.callout)
                    .foregroundStyle(secondaryTextColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 10) {
                        recoveryActions
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            recoveryActions
                        }
                        VStack(spacing: 10) {
                            recoveryActions
                        }
                    }
                }
            }
        }
        .padding(28)
        .foregroundStyle(primaryTextColor)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifierPrefix).startup-recovery")
    }

    @ViewBuilder
    private var recoveryActions: some View {
        Button {
            model.retryLibraryBootstrap()
        } label: {
            if model.libraryBootstrapRetrying {
                Label("Trying Again...", systemImage: "arrow.clockwise")
            } else {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(model.libraryBootstrapRetrying)
        .accessibilityIdentifier("\(identifierPrefix).startup-recovery.retry")

        if model.canRevealLibrary {
            Button {
                model.revealLibrary()
            } label: {
                Label("Reveal Library", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("\(identifierPrefix).startup-recovery.reveal-library")
        }

        if model.canRevealLibraryDiagnostics {
            Button("Show Diagnostics") {
                model.revealLibraryDiagnostics()
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("\(identifierPrefix).startup-recovery.diagnostics")
        }
    }

    private var identifierPrefix: String {
        surface == .library ? "library" : "timeline"
    }

    private var primaryTextColor: Color {
        surface == .timeline ? .white.opacity(0.92) : .primary
    }

    private var secondaryTextColor: Color {
        surface == .timeline ? .white.opacity(0.68) : .secondary
    }
}

enum LibraryResultState {
    case idle
    case needsMoreInput
    case loading
    case content
    case filteredEmpty
    case noMatches
    case recoverableError
}

struct LibraryResultStateView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let state: LibraryResultState
    let onClearSearch: () -> Void
    let onClearFilters: () -> Void
    let onClearAll: () -> Void

    @ViewBuilder
    var body: some View {
        switch state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text("Searching your Library...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Searching your Library")
            .accessibilityIdentifier("library.state.loading")

        case .idle:
            VStack(spacing: 18) {
                VStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("Search your history")
                        .font(.title2.weight(.semibold))
                    Text("Type words you remember seeing on screen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                if !model.recentSearchQueries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Recent searches", systemImage: "clock.arrow.circlepath")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        FlowRecentQueries(queries: model.recentSearchQueries) { query in
                            model.applyRecentQuery(query)
                        }
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                }

                Button {
                    if !model.permissions.isCaptureReady {
                        model.showPermissions(
                            origin: .library,
                            preferredPermission: missingCapturePermission
                        )
                    } else if model.isRecording {
                        model.showMainShell()
                    } else if model.startCapture() {
                        model.showMainShell()
                    }
                } label: {
                    Label(
                        !model.permissions.isCaptureReady
                            ? "Allow \(missingCapturePermission?.title ?? "Required Permission")"
                            : model.isRecording ? "Open Timeline" : "Start Capture",
                        systemImage: !model.permissions.isCaptureReady
                            ? "checkmark.shield"
                            : model.isRecording ? "clock.arrow.circlepath" : "record.circle"
                    )
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("library.state.idle.primary-action")
            }
            .frame(maxWidth: 600)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.state.idle")

        case .needsMoreInput:
            ContentUnavailableView(
                "Keep typing",
                systemImage: "text.cursor",
                description: Text("Enter at least two characters, or finish the app, website, or date filter.")
            )
            .accessibilityIdentifier("library.state.needs-more-input")

        case .recoverableError:
            let issue = model.librarySearchState.issue ?? .queryFailed
            VStack(spacing: 12) {
                ContentUnavailableView(
                    issue.title,
                    systemImage: "exclamationmark.triangle",
                    description: Text(issue.message)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(issue.title)
                .accessibilityValue(issue.message)
                .accessibilityIdentifier("library.state.error.message")
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 10) {
                            errorRecoveryActions
                        }
                    } else {
                        HStack(spacing: 10) {
                            errorRecoveryActions
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.state.error")

        case .filteredEmpty:
            VStack(spacing: 12) {
                ContentUnavailableView(
                    hasAuthoredSearchText ? "No matches" : "No matches for these filters",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text(
                        hasAuthoredSearchText
                            ? "Try clearing filters or using fewer words."
                            : "Clear app, website, date, time, or session filters."
                    )
                )
                HStack(spacing: 10) {
                    Button("Clear Filters", action: onClearFilters)
                        .buttonStyle(.borderedProminent)
                    if hasAuthoredSearchText {
                        Button("Clear All", action: onClearAll)
                            .buttonStyle(.bordered)
                    }
                }
            }
            .accessibilityIdentifier("library.state.filtered-empty")

        case .noMatches:
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "No matches",
                    systemImage: "magnifyingglass",
                    description: Text("Try fewer words, or use the app, website, or date filters.")
                )
                Button("Clear Search", action: onClearSearch)
                    .buttonStyle(.bordered)
            }
            .accessibilityIdentifier("library.state.no-matches")

        case .content:
            EmptyView()
        }
    }

    private var missingCapturePermission: ScreenlogPermission? {
        model.permissions.primaryMissingRequiredPermission
    }

    @ViewBuilder
    private var errorRecoveryActions: some View {
        Button(
            clearErrorTitle,
            action: clearErrorAction
        )
        .buttonStyle(.bordered)
        .accessibilityIdentifier("library.error.clear")

        Button("Try Again") {
            model.retryLibrarySearch()
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("library.retrySearch")
    }

    private var clearErrorTitle: String {
        switch (hasAuthoredSearchText, model.activeLibrarySearchFilterCount > 0) {
        case (true, true): return "Clear Search and Filters"
        case (false, true): return "Clear Filters"
        default: return "Clear Search"
        }
    }

    private var clearErrorAction: () -> Void {
        if hasAuthoredSearchText, model.activeLibrarySearchFilterCount > 0 {
            return onClearAll
        }
        return model.activeLibrarySearchFilterCount > 0 ? onClearFilters : onClearSearch
    }

    private var hasAuthoredSearchText: Bool {
        !SearchOperatorParser.parse(model.searchQuery).ftsText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }
}

private struct FlowRecentQueries: View {
    let queries: [String]
    let onPick: (String) -> Void

    var body: some View {
        RecentQueryFlowLayout(spacing: 6) {
            ForEach(queries, id: \.self) { q in
                Button {
                    onPick(q)
                } label: {
                    Text(q)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: 180)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Search for \(q)")
                .accessibilityLabel("Search for \(q)")
            }
        }
    }
}

/// A compact, leading-aligned wrap that keeps recent queries visually related.
private struct RecentQueryFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let layout = measurements(proposedWidth: proposal.width, subviews: subviews)
        return CGSize(width: proposal.width ?? layout.contentWidth, height: layout.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let availableWidth = max(bounds.width, 1)
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += min(size.width, availableWidth) + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func measurements(proposedWidth: CGFloat?, subviews: Subviews) -> (
        contentWidth: CGFloat, height: CGFloat
    ) {
        let availableWidth = max(proposedWidth ?? .greatestFiniteMagnitude, 1)
        var rowWidth: CGFloat = 0
        var widestRow: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let itemWidth = min(size.width, availableWidth)
            if rowWidth > 0, rowWidth + spacing + itemWidth > availableWidth {
                widestRow = max(widestRow, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth == 0 ? 0 : spacing) + itemWidth
            rowHeight = max(rowHeight, size.height)
        }

        return (max(widestRow, rowWidth), totalHeight + rowHeight)
    }
}
