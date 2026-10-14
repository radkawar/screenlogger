import ScreenlogCore
import SwiftUI

extension HistoryPane {
    /// Activity ribbon with proportional source bands and persistent time orientation.
    var segmentTrack: some View {
        TimelineActivityRibbon(scaleStep: $timelineScaleStep)
    }
}

/// Activity ribbon with proportional source bands and persistent time orientation.
///
/// Hover and scrub state live here instead of on `HistoryPane` so pointer motion
/// over the ribbon redraws the ribbon alone rather than the stage and both
/// control bars above it. The frame list and the activity model are memoized for
/// the same reason: neither answer can change while only the pointer moves.
struct TimelineActivityRibbon: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Binding var scaleStep: Int
    @State private var scrubWindow: TimelineWindow?
    @State private var hoveredFrame: TimelineFrame?
    @State private var cache = TimelineRibbonCache()

    var body: some View {
        let fingerprint = TimelineRibbonCache.fingerprint(model.timeline)
        let frames = cache.momentFrames(fingerprint: fingerprint) {
            model.timelineMomentFrames
        }
        return GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let scopeStart = model.selectedSession?.startMs ?? frames.first?.timestampMs
            let scopeEnd = model.selectedSession?.endMs ?? frames.last?.timestampMs
            let liveWindow = Self.timelineWindow(
                frames: frames,
                selectedTimestampMs: model.selectedTimelineFrame?.timestampMs,
                scaleStep: scaleStep,
                scopeStartMs: scopeStart,
                scopeEndMs: scopeEnd
            )
            // Retain the viewport that was visible when scrubbing began. The
            // selection changes on every drag update; allowing that selection
            // to recenter the window would move the time mapping under the
            // pointer until the gesture ends.
            let window = scrubWindow ?? liveWindow
            let activity = cache.activity(
                frames: frames,
                fingerprint: fingerprint,
                visibleStartMs: window.startMs,
                visibleEndMs: window.endMs,
                expectedCaptureIntervalMs: Int64((model.intervalSeconds * 1_000).rounded())
            )
            let contextFrame = hoveredFrame ?? model.selectedTimelineFrame
            VStack(spacing: SLDesign.space4) {
                timelineRibbonHeader(
                    frames: frames,
                    window: window,
                    scopeStartMs: scopeStart,
                    scopeEndMs: scopeEnd,
                    hoveredFrame: hoveredFrame,
                    contextFrame: contextFrame
                )

                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(trackBackgroundOpacity))
                        .frame(height: 1)
                        .accessibilityHidden(true)

                    if model.selectedSession != nil,
                        let firstLoaded = frames.first,
                        let lastLoaded = frames.last
                    {
                        let loadedX = Self.timelineX(
                            timestampMs: firstLoaded.timestampMs,
                            in: window,
                            width: w
                        )
                        let loadedEndX = Self.timelineX(
                            timestampMs: lastLoaded.timestampMs,
                            in: window,
                            width: w
                        )
                        RoundedRectangle(cornerRadius: SLDesign.space4, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                            .frame(width: max(3, loadedEndX - loadedX), height: 32)
                            .position(x: loadedX + max(3, loadedEndX - loadedX) / 2, y: 22)
                            .accessibilityHidden(true)
                    }

                    TimelineSpeechMarkers(
                        passages: model.timelineTranscriptPassages,
                        visibleStartMs: window.startMs,
                        visibleEndMs: window.endMs,
                        selectedTimestampMs: model.selectedTimelineFrame?.timestampMs,
                        width: w,
                        computerColor: model.accentSwiftUIColor
                    )

                    ForEach(activity.intervals) { interval in
                        let x = Self.timelineX(timestampMs: interval.startMs, in: window, width: w)
                        let endX = Self.timelineX(timestampMs: interval.endMs, in: window, width: w)
                        let runW = max(3, endX - x - 1.5)
                        let isSelected =
                            model.selectedTimelineFrame.map {
                                $0.timestampMs >= interval.startMs && $0.timestampMs <= interval.endMs
                            } ?? false
                        RoundedRectangle(cornerRadius: SLDesign.space4, style: .continuous)
                            .fill(isSelected ? model.accentSwiftUIColor.opacity(0.16) : Color.primary.opacity(trackBackgroundOpacity))
                            .frame(width: runW, height: 24)
                            .position(x: x + runW / 2, y: 22)
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
                            TimelineRunIdentityLabel(
                                source: interval.source,
                                momentCount: interval.momentCount,
                                showsLabel: runW >= 96,
                                maximumWidth: max(20, runW - 8)
                            )
                            .position(
                                x: min(w - 10, max(10, x + runW / 2)),
                                y: 22
                            )
                            .accessibilityHidden(true)
                        }
                    }

                    timelineGaps(activity: activity, window: window, width: w)

                    if let selected = model.selectedTimelineFrame, frames.count > 1 {
                        let x = Self.timelineX(timestampMs: selected.timestampMs, in: window, width: w)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(model.accentSwiftUIColor)
                            .frame(width: 3, height: 32)
                            .overlay {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                            }
                            .position(x: min(w - 2, max(2, x)), y: 22)
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: 44)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let activeWindow = scrubWindow ?? window
                            if scrubWindow == nil {
                                scrubWindow = activeWindow
                            }
                            let target = Self.timelineTimestamp(
                                x: value.location.x,
                                in: activeWindow,
                                width: w
                            )
                            guard Self.loadedRangeContains(target, frames: frames),
                                let selection = activity.selection(at: target)
                            else { return }
                            model.stopReplay()
                            model.selectTimelineFrame(id: selection.frameID)
                        }
                        .onEnded { value in
                            let activeWindow = scrubWindow ?? window
                            let target = Self.timelineTimestamp(
                                x: value.location.x,
                                in: activeWindow,
                                width: w
                            )
                            if Self.loadedRangeContains(target, frames: frames),
                                let selection = activity.selection(at: target)
                            {
                                model.stopReplay()
                                model.selectTimelineFrame(id: selection.frameID)
                            } else if model.selectedSession != nil {
                                model.stopReplay()
                                Task {
                                    await model.loadSelectedSessionWindow(
                                        aroundTimestampMs: target
                                    )
                                }
                            }
                            scrubWindow = nil
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
                        let hoveredID = selection?.crossedGap == true ? nil : selection?.frameID
                        updateHoveredFrame(id: hoveredID, in: frames)
                    case .ended:
                        hoveredFrame = nil
                    }
                }

                if !frames.isEmpty {
                    HStack {
                        Text(SLTimeFormat.shortTime(window.startMs))
                        Spacer()
                        if let selected = model.selectedTimelineFrame {
                            Text(SLTimeFormat.shortTime(selected.timestampMs))
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .accessibilityLabel("Selected moment")
                                .accessibilityValue(timelinePositionAccessibilityValue)
                                .accessibilityIdentifier("timeline.navigation.position")
                        }
                        Spacer()
                        Text(SLTimeFormat.shortTime(window.endMs))
                    }
                    .font(SLDesign.metadataFont.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 96)
        // The pointer can rest still while a session page loads. Drop the
        // remembered moment rather than describing rows that are gone.
        .onChange(of: fingerprint) { _, _ in
            hoveredFrame = nil
        }
        .background {
            TimelineHorizontalScrollMonitor { direction in
                model.stopReplay()
                // Move in useful groups while preserving ordinary arrow-key
                // precision. Crossing a loaded edge fetches the adjacent page.
                model.stepTimeline(by: direction * 10)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline navigation")
        .accessibilityValue(timelineAccessibilityValue)
        .accessibilityHint(
            "Drag to move through moments. Scroll horizontally to browse. Adjust to move one moment at a time."
        )
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

    private func timelineGaps(
        activity: TimelineActivityPresentation,
        window: TimelineWindow,
        width: CGFloat
    ) -> some View {
        ForEach(activity.gaps) { gap in
            let x = Self.timelineX(timestampMs: gap.startMs, in: window, width: width)
            let endX = Self.timelineX(timestampMs: gap.endMs, in: window, width: width)
            let gapWidth = max(1, endX - x)
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: gapWidth, height: 44)
                .position(x: x + gapWidth / 2, y: 22)
                .help(Self.gapHelp(gap))
                .accessibilityElement()
                .accessibilityLabel("No captures")
                .accessibilityValue(Self.gapAccessibilityValue(gap))
                .accessibilityHint(
                    "Select the nearest captured moment. If two moments are equally near, Screenlogger selects the earlier one."
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
                    .font(SLDesign.metadataFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, SLDesign.space4)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .position(x: x + gapWidth / 2, y: 22)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private struct TimelineRangeOption: Identifiable {
        let step: Int
        let durationMs: Int64

        var id: Int { step }
    }

    private func timelineRibbonHeader(
        frames: [TimelineFrame],
        window: TimelineWindow,
        scopeStartMs: Int64?,
        scopeEndMs: Int64?,
        hoveredFrame: TimelineFrame?,
        contextFrame: TimelineFrame?
    ) -> some View {
        HStack(spacing: 8) {
            if let contextFrame {
                TimelineSourceIcon(frame: contextFrame, size: 16)
                    .accessibilityHidden(true)
                HStack(spacing: SLDesign.space8) {
                    Text(contextFrame.appLabel)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if hoveredFrame != nil {
                        Text(SLTimeFormat.shortTime(contextFrame.timestampMs))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if let domain = contextFrame.domain, !domain.isEmpty {
                        Text(domain)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(hoveredFrame == nil ? "Selected moment" : "Moment under pointer")
                .accessibilityValue(Self.sourceContextValue(contextFrame))
                .accessibilityIdentifier("timeline.navigation.context")
                .help(hoveredFrame == nil ? "Selected moment" : "Moment under the pointer")
            } else {
                Text("Activity")
            }

            Spacer(minLength: 8)

            HStack(spacing: 3) {
                if model.selectedSession != nil {
                    sessionPageButton(direction: .earlier)
                }
                timelineRangeMenu(
                    frames: frames,
                    window: window,
                    scopeStartMs: scopeStartMs,
                    scopeEndMs: scopeEndMs
                )
                if model.selectedSession != nil {
                    sessionPageButton(direction: .later)
                }
            }
        }
        .font(SLDesign.bodyFont)
        .foregroundStyle(.primary)
    }

    private func timelineRangeMenu(
        frames: [TimelineFrame],
        window: TimelineWindow,
        scopeStartMs: Int64?,
        scopeEndMs: Int64?
    ) -> some View {
        let options = Self.timelineRangeOptions(
            frames: frames,
            scopeStartMs: scopeStartMs,
            scopeEndMs: scopeEndMs
        )
        let visibleLabel = Self.timelineSpanLabel(
            window.durationMs,
            isFull: scaleStep == 0
        )

        return Menu {
            ForEach(options) { option in
                Button {
                    scaleStep = option.step
                } label: {
                    if option.step == scaleStep {
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
            HStack(spacing: SLDesign.space4) {
                Text("View:")
                Text(visibleLabel)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
            .frame(minHeight: 28)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(SLDesign.metadataFont)
        .foregroundStyle(.secondary)
        .help("Choose how much time is visible in the activity ribbon")
        .accessibilityLabel("Timeline range")
        .accessibilityValue(
            Self.timelineSpanAccessibilityLabel(
                window.durationMs,
                isFull: scaleStep == 0
            )
        )
        .accessibilityHint("Choose how much time is visible in the activity ribbon")
        .accessibilityIdentifier("timeline.navigation.range")
    }

    private static func timelineRangeOptions(
        frames: [TimelineFrame],
        scopeStartMs: Int64?,
        scopeEndMs: Int64?
    ) -> [TimelineRangeOption] {
        var options: [TimelineRangeOption] = []
        var seenDurations = Set<Int64>()

        for step in 0...6 {
            let duration = timelineWindow(
                frames: frames,
                selectedTimestampMs: nil,
                scaleStep: step,
                scopeStartMs: scopeStartMs,
                scopeEndMs: scopeEndMs
            ).durationMs
            guard seenDurations.insert(duration).inserted else { continue }
            options.append(TimelineRangeOption(step: step, durationMs: duration))
        }

        return options
    }

    private static func timelineWindow(
        frames: [TimelineFrame],
        selectedTimestampMs: Int64?,
        scaleStep: Int,
        scopeStartMs: Int64? = nil,
        scopeEndMs: Int64? = nil
    ) -> TimelineWindow {
        guard let firstTimestamp = scopeStartMs ?? frames.first?.timestampMs,
            let lastTimestamp = scopeEndMs ?? frames.last?.timestampMs
        else {
            return TimelineWindow(startMs: 0, endMs: 1)
        }
        return TimelineRibbonMapping.window(
            firstTimestampMs: firstTimestamp,
            lastTimestampMs: lastTimestamp,
            selectedTimestampMs: selectedTimestampMs,
            scaleStep: scaleStep
        )
    }

    private enum SessionPageDirection: Equatable {
        case earlier
        case later
    }

    private func sessionPageButton(direction: SessionPageDirection) -> some View {
        let isEarlier = direction == .earlier
        let enabled =
            isEarlier
            ? model.canLoadEarlierSessionWindow
            : model.canLoadLaterSessionWindow
        return Button {
            Task {
                if isEarlier {
                    await model.loadEarlierSessionWindow()
                } else {
                    await model.loadLaterSessionWindow()
                }
            }
        } label: {
            Image(systemName: isEarlier ? "chevron.left" : "chevron.right")
                .frame(width: 20, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(isEarlier ? "Load earlier moments" : "Load later moments")
        .accessibilityLabel(isEarlier ? "Earlier session moments" : "Later session moments")
        .accessibilityHint("Loads the next part of this long session")
        .accessibilityIdentifier(
            isEarlier ? "timeline.navigation.earlier-page" : "timeline.navigation.later-page"
        )
    }

    private static func loadedRangeContains(_ timestampMs: Int64, frames: [TimelineFrame]) -> Bool {
        guard let first = frames.first, let last = frames.last else { return false }
        return first.timestampMs <= timestampMs && timestampMs <= last.timestampMs
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
        if model.selectedSession != nil, let selected = model.selectedTimelineFrame {
            return "selected time \(SLTimeFormat.shortTime(selected.timestampMs)) within session"
        }
        return model.selectedTimelineMomentIndex.map {
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

    /// Resolve the moment under the pointer when it actually changes. Pointer
    /// motion delivers a continuous stream of positions that mostly land on the
    /// moment already shown, so the list scan stays out of the redraw path.
    private func updateHoveredFrame(id: Int64?, in frames: [TimelineFrame]) {
        guard let id else {
            if hoveredFrame != nil { hoveredFrame = nil }
            return
        }
        guard hoveredFrame?.id != id else { return }
        hoveredFrame = frames.first(where: { $0.id == id })
    }

    private var trackBackgroundOpacity: Double {
        colorSchemeContrast == .increased ? 0.22 : 0.09
    }
}

/// Memoized ribbon inputs.
///
/// Both the representative frame list and the activity model are derived from
/// the loaded Timeline rows and the visible window. Rebuilding them on every
/// body pass meant hundreds of value copies and per-frame source identities for
/// each hover, scrub, and replay tick, so they are recomputed only when the
/// rows or the window actually change.
@MainActor
final class TimelineRibbonCache {
    private struct ActivityKey: Equatable {
        let fingerprint: UInt64
        let visibleStartMs: Int64
        let visibleEndMs: Int64
        let expectedCaptureIntervalMs: Int64
    }

    private var framesFingerprint: UInt64?
    private var frames: [TimelineFrame] = []
    private var activityKey: ActivityKey?
    private var activityPresentation: TimelineActivityPresentation?

    /// FNV-1a over the identity and capture time of every loaded row. An integer
    /// sweep costs a small fraction of the work it protects, and it notices row
    /// changes that a count-and-endpoints comparison would miss.
    static func fingerprint(_ rows: [TimelineFrame]) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for row in rows {
            hash = (hash ^ UInt64(bitPattern: row.id)) &* 1_099_511_628_211
            hash = (hash ^ UInt64(bitPattern: row.timestampMs)) &* 1_099_511_628_211
        }
        return hash
    }

    func momentFrames(fingerprint: UInt64, build: () -> [TimelineFrame]) -> [TimelineFrame] {
        if framesFingerprint == fingerprint { return frames }
        framesFingerprint = fingerprint
        frames = build()
        return frames
    }

    func activity(
        frames: [TimelineFrame],
        fingerprint: UInt64,
        visibleStartMs: Int64,
        visibleEndMs: Int64,
        expectedCaptureIntervalMs: Int64
    ) -> TimelineActivityPresentation {
        let requested = ActivityKey(
            fingerprint: fingerprint,
            visibleStartMs: visibleStartMs,
            visibleEndMs: visibleEndMs,
            expectedCaptureIntervalMs: expectedCaptureIntervalMs
        )
        if activityKey == requested, let activityPresentation { return activityPresentation }
        let built = TimelineActivityPresentation(
            chronologicalFrames: frames,
            visibleStartMs: visibleStartMs,
            visibleEndMs: visibleEndMs,
            expectedCaptureIntervalMs: expectedCaptureIntervalMs
        )
        activityKey = requested
        activityPresentation = built
        return built
    }
}

/// Window-local scroll routing for the ribbon. SwiftUI on macOS 14 does not
/// expose scroll-wheel events directly, so this transparent view observes only
/// horizontal gestures whose pointer is inside its own bounds. Vertical page
/// scrolling and every event elsewhere in the window remain untouched.
private struct TimelineHorizontalScrollMonitor: NSViewRepresentable {
    let onScroll: (Int) -> Void

    func makeNSView(context: Context) -> ScrollCatcherView {
        let view = ScrollCatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollCatcherView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class ScrollCatcherView: NSView {
        var onScroll: ((Int) -> Void)?
        private var monitor: Any?
        private var accumulatedDelta: CGFloat = 0
        private var lastDispatchAt = Date.distantPast

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tearDown()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window,
                    window.isKeyWindow,
                    event.windowNumber == window.windowNumber
                else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }

                let usesShiftWheel = event.modifierFlags.contains(.shift)
                let horizontal = usesShiftWheel ? event.scrollingDeltaY : event.scrollingDeltaX
                guard abs(horizontal) > abs(usesShiftWheel ? event.scrollingDeltaX : event.scrollingDeltaY),
                    abs(horizontal) > 0.1
                else { return event }

                self.accumulatedDelta += horizontal
                let now = Date()
                guard abs(self.accumulatedDelta) >= 18,
                    now.timeIntervalSince(self.lastDispatchAt) >= 0.08
                else { return nil }
                let direction = self.accumulatedDelta > 0 ? -1 : 1
                self.accumulatedDelta = 0
                self.lastDispatchAt = now
                DispatchQueue.main.async { [weak self] in self?.onScroll?(direction) }
                return nil
            }
        }

        override func removeFromSuperview() {
            tearDown()
            super.removeFromSuperview()
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func tearDown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            accumulatedDelta = 0
        }
    }
}

private struct TimelineSpeechMarkers: View {
    let passages: [TimelineTranscriptPresentation.Passage]
    let visibleStartMs: Int64
    let visibleEndMs: Int64
    let selectedTimestampMs: Int64?
    let width: CGFloat
    let computerColor: Color

    private var visiblePassages: [TimelineTranscriptPresentation.Passage] {
        passages.filter {
            $0.endTimestampMs >= visibleStartMs && $0.startTimestampMs <= visibleEndMs
        }
    }

    var body: some View {
        ForEach(visiblePassages) { passage in
            TimelineSpeechMarker(
                passage: passage,
                x: timelineX(max(visibleStartMs, passage.startTimestampMs)),
                endX: timelineX(min(visibleEndMs, passage.endTimestampMs)),
                isActive: selectedTimestampMs.map { passage.contains(timestampMs: $0) } ?? false,
                color: passage.source == .microphone ? .secondary : computerColor
            )
        }
    }

    private func timelineX(_ timestampMs: Int64) -> CGFloat {
        TimelineRibbonMapping.x(
            timestampMs: timestampMs,
            in: TimelineRibbonMapping.Window(
                startMs: visibleStartMs,
                endMs: visibleEndMs
            ),
            width: width
        )
    }
}

private struct TimelineSpeechMarker: View {
    let passage: TimelineTranscriptPresentation.Passage
    let x: CGFloat
    let endX: CGFloat
    let isActive: Bool
    let color: Color

    private var markerWidth: CGFloat { max(3, endX - x) }

    var body: some View {
        Capsule(style: .continuous)
            .fill(color.opacity(isActive ? 1 : 0.62))
            .frame(width: markerWidth, height: isActive ? 5 : 3)
            .position(x: x + markerWidth / 2, y: 4)
            .help(
                "\(passage.source.label) transcript, \(SLTimeFormat.shortTime(passage.startTimestampMs))"
            )
            .accessibilityElement()
            .accessibilityLabel("\(passage.source.label) speech")
            .accessibilityValue(
                "\(SLTimeFormat.shortTime(passage.startTimestampMs)) to \(SLTimeFormat.shortTime(passage.endTimestampMs))"
            )
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

private struct TimelineRunIdentityLabel: View {
    let source: TimelineActivityPresentation.Source
    let momentCount: Int
    let showsLabel: Bool
    let maximumWidth: CGFloat

    var body: some View {
        HStack(spacing: SLDesign.space4) {
            TimelineSourceIcon(source: source, size: 16)
            if showsLabel {
                Text(source.appLabel)
                    .font(SLDesign.metadataFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: maximumWidth)
        .foregroundStyle(.primary)
        .help("\(source.appLabel), \(momentCount) captured moment\(momentCount == 1 ? "" : "s")")
        .accessibilityHidden(true)
    }
}
