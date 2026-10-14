import ScreenlogCore
import SwiftUI

/// Compact, surface-local feedback for Timeline navigation and moment actions.
/// The notice stays visually attached to the stage and never replaces capture
/// status or Library health elsewhere in the app.
struct TimelineNoticeView: View {
    let notice: TimelineNotice
    let onDismiss: () -> Void

    var body: some View {
        TimelineBannerShell(
            maxWidth: 620,
            accessibilityIdentifier: "timeline.notice"
        ) {
            HStack(spacing: SLDesign.space8) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)

                Text(notice.message)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(notice.severity.accessibilityLabel)
                    .accessibilityValue(notice.message)
                    .accessibilityIdentifier("timeline.notice.message")

                Button(action: onDismiss) {
                    Label("Dismiss", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .slCompactControlTarget()
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityIdentifier("timeline.notice.dismiss")
            }
        }
    }

    private var symbol: String {
        switch notice.severity {
        case .success: return "checkmark.circle.fill"
        case .information: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch notice.severity {
        case .success: return SLDesign.success
        case .information: return .secondary
        case .warning: return SLDesign.warning
        }
    }
}

/// Persistent recovery for a failed Timeline refresh when already-loaded
/// moments remain usable underneath it.
struct TimelineIssueBannerView: View {
    let issue: TimelineIssue
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        TimelineBannerShell(
            maxWidth: 680,
            accessibilityIdentifier: "timeline.issue.banner"
        ) {
            HStack(spacing: SLDesign.space8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SLDesign.warning)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: SLDesign.space4) {
                    Text(issue.title)
                        .font(.callout.weight(.semibold))
                    Text(issue.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .fixedSize(horizontal: false, vertical: true)

                Button("Try Again", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("timeline.issue.retry")

                Button(action: onDismiss) {
                    Label("Dismiss", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .slCompactControlTarget()
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityIdentifier("timeline.issue.dismiss")
            }
        }
    }
}

/// Recoverable feedback for a deletion that could not reach its confirmation
/// sheet. Confirmation failures remain inside the sheet beside the reviewed set.
struct TimelineDeletionIssueBannerView: View {
    let issue: LibraryDeletionIssue
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        TimelineBannerShell(
            maxWidth: 680,
            accessibilityIdentifier: "library.deletion.issue.timeline"
        ) {
            HStack(spacing: SLDesign.space8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SLDesign.warning)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: SLDesign.space4) {
                    Text(issue.title)
                        .font(.callout.weight(.semibold))
                    Text(issue.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .fixedSize(horizontal: false, vertical: true)

                if issue.canRetry {
                    Button("Try Again", action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("library.deletion.issue.timeline.retry")
                }

                Button(action: onDismiss) {
                    Label("Dismiss", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .slCompactControlTarget()
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityIdentifier("library.deletion.issue.timeline.dismiss")
            }
        }
    }
}

private struct TimelineBannerShell<Content: View>: View {
    let maxWidth: CGFloat
    let accessibilityIdentifier: String
    let content: Content

    init(
        maxWidth: CGFloat,
        accessibilityIdentifier: String,
        @ViewBuilder content: () -> Content
    ) {
        self.maxWidth = maxWidth
        self.accessibilityIdentifier = accessibilityIdentifier
        self.content = content()
    }

    var body: some View {
        content
            .foregroundStyle(.primary)
            .padding(.horizontal, SLDesign.space16)
            .padding(.vertical, SLDesign.space8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SLDesign.thumbRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SLDesign.thumbRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            }
            .frame(maxWidth: maxWidth)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}
