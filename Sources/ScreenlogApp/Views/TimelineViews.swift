import AppKit
import ScreenlogCore
import SwiftUI

struct HistoryPane: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State var showDayPicker = false
    @State var dayPickerSelection = Date()
    @State var timelineScaleStep = 0
    @State var stagePanOffset = CGSize.zero
    @State var stagePanGestureStart: CGSize?
    @State var ocrHighlightMatches = TimelineOCRHighlightMatches()

    var body: some View {
        Group {
            if let issue = model.libraryStartupIssue {
                LibraryStartupRecoveryView(issue: issue, surface: .timeline)
            } else {
                timelineSurface
            }
        }
        .tint(model.accentSwiftUIColor)
        .background(Color(nsColor: .windowBackgroundColor))
        .accentColor(model.accentSwiftUIColor)
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
        .sheet(
            item: timelineDeletionReview,
            onDismiss: {
                model.cancelLibraryDeletionReview()
            }
        ) { review in
            LibraryDeletionReviewSheet(
                review: review,
                isDeleting: model.libraryDeletionInProgress,
                issue: reviewDeletionIssue,
                onDelete: { Task { await model.confirmLibraryDeletion() } },
                onCancel: { model.cancelLibraryDeletionReview() }
            )
        }
    }

    @ViewBuilder
    private var timelineSurface: some View {
        switch model.timelineContentState {
        case .loading:
            TimelineLoadingStateView()
        case .failed:
            TimelineFailureStateView(
                issue: model.timelineIssue ?? .refreshTimeline,
                onRetry: { Task { await model.retryTimelineLoad() } },
                onOpenLibrary: openLibraryFromFailure
            )
        case .empty(.captureState):
            timelineEmptyView
        case .empty(.libraryResultUnavailable):
            TimelineNavigationEmptyStateView(
                context: .libraryResultUnavailable,
                onReturnToLibrary: { model.returnToLibrary() },
                onShowRecent: showRecentTimeline
            )
        case .empty(.selectedSessionUnavailable):
            TimelineNavigationEmptyStateView(
                context: .selectedSessionUnavailable,
                onReturnToLibrary: { model.returnToLibrary() },
                onShowRecent: showRecentTimeline
            )
        case .content:
            timelineContentView
        }
    }

    private var timelineEmptyView: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            TimelineStatePanel(
                symbol: model.permissions.isCaptureReady
                    ? "rectangle.stack.badge.plus"
                    : "checkmark.shield",
                symbolColor: .secondary,
                title: timelineEmptyTitle,
                detail: timelineEmptyDetail
            ) {
                HStack(spacing: SLDesign.space8) {
                    Button {
                        if model.isRecording {
                            Task { await model.refreshData(light: false) }
                        } else if model.permissions.isCaptureReady {
                            model.toggleRecording()
                        } else {
                            model.showPermissions(
                                origin: .timeline,
                                preferredPermission: missingCapturePermission
                            )
                        }
                    } label: {
                        Label(
                            !model.permissions.isCaptureReady
                                ? "Allow \(missingCapturePermission?.title ?? "Required Permission")"
                                : model.isRecording ? "Refresh Timeline" : "Start Capture",
                            systemImage: !model.permissions.isCaptureReady
                                ? "checkmark.shield"
                                : model.isRecording ? "arrow.clockwise" : "record.circle"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("timeline.empty.primary-action")

                    Button(model.permissions.isCaptureReady ? "Capture Settings" : "Privacy & Capture Settings") {
                        model.openProductSettings(
                            model.permissions.isCaptureReady
                                ? .captureStatus : .privacyPermissions
                        )
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("timeline.empty.settings")
                }
            }
            .accessibilityIdentifier("timeline.state.empty")
        }
    }

    private var timelineEmptyTitle: String {
        if let missingCapturePermission { return "Allow \(missingCapturePermission.title)" }
        return model.isRecording ? "Building Your Timeline" : "Your Timeline Starts Here"
    }

    private var timelineEmptyDetail: String {
        if !model.permissions.screenRecording {
            return "Screenlogger needs Screen Recording access before it can save your first moment."
        }
        if !model.permissions.accessibility {
            return "Screenlogger needs Accessibility access to apply exclusions and capture useful app context."
        }
        if model.isRecording {
            return "Capture is active. Your first searchable moment will appear shortly."
        }
        return "Start capture to build a private, searchable history on this Mac."
    }

    private var missingCapturePermission: ScreenlogPermission? {
        model.permissions.primaryMissingRequiredPermission
    }

    private var timelineContentView: some View {
        VStack(spacing: 0) {
            if model.selectedTimelineMomentFrames.count > 1 {
                HStack {
                    Spacer()
                    timelineDisplaySwitcher
                }
                .padding(.horizontal, SLDesign.space16)
                .padding(.top, SLDesign.space8)
            }

            ZStack {
                memoryStage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let issue = model.selectedFramePreviewIssue {
                    previewIssueView(issue)
                }

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(SLDesign.space16)

            if let selectedTimestampMs = model.selectedTimelineFrame?.timestampMs,
                !TimelineTranscriptPresentation.visiblePassages(
                    from: model.timelineTranscriptPassages,
                    selectedTimestampMs: selectedTimestampMs
                ).isEmpty
            {
                TimelineTranscriptRows(
                    passages: model.timelineTranscriptPassages,
                    selectedTimestampMs: selectedTimestampMs,
                    accent: model.accentSwiftUIColor
                )
            }

            bottomChrome
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var timelineDisplaySwitcher: some View {
        let displays = model.selectedTimelineMomentFrames
        HStack(spacing: SLDesign.space8) {
            Text("Display")
                .font(SLDesign.metadataFont)
                .foregroundStyle(.secondary)
            timelineDisplayPicker(displays)
                .pickerStyle(.menu)
                .fixedSize()
                .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.display.switcher")
    }

    private func timelineDisplayPicker(_ displays: [TimelineFrame]) -> some View {
        Picker(
            "Display",
            selection: Binding(
                get: { model.selectedTimelineID ?? displays[0].id },
                set: { model.selectTimelineDisplay(frameID: $0) }
            )
        ) {
            ForEach(Array(displays.enumerated()), id: \.element.id) { index, frame in
                Text(TimelineDisplayPresentation.label(for: index, in: displays)).tag(frame.id)
            }
        }
        .labelsHidden()
        .accessibilityLabel("Captured display")
        .accessibilityValue(Text(model.selectedTimelineDisplayLabel ?? "Display"))
        .accessibilityHint("Choose a display saved at this moment")
        .accessibilityIdentifier("timeline.display.picker")
    }

    private func showRecentTimeline() {
        Task { await model.showRecentTimeline() }
    }

    private func openLibraryFromFailure() {
        if model.timelineNavigationOrigin.returnsToLibrary {
            model.returnToLibrary()
        } else {
            model.openSearchWindow()
        }
    }

    private var reviewDeletionIssue: LibraryDeletionIssue? {
        guard let issue = model.libraryDeletionIssue,
            issue.origin == .timeline,
            case .deletionFailed = issue
        else { return nil }
        return issue
    }

    private var timelineDeletionReview: Binding<LibraryDeletionReview?> {
        Binding(
            get: {
                guard model.libraryDeletionReview?.origin == .timeline else { return nil }
                return model.libraryDeletionReview
            },
            set: { review in
                if review == nil { model.cancelLibraryDeletionReview() }
            }
        )
    }
}

private struct TimelineTranscriptRows: View {
    let passages: [TimelineTranscriptPresentation.Passage]
    let selectedTimestampMs: Int64
    let accent: Color

    private var visiblePassages: [TimelineTranscriptPresentation.Passage] {
        TimelineTranscriptPresentation.visiblePassages(
            from: passages,
            selectedTimestampMs: selectedTimestampMs
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SLDesign.space8) {
            ForEach(visiblePassages) { passage in
                let isActive = passage.contains(timestampMs: selectedTimestampMs)
                HStack(alignment: .firstTextBaseline, spacing: SLDesign.space16) {
                    Label(
                        passage.source.label,
                        systemImage: passage.source == .microphone ? "mic.fill" : "waveform"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    .frame(width: 88, alignment: .leading)

                    Text(passage.text)
                        .font(.callout)
                        .foregroundStyle(Color.primary)
                        .lineLimit(isActive ? 3 : 2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(SLTimeFormat.shortTime(passage.startTimestampMs))
                        .font(SLDesign.metadataFont.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, SLDesign.space8)
                .padding(.vertical, SLDesign.space8)
                .background(
                    isActive ? accent.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: SLDesign.thumbRadius, style: .continuous)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(isActive ? "Currently speaking, " : "")\(passage.source.label), \(passage.text), \(SLTimeFormat.shortTime(passage.startTimestampMs))"
                )
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }

            if passages.count > visiblePassages.count {
                Text("\(passages.count) transcript passages in this timeline")
                    .font(SLDesign.metadataFont)
                    .foregroundStyle(.secondary)
                    .padding(.leading, SLDesign.space8)
            }
        }
        .padding(.horizontal, SLDesign.space16)
        .padding(.vertical, SLDesign.space8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio transcript")
        .accessibilityIdentifier("timeline.transcript")
    }
}
