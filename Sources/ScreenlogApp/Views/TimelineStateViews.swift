import ScreenlogCore
import SwiftUI

/// A restrained, stage-appropriate presentation shared by Timeline states.
/// State views provide the outcome and actions while this shell keeps their
/// hierarchy, readable width, and contrast consistent.
struct TimelineStatePanel<Actions: View>: View {
    let symbol: String
    let symbolColor: Color
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    init(
        symbol: String,
        symbolColor: Color,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.symbol = symbol
        self.symbolColor = symbolColor
        self.title = title
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SLDesign.space16) {
            Label {
                Text(title)
                    .font(SLDesign.titleFont)
            } icon: {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(symbolColor)
                    .accessibilityHidden(true)
            }

            Text(detail)
                .font(SLDesign.bodyFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            actions
        }
        .padding(SLDesign.space24)
        .frame(maxWidth: 480, alignment: .leading)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
    }

}

/// Primary Timeline state surfaces used only when there is no usable moment to
/// keep on stage. Refresh failures with existing content stay compact banners.
struct TimelineLoadingStateView: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            HStack(spacing: SLDesign.space16) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: SLDesign.space4) {
                    Text("Loading Timeline...")
                        .font(SLDesign.sectionFont)
                    Text("Opening your most recent captured moments.")
                        .font(SLDesign.metadataFont)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading Timeline")
            .accessibilityIdentifier("timeline.state.loading")
        }
    }

}

struct TimelineFailureStateView: View {
    let issue: TimelineIssue
    let onRetry: () -> Void
    let onOpenLibrary: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            TimelineStatePanel(
                symbol: "exclamationmark.triangle",
                symbolColor: SLDesign.warning,
                title: issue.title,
                detail: issue.message
            ) {
                HStack(spacing: SLDesign.space8) {
                    Button(action: onRetry) {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("timeline.state.failure.retry")

                    Button(action: onOpenLibrary) {
                        Label("Open Library", systemImage: "books.vertical")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("timeline.state.failure.library")
                }
            }
            .accessibilityIdentifier("timeline.state.failure")
        }
    }
}

struct TimelineNavigationEmptyStateView: View {
    enum Context {
        case libraryResultUnavailable
        case selectedSessionUnavailable
    }

    let context: Context
    let onReturnToLibrary: () -> Void
    let onShowRecent: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            TimelineStatePanel(
                symbol: symbol,
                symbolColor: .secondary,
                title: title,
                detail: detail
            ) {
                HStack(spacing: SLDesign.space8) {
                    Button(action: primaryAction) {
                        Label(primaryTitle, systemImage: primarySymbol)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("timeline.empty.primary-action")

                    if context == .libraryResultUnavailable {
                        Button("Show Recent Timeline", action: onShowRecent)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("timeline.empty.show-recent")
                    }
                }
            }
            .accessibilityIdentifier("timeline.state.empty.navigation")
        }
    }

    private var title: String {
        switch context {
        case .libraryResultUnavailable: "This Moment Is No Longer Available"
        case .selectedSessionUnavailable: "No Moments in This Session"
        }
    }

    private var detail: String {
        switch context {
        case .libraryResultUnavailable:
            "Screenlogger may have removed it because of your storage settings. Your Library search and filters are unchanged."
        case .selectedSessionUnavailable:
            "This recorded session no longer contains moments. You can return to your recent Timeline."
        }
    }

    private var symbol: String {
        switch context {
        case .libraryResultUnavailable: "clock.badge.exclamationmark"
        case .selectedSessionUnavailable: "clock.badge.questionmark"
        }
    }

    private var primaryTitle: String {
        switch context {
        case .libraryResultUnavailable: "Back to Library"
        case .selectedSessionUnavailable: "Show Recent Timeline"
        }
    }

    private var primarySymbol: String {
        switch context {
        case .libraryResultUnavailable: "chevron.left"
        case .selectedSessionUnavailable: "clock.arrow.circlepath"
        }
    }

    private var primaryAction: () -> Void {
        context == .libraryResultUnavailable ? onReturnToLibrary : onShowRecent
    }
}
