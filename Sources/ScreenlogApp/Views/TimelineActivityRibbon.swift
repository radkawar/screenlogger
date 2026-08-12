import ScreenlogCore
import SwiftUI

extension HistoryPane {
    /// Activity ribbon with proportional source bands and persistent time orientation.
    var segmentTrack: some View {
        let frames = model.timelineMomentFrames
        return GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let liveWindow = Self.timelineWindow(
                frames: frames,
                selectedTimestampMs: model.selectedTimelineFrame?.timestampMs,
                scaleStep: timelineScaleStep
            )
            // Retain the viewport that was visible when scrubbing began. The
            // selection changes on every drag update; allowing that selection
            // to recenter the window would move the time mapping under the
            // pointer until the gesture ends.
            let window = timelineScrubWindow ?? liveWindow
            let activity = TimelineActivityPresentation(
                chronologicalFrames: frames,
                visibleStartMs: window.startMs,
                visibleEndMs: window.endMs,
                expectedCaptureIntervalMs: Int64((model.intervalSeconds * 1_000).rounded())
            )
            let visibleTranscriptPassages = model.timelineTranscriptPassages.filter {
                $0.endTimestampMs >= window.startMs && $0.startTimestampMs <= window.endMs
            }
            let hoveredFrame = frames.first(where: { $0.id == hoveredTimelineFrameID })
            let contextFrame = hoveredFrame ?? model.selectedTimelineFrame
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    if let contextFrame {
                        TimelineSourceIcon(frame: contextFrame, size: 16)
                            .accessibilityHidden(true)
                        HStack(spacing: 5) {
                            Text(SLTimeFormat.shortTime(contextFrame.timestampMs))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                            Divider()
                                .frame(height: 10)
                                .overlay(.white.opacity(secondaryTextOpacity))
                                .accessibilityHidden(true)
                            Text(contextFrame.appLabel)
                                .lineLimit(1)
                            if let domain = contextFrame.domain, !domain.isEmpty {
                                Text(domain)
                                    .lineLimit(1)
                                    .foregroundStyle(.white.opacity(secondaryTextOpacity))
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(hoveredFrame == nil ? "Selected moment" : "Moment under pointer")
                        .accessibilityValue(Self.sourceContextValue(contextFrame))
                        .accessibilityIdentifier("timeline.navigation.context")
                        .help(hoveredFrame == nil ? "Selected moment" : "Moment under the pointer")
                    } else {
                        Label("Time scale", systemImage: "clock")
                    }

                    Spacer(minLength: 8)

                    timelineRangeMenu(frames: frames, window: window)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(primaryTimelineTextOpacity))

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(trackBackgroundOpacity))
                        .frame(height: 8)
                        .accessibilityHidden(true)

                    ForEach(visibleTranscriptPassages) { passage in
                        let startMs = max(window.startMs, passage.startTimestampMs)
                        let endMs = min(window.endMs, passage.endTimestampMs)
                        let x = Self.timelineX(timestampMs: startMs, in: window, width: w)
                        let endX = Self.timelineX(timestampMs: endMs, in: window, width: w)
                        let markerWidth = max(3, endX - x)
                        let isActive = passage.contains(
                            timestampMs: model.selectedTimelineFrame?.timestampMs ?? Int64.min
                        )
                        Capsule(style: .continuous)
                            .fill(speechMarkerColor(for: passage.source).opacity(isActive ? 1 : 0.62))
                            .frame(width: markerWidth, height: isActive ? 5 : 3)
                            .shadow(
                                color: isActive
                                    ? speechMarkerColor(for: passage.source).opacity(0.55)
                                    : .clear,
                                radius: 3
                            )
                            .position(x: x + markerWidth / 2, y: 3)
                            .help(
                                "\(passage.source.label) transcript, \(SLTimeFormat.shortTime(passage.startTimestampMs))"
                            )
                            .accessibilityElement()
                            .accessibilityLabel("\(passage.source.label) speech")
                            .accessibilityValue(
                                "\(SLTimeFormat.shortTime(passage.startTimestampMs)) to \(SLTimeFormat.shortTime(passage.endTimestampMs))"
                            )
                    }

                    ForEach(activity.intervals) { interval in
                        let x = Self.timelineX(timestampMs: interval.startMs, in: window, width: w)
                        let endX = Self.timelineX(timestampMs: interval.endMs, in: window, width: w)
                        let runW = max(3, endX - x - 1.5)
                        Capsule(style: .continuous)
                            .fill(segmentColor(for: interval.source).opacity(0.9))
                            .frame(width: runW, height: 8)
                            .position(x: x + runW / 2, y: 14)
                            .help(Self.intervalHelp(interval))
                            .accessibilityElement()
                            .accessibilityLabel("\(interval.source.appLabel) captured activity")
                            .accessibilityValue(Self.intervalAccessibilityValue(interval))
                            .accessibilityHint("Activate to select a moment in this activity")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction {
                                let midpoint = interval.startMs + interval.durationMs / 2
                                guard let selection = activity.selection(at: midpoint) else { return }
                                model.stopReplay()
                                model.selectTimelineFrame(id: selection.frameID)
                            }
                    }

                    ForEach(activity.intervals) { interval in
                        let x = Self.timelineX(timestampMs: interval.startMs, in: window, width: w)
                        let endX = Self.timelineX(timestampMs: interval.endMs, in: window, width: w)
                        let runW = max(3, endX - x - 1.5)
                        if runW >= 24 {
                            TimelineRunIdentityBadge(
                                source: interval.source,
                                momentCount: interval.momentCount,
                                showsLabel: runW >= 78,
                                maximumWidth: max(20, runW - 4),
                                strokeOpacity: controlStrokeOpacity
                            )
                            .position(
                                x: min(w - 10, max(10, x + runW / 2)),
                                y: 14
                            )
                            .accessibilityHidden(true)
                        }
                    }

                    ForEach(activity.gaps) { gap in
                        let x = Self.timelineX(timestampMs: gap.startMs, in: window, width: w)
                        let endX = Self.timelineX(timestampMs: gap.endMs, in: window, width: w)
                        let gapWidth = max(1, endX - x)
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .frame(width: gapWidth, height: 28)
                            .position(x: x + gapWidth / 2, y: 14)
                            .help(Self.gapHelp(gap))
                            .accessibilityElement()
                            .accessibilityLabel("No captures")
                            .accessibilityValue(Self.gapAccessibilityValue(gap))
                            .accessibilityHint(
                                "Activate to choose the closest captured moment; a tie chooses the earlier one"
                            )
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction {
                                let midpoint = gap.startMs + gap.durationMs / 2
                                guard let selection = activity.selection(at: midpoint) else { return }
                                model.stopReplay()
                                model.selectTimelineFrame(id: selection.frameID)
                            }

                        if gapWidth >= 90 {
                            Text("No captures")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(secondaryTextOpacity))
                                .padding(.horizontal, 5)
                                .background(Color.black.opacity(0.72))
                                .position(x: x + gapWidth / 2, y: 14)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }

                    if let selected = model.selectedTimelineFrame, frames.count > 1 {
                        let x = Self.timelineX(timestampMs: selected.timestampMs, in: window, width: w)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.white)
                            .frame(width: 4, height: 24)
                            .overlay {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
                            }
                            .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                            .position(x: x, y: 14)
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let scrubWindow = timelineScrubWindow ?? window
                            if timelineScrubWindow == nil {
                                timelineScrubWindow = scrubWindow
                            }
                            guard
                                let selection = activity.selection(
                                    at: Self.timelineTimestamp(
                                        x: value.location.x,
                                        in: scrubWindow,
                                        width: w
                                    )
                                )
                            else { return }
                            model.stopReplay()
                            model.selectTimelineFrame(id: selection.frameID)
                        }
                        .onEnded { value in
                            let scrubWindow = timelineScrubWindow ?? window
                            if let selection = activity.selection(
                                at: Self.timelineTimestamp(
                                    x: value.location.x,
                                    in: scrubWindow,
                                    width: w
                                )
                            ) {
                                model.stopReplay()
                                model.selectTimelineFrame(id: selection.frameID)
                            }
                            timelineScrubWindow = nil
                        }
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let selection = activity.selection(
                            at: Self.timelineTimestamp(x: location.x, in: window, width: w)
                        )
                        // A gap has no source identity. Keep the header on the
                        // selected moment instead of attributing empty time to
                        // whichever boundary happened to be closest.
                        hoveredTimelineFrameID = selection?.crossedGap == true ? nil : selection?.frameID
                    case .ended:
                        hoveredTimelineFrameID = nil
                    }
                }

                if !frames.isEmpty {
                    HStack {
                        Text(SLTimeFormat.shortTime(window.startMs))
                        Spacer()
                        if let selected = model.selectedTimelineFrame {
                            Text(SLTimeFormat.shortTime(selected.timestampMs))
                                .fontWeight(.semibold)
                                .foregroundStyle(.white.opacity(0.92))
                                .accessibilityLabel("Selected moment")
                                .accessibilityValue(timelinePositionAccessibilityValue)
                                .accessibilityIdentifier("timeline.navigation.position")
                        }
                        Spacer()
                        Text(SLTimeFormat.shortTime(window.endMs))
                    }
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(secondaryTextOpacity))
                }
            }
        }
        .frame(height: 76)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline navigation")
        .accessibilityValue(timelineAccessibilityValue)
        .accessibilityHint("Drag to scrub, or adjust to move one moment at a time")
        .accessibilityIdentifier("timeline.navigation")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                model.stopReplay()
                model.stepTimeline(by: 1)
            case .decrement:
                model.stopReplay()
                model.stepTimeline(by: -1)
            @unknown default:
                break
            }
        }
    }

    private typealias TimelineWindow = TimelineRibbonMapping.Window

    private struct TimelineRangeOption: Identifiable {
        let step: Int
        let durationMs: Int64

        var id: Int { step }
    }

    private func timelineRangeMenu(
        frames: [TimelineFrame],
        window: TimelineWindow
    ) -> some View {
        let options = Self.timelineRangeOptions(frames: frames)
        let visibleLabel = Self.timelineSpanLabel(
            window.durationMs,
            isFull: timelineScaleStep == 0
        )

        return Menu {
            ForEach(options) { option in
                Button {
                    timelineScaleStep = option.step
                } label: {
                    if option.step == timelineScaleStep {
                        Label(
                            Self.timelineSpanLabel(
                                option.durationMs,
                                isFull: option.step == 0
                            ),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(
                            Self.timelineSpanLabel(
                                option.durationMs,
                                isFull: option.step == 0
                            )
                        )
                    }
                }
                .accessibilityIdentifier("timeline.navigation.range.option.\(option.step)")
            }
        } label: {
            HStack(spacing: 5) {
                Label("Range", systemImage: "arrow.left.and.right")
                Text(visibleLabel)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(secondaryTextOpacity))
            }
            .contentShape(Rectangle())
            .frame(minHeight: 28)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose how much time is visible in the activity ribbon")
        .accessibilityLabel("Timeline range")
        .accessibilityValue(
            Self.timelineSpanAccessibilityLabel(
                window.durationMs,
                isFull: timelineScaleStep == 0
            )
        )
        .accessibilityHint("Choose how much time is visible in the activity ribbon")
        .accessibilityIdentifier("timeline.navigation.range")
    }

    private static func timelineRangeOptions(frames: [TimelineFrame]) -> [TimelineRangeOption] {
        var options: [TimelineRangeOption] = []
        var seenDurations = Set<Int64>()

        for step in 0...6 {
            let duration = timelineWindow(
                frames: frames,
                selectedTimestampMs: nil,
                scaleStep: step
            ).durationMs
            guard seenDurations.insert(duration).inserted else { continue }
            options.append(TimelineRangeOption(step: step, durationMs: duration))
        }

        return options
    }

    private static func timelineWindow(
        frames: [TimelineFrame],
        selectedTimestampMs: Int64?,
        scaleStep: Int
    ) -> TimelineWindow {
        guard let first = frames.first, let last = frames.last else {
            return TimelineWindow(startMs: 0, endMs: 1)
        }
        return TimelineRibbonMapping.window(
            firstTimestampMs: first.timestampMs,
            lastTimestampMs: last.timestampMs,
            selectedTimestampMs: selectedTimestampMs,
            scaleStep: scaleStep
        )
    }

    private static func timelineX(timestampMs: Int64, in window: TimelineWindow, width: CGFloat) -> CGFloat {
        TimelineRibbonMapping.x(timestampMs: timestampMs, in: window, width: width)
    }

    private static func timelineTimestamp(x: CGFloat, in window: TimelineWindow, width: CGFloat) -> Int64 {
        TimelineRibbonMapping.timestamp(x: x, in: window, width: width)
    }

    private static func timelineSpanLabel(_ durationMs: Int64, isFull: Bool) -> String {
        if isFull { return "Full range" }
        let seconds = max(1, durationMs / 1000)
        if seconds < 60 { return "\(seconds) sec" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours) hr" : "\(hours)h \(remainingMinutes)m"
    }

    private static func timelineSpanAccessibilityLabel(
        _ durationMs: Int64,
        isFull: Bool
    ) -> String {
        if isFull { return "Full Timeline range" }
        let seconds = max(1, durationMs / 1_000)
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) minutes" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0
            ? "\(hours) hours"
            : "\(hours) hours, \(remainingMinutes) minutes"
    }

    private static func intervalHelp(_ interval: TimelineActivityPresentation.Interval) -> String {
        "\(interval.source.appLabel), \(interval.momentCount) captured moment\(interval.momentCount == 1 ? "" : "s")"
    }

    private static func intervalAccessibilityValue(
        _ interval: TimelineActivityPresentation.Interval
    ) -> String {
        "\(interval.momentCount) captured moment\(interval.momentCount == 1 ? "" : "s"), "
            + "\(SLTimeFormat.shortTime(interval.startMs)) to \(SLTimeFormat.shortTime(interval.endMs))"
    }

    private static func gapHelp(_ gap: TimelineActivityPresentation.Gap) -> String {
        "No captures for \(durationLabel(gap.durationMs))"
    }

    private static func gapAccessibilityValue(_ gap: TimelineActivityPresentation.Gap) -> String {
        "\(SLTimeFormat.shortTime(gap.startMs)) to \(SLTimeFormat.shortTime(gap.endMs)), "
            + durationLabel(gap.durationMs)
    }

    private static func durationLabel(_ durationMs: Int64) -> String {
        let seconds = max(1, durationMs / 1_000)
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if remainingSeconds == 0 { return "\(minutes) minutes" }
        return "\(minutes) minutes \(remainingSeconds) seconds"
    }

    private var timelineAccessibilityValue: String {
        guard let selected = model.selectedTimelineFrame else { return "No moment selected" }
        return "\(Self.sourceContextValue(selected)), \(timelinePositionAccessibilityValue)"
    }

    private var timelinePositionAccessibilityValue: String {
        model.selectedTimelineMomentIndex.map {
            "moment \($0 + 1) of \(model.timelineMomentCount)"
        } ?? "selected moment"
    }

    private static func sourceContextValue(_ frame: TimelineFrame) -> String {
        let source: String
        if let domain = frame.domain, !domain.isEmpty {
            source = "\(frame.appLabel), \(domain)"
        } else {
            source = frame.appLabel
        }
        return "\(source), \(SLTimeFormat.full(frame.timestampMs))"
    }

    private func segmentColor(for _: TimelineActivityPresentation.Source) -> Color {
        // The ribbon communicates captured activity, not an arbitrary app
        // category. Source identity remains available through the icon and
        // hover/VoiceOver context without assigning every app a random hue.
        model.accentSwiftUIColor
    }

    private func speechMarkerColor(for source: TranscriptSource) -> Color {
        source == .microphone ? .white : model.accentSwiftUIColor
    }
}

/// Compact source identity used by the activity ribbon. App icons take priority;
/// website favicons cover browser-only records without a bundle identifier.
private struct TimelineSourceIcon: View {
    let bundleID: String?
    let domain: String?
    let size: CGFloat

    init(frame: TimelineFrame, size: CGFloat) {
        bundleID = frame.bundleID
        domain = frame.domain
        self.size = size
    }

    init(source: TimelineActivityPresentation.Source, size: CGFloat) {
        bundleID = source.bundleID
        domain = source.domain
        self.size = size
    }

    @ViewBuilder
    var body: some View {
        if let bundleID, !bundleID.isEmpty {
            SLAppIconView(bundleID: bundleID, size: size)
        } else if let domain, !domain.isEmpty {
            SLFaviconView(domain: domain, size: size)
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: size * 0.72, weight: .medium))
                .frame(width: size, height: size)
        }
    }
}

private struct TimelineRunIdentityBadge: View {
    let source: TimelineActivityPresentation.Source
    let momentCount: Int
    let showsLabel: Bool
    let maximumWidth: CGFloat
    let strokeOpacity: Double

    var body: some View {
        HStack(spacing: 4) {
            TimelineSourceIcon(source: source, size: 13)
            if showsLabel {
                Text(source.appLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(3)
        .frame(maxWidth: maximumWidth)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.white.opacity(strokeOpacity), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        .help("\(source.appLabel), \(momentCount) captured moment\(momentCount == 1 ? "" : "s")")
        .accessibilityHidden(true)
    }
}
