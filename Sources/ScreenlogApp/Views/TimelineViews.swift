import AppKit
import ScreenlogCore
import SwiftUI

struct HistoryPane: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) var colorSchemeContrast
    @State var showDayPicker = false
    @State var dayPickerSelection = Date()
    @State var timelineScaleStep = 0
    @State var stagePanOffset = CGSize.zero
    @State var stagePanGestureStart: CGSize?
    @State var ocrHighlightMatches = TimelineOCRHighlightMatches()

    var body: some View {
        Group {
            if let issue = model.libraryStartupIssue {
                ZStack {
                    Color.black
                    LibraryStartupRecoveryView(issue: issue, surface: .timeline)
                }
                .environment(\.colorScheme, .dark)
            } else {
                timelineSurface
                    .environment(\.colorScheme, .dark)
            }
        }
        .tint(model.accentSwiftUIColor)
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
            Color.black
            TimelineStatePanel(
                symbol: model.permissions.isCaptureReady
                    ? "rectangle.stack.badge.plus"
                    : "checkmark.shield",
                symbolColor: model.accentSwiftUIColor,
                title: timelineEmptyTitle,
                detail: timelineEmptyDetail
            ) {
                HStack(spacing: 12) {
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
            ZStack {
                memoryStage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let issue = model.selectedFramePreviewIssue {
                    previewIssueView(issue)
                }

                if model.selectedTimelineMomentFrames.count > 1 {
                    VStack {
                        timelineDisplaySwitcher
                        Spacer()
                    }
                    .padding(.top, 14)
                    .padding(.horizontal, 18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
        HStack(spacing: 8) {
            Image(systemName: "display.2")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            if displays.count <= 3 {
                timelineDisplayPicker(displays)
                    .pickerStyle(.segmented)
                    .fixedSize()
            } else {
                timelineDisplayPicker(displays)
                    .pickerStyle(.menu)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(controlStrokeOpacity), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
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
        VStack(alignment: .leading, spacing: 7) {
            ForEach(visiblePassages) { passage in
                let isActive = passage.contains(timestampMs: selectedTimestampMs)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(
                        passage.source.label,
                        systemImage: passage.source == .microphone ? "mic.fill" : "waveform"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.68))
                    .frame(width: 88, alignment: .leading)

                    Text(passage.text)
                        .font(.callout)
                        .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.88))
                        .lineLimit(isActive ? 3 : 2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(SLTimeFormat.shortTime(passage.startTimestampMs))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isActive ? Color.white.opacity(0.76) : Color.white.opacity(0.46))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    isActive ? accent.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    if isActive {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(accent.opacity(0.72), lineWidth: 1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(isActive ? "Currently speaking, " : "")\(passage.source.label), \(passage.text), \(SLTimeFormat.shortTime(passage.startTimestampMs))"
                )
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }

            if passages.count > visiblePassages.count {
                Text("\(passages.count) transcript passages in this timeline")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 9)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.94))
        .overlay(alignment: .top) {
            Divider().overlay(Color.white.opacity(0.12))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio transcript")
        .accessibilityIdentifier("timeline.transcript")
    }
}
