import ScreenlogCore
import SwiftUI

/// Shared interaction policy for every Timeline playback entry point.
/// Native media controls restart from the beginning when Play is pressed at
/// the end instead of briefly entering a replay state that cannot advance.
@MainActor
enum TimelinePlaybackControl {
    static func toggle(_ model: AppModel) {
        guard model.timelineMomentCount > 1 else { return }
        if !model.isReplaying, !model.canStepForward {
            model.selectFirstTimelineMoment()
        }
        model.toggleReplay()
    }
}

extension HistoryPane {
    /// Contextual time, transport, zoom, and activity controls below the stage.
    var bottomChrome: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if model.selectedTimelineFrame != nil {
                    timelineDayNavigation
                }

                Spacer(minLength: 8)

                timelineControlBar
            }
            .padding(.horizontal, 18)

            // Time-aware activity ribbon.
            segmentTrack
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
        }
        .padding(.top, 8)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.45), .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.chrome.bottom")
    }

    private var timelineControlBar: some View {
        // ViewThatFits builds both candidates on every pass, so the segment scan
        // is answered once here instead of once per candidate.
        let segmentAvailability =
            model.showSegmentNavigation
            ? segmentNavigationAvailability
            : (previous: false, next: false)
        return ViewThatFits(in: .horizontal) {
            expandedTimelineControlBar(segmentAvailability: segmentAvailability)
                .fixedSize(horizontal: true, vertical: false)
            compactTimelineControlBar(segmentAvailability: segmentAvailability)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func expandedTimelineControlBar(
        segmentAvailability: (previous: Bool, next: Bool)
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                model.stopReplay()
                model.stepTimeline(by: -1)
            } label: {
                Label("Previous moment", systemImage: "backward.frame.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .disabled(!model.canStepBack)
            .help(shortcutHelp("Previous moment", actionID: .timelinePreviousMoment))
            .accessibilityIdentifier("timeline.playback.previous")

            Button {
                TimelinePlaybackControl.toggle(model)
            } label: {
                Image(systemName: model.isReplaying ? "pause.fill" : "play.fill")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(model.accentSwiftUIColor)
            .disabled(model.timelineMomentCount < 2)
            .help(
                shortcutHelp(
                    model.isReplaying ? "Pause replay" : "Play through moments",
                    actionID: .timelineToggleReplay
                )
            )
            .accessibilityLabel(
                model.isReplaying ? "Pause replay" : "Play through moments"
            )
            .accessibilityIdentifier("timeline.playback.toggle")

            Button {
                model.stopReplay()
                model.stepTimeline(by: 1)
            } label: {
                Label("Next moment", systemImage: "forward.frame.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .disabled(!model.canStepForward)
            .help(shortcutHelp("Next moment", actionID: .timelineNextMoment))
            .accessibilityIdentifier("timeline.playback.next")

            if model.showSegmentNavigation {
                controlDivider

                Button {
                    model.stopReplay()
                    model.stepSegment(by: -1)
                } label: {
                    Label("Previous activity", systemImage: "backward.end.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .disabled(!segmentAvailability.previous)
                .help(
                    shortcutHelp(
                        "Previous activity",
                        actionID: .timelinePreviousActivity
                    )
                )
                .accessibilityIdentifier("timeline.segment.previous")

                Button {
                    model.stopReplay()
                    model.stepSegment(by: 1)
                } label: {
                    Label("Next activity", systemImage: "forward.end.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .disabled(!segmentAvailability.next)
                .help(
                    shortcutHelp(
                        "Next activity",
                        actionID: .timelineNextActivity
                    )
                )
                .accessibilityIdentifier("timeline.segment.next")
            }

            if model.showZoomControls {
                controlDivider

                Button {
                    model.zoomStage(by: 1 / 1.25)
                } label: {
                    Label("Zoom out", systemImage: "minus.magnifyingglass")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .disabled(model.selectedFrameImage == nil || model.stageZoom <= 0.5)
                .help(shortcutHelp("Zoom out", actionID: .timelineZoomOut))
                .accessibilityIdentifier("timeline.zoom.out")

                Button {
                    model.resetStageZoom()
                } label: {
                    Text("\(Int(model.stageZoom * 100))%")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                        .frame(minWidth: 38, minHeight: 28)
                }
                .disabled(model.selectedFrameImage == nil || model.stageZoom == 1)
                .help(shortcutHelp("Reset zoom", actionID: .timelineResetZoom))
                .accessibilityLabel("Reset zoom")
                .accessibilityValue("\(Int(model.stageZoom * 100)) percent")
                .accessibilityIdentifier("timeline.zoom.reset")

                Button {
                    model.zoomStage(by: 1.25)
                } label: {
                    Label("Zoom in", systemImage: "plus.magnifyingglass")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .disabled(model.selectedFrameImage == nil || model.stageZoom >= 4)
                .help(shortcutHelp("Zoom in", actionID: .timelineZoomIn))
                .accessibilityIdentifier("timeline.zoom.in")
            }

            controlDivider

            Button {
                model.showLiveText.toggle()
            } label: {
                Label("Detected text highlights", systemImage: "text.viewfinder")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
                    .foregroundStyle(
                        hasSelectedOCRBoxes && model.showLiveText
                            ? model.accentSwiftUIColor
                            : Color.primary
                    )
            }
            .disabled(!hasSelectedOCRBoxes)
            .help(liveTextControlHelp)
            .accessibilityLabel("Detected text highlights")
            .accessibilityValue(
                hasSelectedOCRBoxes
                    ? (model.showLiveText ? "Shown" : "Hidden")
                    : "Unavailable for this moment"
            )
            .accessibilityAddTraits(
                hasSelectedOCRBoxes && model.showLiveText ? .isSelected : []
            )
            .accessibilityIdentifier("timeline.live-text")

            Menu {
                Button {
                    model.copySelectedFrameImage()
                } label: {
                    Label("Copy Image", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(!model.canCopySelectedFrameImage)
                .accessibilityIdentifier("timeline.moment.actions.copy-image")

                Button {
                    model.copySelectedOCRText()
                } label: {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
                .disabled(!model.canCopySelectedOCRText)
                .accessibilityIdentifier("timeline.moment.actions.copy-text")

                if model.showOpenExternally {
                    Divider()

                    Button {
                        model.openSelectedExternally()
                    } label: {
                        Label("Open Source", systemImage: "arrow.up.forward.app")
                    }
                    .disabled(!model.canOpenSelectedExternally)
                    .accessibilityIdentifier("timeline.moment.actions.open-source")
                }

                Divider()

                Button(role: .destructive) {
                    guard let frame = model.selectedTimelineFrame else { return }
                    Task {
                        await model.prepareLibraryDeletion(
                            .moment(frameID: frame.id),
                            origin: .timeline,
                            title: "Delete This Moment?",
                            detail: TimelineDisplayPresentation.deletionDetail(
                                frame: frame,
                                displayCount: model.selectedTimelineMomentFrames.count
                            )
                        )
                    }
                } label: {
                    Label("Delete Moment...", systemImage: "trash")
                }
                .disabled(model.selectedTimelineFrame == nil)
                .accessibilityIdentifier("timeline.moment.actions.delete")
            } label: {
                Label("Moment Actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.selectedTimelineFrame == nil)
            .help("Copy, open, or delete this moment")
            .accessibilityLabel("Moment Actions")
            .accessibilityHint("Copy, open, or delete the selected moment")
            .accessibilityIdentifier("timeline.moment.actions")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(controlStrokeOpacity), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline controls")
    }

    /// At compact widths, keep playback immediate and move less-frequent
    /// inspection tools into one predictable overflow menu.
    private func compactTimelineControlBar(
        segmentAvailability: (previous: Bool, next: Bool)
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                model.stopReplay()
                model.stepTimeline(by: -1)
            } label: {
                Label("Previous moment", systemImage: "backward.frame.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .disabled(!model.canStepBack)
            .help(shortcutHelp("Previous moment", actionID: .timelinePreviousMoment))
            .accessibilityIdentifier("timeline.playback.previous")

            Button {
                TimelinePlaybackControl.toggle(model)
            } label: {
                Image(systemName: model.isReplaying ? "pause.fill" : "play.fill")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(model.accentSwiftUIColor)
            .disabled(model.timelineMomentCount < 2)
            .help(
                shortcutHelp(
                    model.isReplaying ? "Pause replay" : "Play through moments",
                    actionID: .timelineToggleReplay
                )
            )
            .accessibilityLabel(
                model.isReplaying ? "Pause replay" : "Play through moments"
            )
            .accessibilityIdentifier("timeline.playback.toggle")

            Button {
                model.stopReplay()
                model.stepTimeline(by: 1)
            } label: {
                Label("Next moment", systemImage: "forward.frame.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .disabled(!model.canStepForward)
            .help(shortcutHelp("Next moment", actionID: .timelineNextMoment))
            .accessibilityIdentifier("timeline.playback.next")

            controlDivider

            Menu {
                if model.showSegmentNavigation {
                    Button {
                        model.stopReplay()
                        model.stepSegment(by: -1)
                    } label: {
                        Label("Previous Activity", systemImage: "backward.end.fill")
                    }
                    .disabled(!segmentAvailability.previous)
                    .accessibilityIdentifier("timeline.segment.previous")

                    Button {
                        model.stopReplay()
                        model.stepSegment(by: 1)
                    } label: {
                        Label("Next Activity", systemImage: "forward.end.fill")
                    }
                    .disabled(!segmentAvailability.next)
                    .accessibilityIdentifier("timeline.segment.next")
                }

                if model.showZoomControls {
                    Divider()

                    Button {
                        model.zoomStage(by: 1 / 1.25)
                    } label: {
                        Label("Zoom Out", systemImage: "minus.magnifyingglass")
                    }
                    .disabled(model.selectedFrameImage == nil || model.stageZoom <= 0.5)
                    .accessibilityIdentifier("timeline.zoom.out")

                    Button {
                        model.resetStageZoom()
                    } label: {
                        Label(
                            "Reset Zoom (\(Int(model.stageZoom * 100))%)",
                            systemImage: "arrow.counterclockwise"
                        )
                    }
                    .disabled(model.selectedFrameImage == nil || model.stageZoom == 1)
                    .accessibilityIdentifier("timeline.zoom.reset")

                    Button {
                        model.zoomStage(by: 1.25)
                    } label: {
                        Label("Zoom In", systemImage: "plus.magnifyingglass")
                    }
                    .disabled(model.selectedFrameImage == nil || model.stageZoom >= 4)
                    .accessibilityIdentifier("timeline.zoom.in")
                }

                Divider()

                Button {
                    model.showLiveText.toggle()
                } label: {
                    Label(
                        model.showLiveText ? "Hide Detected Text" : "Show Detected Text",
                        systemImage: "text.viewfinder"
                    )
                }
                .disabled(!hasSelectedOCRBoxes)
                .accessibilityIdentifier("timeline.live-text")

                Divider()

                Button {
                    model.copySelectedFrameImage()
                } label: {
                    Label("Copy Image", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(!model.canCopySelectedFrameImage)
                .accessibilityIdentifier("timeline.moment.actions.copy-image")

                Button {
                    model.copySelectedOCRText()
                } label: {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
                .disabled(!model.canCopySelectedOCRText)
                .accessibilityIdentifier("timeline.moment.actions.copy-text")

                if model.showOpenExternally {
                    Button {
                        model.openSelectedExternally()
                    } label: {
                        Label("Open Source", systemImage: "arrow.up.forward.app")
                    }
                    .disabled(!model.canOpenSelectedExternally)
                    .accessibilityIdentifier("timeline.moment.actions.open-source")
                }

                Divider()

                Button(role: .destructive) {
                    guard let frame = model.selectedTimelineFrame else { return }
                    Task {
                        await model.prepareLibraryDeletion(
                            .moment(frameID: frame.id),
                            origin: .timeline,
                            title: "Delete This Moment?",
                            detail: "\(frame.appLabel) at \(SLTimeFormat.full(frame.timestampMs))."
                        )
                    }
                } label: {
                    Label("Delete Moment...", systemImage: "trash")
                }
                .disabled(model.selectedTimelineFrame == nil)
                .accessibilityIdentifier("timeline.moment.actions.delete")
            } label: {
                Label("More Timeline Actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Activity, zoom, text, and moment actions")
            .accessibilityLabel("More Timeline Actions")
            .accessibilityIdentifier("timeline.moment.actions")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(controlStrokeOpacity), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline controls")
    }

    private func shortcutHelp(
        _ title: String,
        actionID: KeyboardShortcutActionID
    ) -> String {
        "\(title)  \(model.keyboardShortcutDisplayLabel(for: actionID))"
    }

    private var controlDivider: some View {
        Divider()
            .frame(height: 16)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }

    private var hasSelectedOCRBoxes: Bool {
        !model.selectedFrameOCRBoxes.isEmpty
    }

    private var liveTextControlHelp: String {
        guard hasSelectedOCRBoxes else {
            return "No detected text highlights are available for this moment"
        }
        return model.showLiveText ? "Hide detected text highlights" : "Show detected text highlights"
    }

    private var segmentNavigationAvailability: (previous: Bool, next: Bool) {
        guard let selected = model.selectedTimelineFrame else {
            return (false, false)
        }

        // AppModel normalizes every Timeline load into chronological capture order.
        // Avoid sorting the full collection again on each SwiftUI body update.
        let ordered = model.timelineMomentFrames
        guard let selectedIndex = model.selectedTimelineMomentIndex else {
            return (false, false)
        }

        let canMoveBackward =
            selectedIndex > 0
            && ordered[..<selectedIndex].contains {
                selected.segmentID == nil || $0.segmentID != selected.segmentID
            }
        let canMoveForward =
            selectedIndex + 1 < ordered.count
            && ordered[(selectedIndex + 1)...].contains {
                selected.segmentID == nil || $0.segmentID != selected.segmentID
            }
        return (canMoveBackward, canMoveForward)
    }

    private func momentDateLabel(_ timestampMs: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)
        return Self.timelineDateFormatter.string(from: d)
    }

    private static let timelineDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// Both directions from one pass over the recorded days. Asking the model
    /// per button rebuilt the whole day set twice on every body pass.
    private var timelineDayNavigationAvailability: (previous: Bool, next: Bool) {
        guard let current = model.selectedTimelineDay else { return (false, false) }
        let days = model.timelineAvailableDays
        return (
            days.contains(where: { $0 < current }),
            days.contains(where: { $0 > current })
        )
    }

    private var timelineDayNavigation: some View {
        let dayAvailability = timelineDayNavigationAvailability
        return HStack(spacing: 4) {
            Button {
                Task { await model.navigateTimelineDay(by: -1) }
            } label: {
                Label("Previous recorded day", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .disabled(!dayAvailability.previous)
            .help("Previous recorded day")
            .accessibilityIdentifier("timeline.day.previous")

            Button {
                dayPickerSelection = model.selectedTimelineDay ?? Date()
                showDayPicker = true
            } label: {
                Label(
                    timelineRangeLabel,
                    systemImage: model.selectedSession == nil ? "calendar" : "clock.badge.checkmark"
                )
                .fontWeight(.semibold)
            }
            .popover(isPresented: $showDayPicker, arrowEdge: .bottom) {
                timelineDayPicker
            }
            .help(timelineRangeHelp)
            .accessibilityLabel("Choose Timeline range")
            .accessibilityValue(timelineRangeAccessibilityValue)
            .accessibilityIdentifier("timeline.day.choose")

            Button {
                Task { await model.navigateTimelineDay(by: 1) }
            } label: {
                Label("Next recorded day", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .disabled(!dayAvailability.next)
            .help("Next recorded day")
            .accessibilityIdentifier("timeline.day.next")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(controlStrokeOpacity), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recorded day navigation")
    }

    private var timelineDayPicker: some View {
        let daySessions = model.timelineSessions(on: dayPickerSelection)
        let recentRangeSelected = isRecentTimelineRangeSelected
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                showDayPicker = false
                guard !recentRangeSelected else { return }
                Task { await model.showRecentTimeline() }
            } label: {
                HStack {
                    Label("All Recent Activity", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundStyle(model.accentSwiftUIColor)
                        .opacity(recentRangeSelected ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .font(.callout.weight(recentRangeSelected ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    recentRangeSelected ? model.accentSwiftUIColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .help(
                recentRangeSelected
                    ? "Showing the latest moments"
                    : "Leave the selected session and show the latest moments"
            )
            .accessibilityLabel("All Recent Activity")
            .accessibilityValue(recentRangeSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(recentRangeSelected ? .isSelected : [])
            .accessibilityIdentifier("timeline.range.recent")

            Divider()

            Label("Choose a Day", systemImage: "calendar")
                .font(.headline)

            DatePicker(
                "Day",
                selection: $dayPickerSelection,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .accessibilityLabel("Timeline day")

            Divider()

            if daySessions.isEmpty {
                Label("No captures on this day", systemImage: "moon.zzz")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Sessions")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        showDayPicker = false
                        Task { await model.selectTimelineDay(dayPickerSelection) }
                    } label: {
                        Label("Open Latest", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Open the latest session on this day")
                }

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(daySessions) { session in
                            let sessionSelected = isSelectedTimelineSession(session)
                            Button {
                                showDayPicker = false
                                guard !sessionSelected else { return }
                                Task { await model.loadSession(session) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "clock")
                                        .foregroundStyle(
                                            sessionSelected ? model.accentSwiftUIColor : .secondary
                                        )
                                    Text(SLTimeFormat.shortTime(session.startMs))
                                        .monospacedDigit()
                                    Text(session.appLabel)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(SessionPinning.summaryLabel(for: session))
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(model.accentSwiftUIColor)
                                        .opacity(sessionSelected ? 1 : 0)
                                        .accessibilityHidden(true)
                                }
                                .font(.callout.weight(sessionSelected ? .semibold : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    sessionSelected ? model.accentSwiftUIColor.opacity(0.14) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusable()
                            .help(
                                sessionSelected
                                    ? "Showing this session"
                                    : "Open session at \(SLTimeFormat.shortTime(session.startMs))"
                            )
                            .accessibilityLabel(
                                "Session at \(SLTimeFormat.shortTime(session.startMs)), \(session.appLabel)"
                            )
                            .accessibilityValue(sessionSelected ? "Selected" : "Not selected")
                            .accessibilityAddTraits(sessionSelected ? .isSelected : [])
                            .accessibilityIdentifier("timeline.session.\(session.startMs)")
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var isRecentTimelineRangeSelected: Bool {
        model.selectedSession == nil && model.timelineNavigationOrigin == .direct
    }

    private func isSelectedTimelineSession(_ session: SessionRow) -> Bool {
        model.selectedSession?.startMs == session.startMs
    }

    private var timelineRangeLabel: String {
        if let session = model.selectedSession {
            return "Session at \(SLTimeFormat.shortTime(session.startMs))"
        }
        return model.selectedTimelineFrame.map { momentDateLabel($0.timestampMs) } ?? "Choose Day"
    }

    private var timelineRangeHelp: String {
        if let session = model.selectedSession {
            return "Viewing the session from \(SLTimeFormat.shortTime(session.startMs)). Choose another day or show all recent activity."
        }
        return "Choose a day or recording session"
    }

    private var timelineRangeAccessibilityValue: String {
        if let session = model.selectedSession {
            return "Selected session, \(SLTimeFormat.shortTime(session.startMs)), \(session.appLabel)"
        }
        return model.selectedTimelineFrame.map { momentDateLabel($0.timestampMs) } ?? "No day selected"
    }

    var controlStrokeOpacity: Double {
        colorSchemeContrast == .increased ? 0.48 : 0.22
    }

    var primaryTimelineTextOpacity: Double {
        colorSchemeContrast == .increased ? 1 : 0.82
    }

    var secondaryTextOpacity: Double {
        colorSchemeContrast == .increased ? 0.92 : 0.72
    }

    var trackBackgroundOpacity: Double {
        colorSchemeContrast == .increased ? 0.28 : 0.16
    }
}
