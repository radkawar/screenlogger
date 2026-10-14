import AppKit
import ScreenlogCore
import SwiftUI

/// Screenlogger timeline window - a focused memory viewer with unobstructed stage chrome.
/// Search is a *separate* floating window (`SearchWindowController`), not a mode here.
struct MainShellView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            HistoryPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 8) {
                if let issue = model.timelineIssue,
                    model.timelineContentState != .failed
                {
                    TimelineIssueBannerView(
                        issue: issue,
                        onRetry: { Task { await model.retryTimelineIssue() } },
                        onDismiss: { model.dismissTimelineIssue() }
                    )
                } else if let issue = timelineDeletionIssue {
                    TimelineDeletionIssueBannerView(
                        issue: issue,
                        onRetry: { Task { await model.retryLibraryDeletionIssue() } },
                        onDismiss: { model.dismissLibraryDeletionIssue() }
                    )
                } else if let issue = model.captureIssue {
                    SLCaptureIssueBanner(issue: issue, context: "timeline")
                        .frame(maxWidth: 620)
                }

                if let notice = model.timelineNotice {
                    TimelineNoticeView(
                        notice: notice,
                        onDismiss: { model.dismissTimelineNotice() }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .padding(.horizontal, SLDesign.space16)
            .padding(.top, 8)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.18),
                value: model.timelineNotice?.id
            )
        }
        .frame(
            minWidth: SLDesign.workspaceMinimumWidth,
            minHeight: SLDesign.workspaceMinimumHeight
        )
        .tint(model.accentSwiftUIColor)
        .accentColor(model.accentSwiftUIColor)
        .background(.background)
        .onAppear {
            model.shellSearchMode = false
            Task {
                await model.loadSessions()
                if model.timeline.isEmpty,
                    model.timelineLoadState == .awaitingInitialLoad
                {
                    await model.refreshTimeline()
                }
            }
        }
        .background(
            TimelineKeyMonitor(
                shortcuts: timelineKeyboardShortcuts,
                onSlash: { model.openSearchWindow(intent: .timelineContext) },
                onEscape: { leaveTimeline() },
                onCommandK: { model.openSearchWindow(intent: .timelineContext) },
                onStepBack: {
                    model.stopReplay()
                    model.stepTimeline(by: -1)
                },
                onStepForward: {
                    model.stopReplay()
                    model.stepTimeline(by: 1)
                },
                onPreviousSegment: {
                    model.stopReplay()
                    model.stepSegment(by: -1)
                },
                onNextSegment: {
                    model.stopReplay()
                    model.stepSegment(by: 1)
                },
                onToggleReplay: { TimelinePlaybackControl.toggle(model) },
                onZoomIn: { model.zoomStage(by: 1.25) },
                onZoomOut: { model.zoomStage(by: 1 / 1.25) },
                onResetZoom: { model.resetStageZoom() }
            )
            .frame(width: 0, height: 0)
        )
        .onExitCommand {
            leaveTimeline()
        }
    }

    private var timelineKeyboardShortcuts: [KeyboardShortcutActionID: KeyboardShortcutBinding] {
        let actions: [KeyboardShortcutActionID] = [
            .searchLibrary,
            .timelineFilter,
            .timelinePreviousMoment,
            .timelineNextMoment,
            .timelinePreviousActivity,
            .timelineNextActivity,
            .timelineToggleReplay,
            .timelineZoomIn,
            .timelineZoomOut,
            .timelineResetZoom,
        ]
        return Dictionary(
            uniqueKeysWithValues: actions.compactMap { actionID in
                model.keyboardShortcutBinding(for: actionID).map { (actionID, $0) }
            }
        )
    }

    private var offersLibraryReturn: Bool {
        model.timelineNavigationOrigin.returnsToLibrary
    }

    private func leaveTimeline() {
        if offersLibraryReturn {
            model.returnToLibrary()
        } else {
            model.closeMainShell()
        }
    }

    private var timelineDeletionIssue: LibraryDeletionIssue? {
        guard let issue = model.libraryDeletionIssue, issue.origin == .timeline else { return nil }
        // Confirmation failures appear inside the still-open review sheet.
        if case .deletionFailed = issue { return nil }
        return issue
    }

}

/// Location, handoff, and current-moment context hosted in the native toolbar.
struct TimelineToolbarContextView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            contextContent(moment: fullMomentContext)
                .fixedSize(horizontal: true, vertical: false)
            contextContent(moment: compactMomentContext)
                .fixedSize(horizontal: true, vertical: false)
            locationLabel
                .fixedSize(horizontal: true, vertical: false)
        }
        // Custom toolbar views don't receive AppKit's automatic control tint.
        // An explicit semantic foreground keeps their labels legible on both
        // light titlebars and dark edge-to-edge Timeline content.
        .foregroundStyle(.primary)
        .tint(model.accentSwiftUIColor)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.chrome.top")
    }

    private func contextContent<Moment: View>(moment: Moment) -> some View {
        HStack(spacing: 12) {
            locationLabel

            Divider()
                .frame(height: 18)

            moment
        }
    }

    private var locationLabel: some View {
        Label("Timeline", systemImage: "clock")
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.semibold))
            .fixedSize()
            .accessibilityIdentifier("timeline.location")
    }

    @ViewBuilder
    private var fullMomentContext: some View {
        if let frame = model.selectedTimelineFrame {
            HStack(spacing: 9) {
                SLAppIconView(bundleID: frame.bundleID, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(frame.appLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        if let domain = frame.domain, !domain.isEmpty {
                            Divider()
                                .frame(height: 11)
                                .accessibilityHidden(true)
                            Text(domain)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let title = frame.title, !title.isEmpty,
                        title.compare(frame.appLabel, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
                    {
                        Text(title)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .lineLimit(1)

                Divider()
                    .frame(height: 18)

                Text(SLTimeFormat.shortTime(frame.timestampMs))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 380, alignment: .leading)
            .help(SLTimeFormat.full(frame.timestampMs))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current moment")
            .accessibilityValue(momentContextValue(frame))
            .accessibilityIdentifier("timeline.moment.context")
        } else {
            Text("No moment selected")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var compactMomentContext: some View {
        if let frame = model.selectedTimelineFrame {
            HStack(spacing: 7) {
                SLAppIconView(bundleID: frame.bundleID, size: 19)
                Text(SLTimeFormat.shortTime(frame.timestampMs))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help(momentContextValue(frame))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current moment")
            .accessibilityValue(momentContextValue(frame))
            .accessibilityIdentifier("timeline.moment.context")
        } else {
            Text("No moment")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    private func momentContextValue(_ frame: TimelineFrame) -> String {
        [
            frame.appLabel,
            frame.domain,
            frame.title,
            SLTimeFormat.full(frame.timestampMs),
        ]
        .compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        .joined(separator: ", ")
    }
}

/// Capture state hosted in the native toolbar. Window destinations are
/// separate AppKit toolbar items so their order and hit targets stay stable.
struct TimelineToolbarActionsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            expandedActions
                .fixedSize(horizontal: true, vertical: false)
            compactActions
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.chrome.toolbar-actions")
        .tint(model.accentSwiftUIColor)
    }

    private var expandedActions: some View {
        SLCaptureStatusToolbarView(
            setupOrigin: .timeline,
            accessibilityIdentifier: "timeline.capture.status"
        )
        .labelStyle(.titleAndIcon)
    }

    private var compactActions: some View {
        SLCaptureStatusToolbarView(
            setupOrigin: .timeline,
            accessibilityIdentifier: "timeline.capture.status"
        )
        .labelStyle(.iconOnly)
    }
}
