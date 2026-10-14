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
        .primary
    }

    private var secondaryTextColor: Color {
        .secondary
    }
}

enum LibraryResultState {
    case idle
    case needsMoreInput
    case invalidFilters
    case needsDescription
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
            VStack(alignment: .leading, spacing: SLDesign.space24) {
                VStack(alignment: .leading, spacing: SLDesign.space8) {
                    Text("Your history")
                        .font(SLDesign.titleFont)
                    Text(
                        model.librarySearchEngine == .related
                            ? "Describe a screen, page, or moment you remember."
                            : "Find names, commands, and exact words on screen."
                    )
                    .font(SLDesign.bodyFont)
                    .foregroundStyle(.secondary)
                }

                if !model.recentSearchQueries.isEmpty {
                    VStack(alignment: .leading, spacing: SLDesign.space8) {
                        Text("Recent searches")
                            .font(SLDesign.sectionFont)
                        FlowRecentQueries(queries: model.recentSearchQueries) { query in
                            model.applyRecentQuery(query)
                        }
                    }
                }

                if !model.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: SLDesign.space8) {
                        Text("Recent sessions")
                            .font(SLDesign.sectionFont)
                        ForEach(Array(model.sessions.prefix(5))) { session in
                            Button {
                                model.libraryWorkspaceNavigation.selectedSessionStartMs = session.startMs
                                model.libraryWorkspaceNavigation.contentMode = .sessions
                            } label: {
                                HStack(spacing: SLDesign.space16) {
                                    SLAppIconView(bundleID: session.primaryBundleID, size: 24)
                                    VStack(alignment: .leading, spacing: SLDesign.space4) {
                                        Text(session.displayTitle)
                                            .font(SLDesign.bodyFont)
                                        Text(
                                            Date(timeIntervalSince1970: Double(session.startMs) / 1000),
                                            format: .dateTime.month(.abbreviated).day().hour().minute()
                                        )
                                        .font(SLDesign.metadataFont)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, SLDesign.space8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Show session \(session.displayTitle)")
                        }
                    }
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
                .disabled(model.isDatabaseReclamationRunning && !model.isRecording)
                .accessibilityIdentifier("library.state.idle.primary-action")
                if model.isDatabaseReclamationRunning {
                    Text("Screenlogger is reclaiming database space. Capture is unavailable until this finishes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.state.idle")

        case .invalidFilters:
            ContentUnavailableView(
                "Check your filters",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text(model.librarySearchValidationMessage ?? "")
            )
            .accessibilityIdentifier("library.state.invalid-filters")

        case .needsDescription:
            ContentUnavailableView(
                "Describe what you're looking for",
                systemImage: "magnifyingglass",
                description: Text("Meaning needs a description. Use Words to browse with filters alone.")
            )
            .accessibilityIdentifier("library.state.related-description")

        case .needsMoreInput:
            ContentUnavailableView(
                "Keep typing",
                systemImage: "text.cursor",
                description: Text("Enter at least two characters, or complete the app, website, or date filter.")
            )
            .accessibilityIdentifier("library.state.needs-more-input")

        case .recoverableError:
            let issue = model.librarySearchState.issue ?? .queryFailed
            VStack(spacing: 12) {
                ContentUnavailableView(
                    issue.title,
                    systemImage: "exclamationmark.triangle",
                    description: Text(model.semanticSearchMessage ?? issue.message)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(issue.title)
                .accessibilityValue(model.semanticSearchMessage ?? issue.message)
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
        VStack(alignment: .leading, spacing: 0) {
            ForEach(queries.prefix(6), id: \.self) { q in
                Button {
                    onPick(q)
                } label: {
                    Label(q, systemImage: "clock.arrow.circlepath")
                        .font(SLDesign.bodyFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Search for \(q)")
                .accessibilityLabel("Search for \(q)")
            }
        }
    }
}
