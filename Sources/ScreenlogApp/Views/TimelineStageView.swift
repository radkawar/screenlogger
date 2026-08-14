import AppKit
import ScreenlogCore
import SwiftUI

extension HistoryPane {
    /// Full-bleed capture (edge to edge, no card chrome).
    var memoryStage: some View {
        stageWithDisplayAccessibility
            .accessibilityAction(named: Text(model.isReplaying ? "Pause replay" : "Play through moments")) {
                TimelinePlaybackControl.toggle(model)
            }
            .accessibilityAction(named: Text("Center zoomed moment")) {
                stagePanOffset = .zero
                stagePanGestureStart = nil
            }
            .onChange(of: model.selectedTimelineID) { _, _ in
                stagePanOffset = .zero
                stagePanGestureStart = nil
            }
    }

    private var stageCanvas: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if model.selectedFrameExtracting {
                    ProgressView()
                        .tint(.white)
                        .accessibilityLabel("Loading captured moment")
                } else if let img = model.selectedFrameImage {
                    let sourceSize = stageSourceSize(for: img)
                    let panOffset = TimelineStagePanGeometry.clampedOffset(
                        stagePanOffset,
                        sourceSize: sourceSize,
                        viewportSize: geometry.size,
                        zoom: model.stageZoom
                    )
                    stageImageWithHighlights(
                        img,
                        sourceSize: sourceSize,
                        panOffset: panOffset
                    )
                } else if let frame = model.selectedTimelineFrame,
                    frame.imagePath == nil,
                    frame.videoID == nil
                {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.clock")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.white.opacity(0.38))
                            .accessibilityHidden(true)
                        Text("Preview no longer available")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.88))
                        Text("Screenlogger kept the searchable text, app, and time for this moment.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(secondaryTextOpacity))
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Preview no longer available. Searchable text, app, and time remain.")
                    .accessibilityIdentifier("timeline.preview.unavailable")
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 40, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(stageDragGesture(viewportSize: geometry.size))
            .onChange(of: model.stageZoom) { _, _ in
                clampStagePan(to: geometry.size)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stageWithContextActions: some View {
        stageCanvas
            .contextMenu {
                if model.canCopySelectedFrameImage {
                    Button {
                        model.copySelectedFrameImage()
                    } label: {
                        Label("Copy Image", systemImage: "photo.on.rectangle.angled")
                    }
                    .accessibilityIdentifier("timeline.moment.context.copy-image")
                }
                if model.canCopySelectedOCRText {
                    Button {
                        model.copySelectedOCRText()
                    } label: {
                        Label("Copy Text", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("timeline.moment.context.copy-text")
                }
                if model.showOpenExternally {
                    Button {
                        model.openSelectedExternally()
                    } label: {
                        Label("Open Source", systemImage: "arrow.up.forward.app")
                    }
                    .disabled(!model.canOpenSelectedExternally)
                    .accessibilityIdentifier("timeline.moment.context.open-source")
                }
                if let frame = model.selectedTimelineFrame {
                    Divider()
                    Button(role: .destructive) {
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
                    .accessibilityIdentifier("timeline.moment.context.delete")
                }
            }
    }

    private var stageWithMomentAccessibility: some View {
        stageWithContextActions
            .onTapGesture(count: 2) {
                TimelinePlaybackControl.toggle(model)
            }
            // The stage is the explicit focus owner for bare Timeline shortcuts.
            // Full Keyboard Access can move to controls below it without the
            // window-wide key monitor stealing Space or arrow-key activation.
            .focusable()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Captured moment")
            .accessibilityValue(stageAccessibilityValue)
            .accessibilityHint(stageAccessibilityHint)
            .accessibilityIdentifier("timeline.moment")
            .accessibilityAction(named: Text("Previous moment")) {
                guard model.canStepBack else { return }
                model.stopReplay()
                model.stepTimeline(by: -1)
            }
            .accessibilityAction(named: Text("Next moment")) {
                guard model.canStepForward else { return }
                model.stopReplay()
                model.stepTimeline(by: 1)
            }
    }

    private var stageWithDisplayAccessibility: some View {
        stageWithMomentAccessibility
            .accessibilityAction(named: Text("Previous display")) {
                model.stopReplay()
                model.stepTimelineDisplay(by: -1)
            }
            .accessibilityAction(named: Text("Next display")) {
                model.stopReplay()
                model.stepTimelineDisplay(by: 1)
            }
    }

    func previewIssueView(_ issue: TimelinePreviewIssue) -> some View {
        VStack(spacing: 14) {
            Image(systemName: issue.systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.72))
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(issue.title)
                    .font(.headline)
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(secondaryTextOpacity))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            HStack(spacing: 10) {
                if model.canCopySelectedOCRText {
                    Button("Copy Text") {
                        model.copySelectedOCRText()
                    }
                    .buttonStyle(.bordered)
                }

                if issue.canRetry {
                    Button {
                        if issue == .momentMissing {
                            Task { await model.refreshTimeline(announceResult: true) }
                        } else {
                            model.retrySelectedFramePreview()
                        }
                    } label: {
                        Label(
                            issue == .momentMissing ? "Refresh Timeline" : "Try Again",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(
                        issue == .momentMissing ? "timeline.preview.refresh" : "timeline.preview.retry"
                    )
                }
            }
        }
        .padding(22)
        .foregroundStyle(.white.opacity(0.9))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(controlStrokeOpacity), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.preview.issue")
        .accessibilitySortPriority(2)
    }

    // Replay and inspection share the same full-bleed memory stage.

    /// Frame image with OCR boxes; search hits get stronger highlights on matching tokens.
    @ViewBuilder
    private func stageImageWithHighlights(
        _ img: NSImage,
        sourceSize: CGSize,
        panOffset: CGSize
    ) -> some View {
        let ocrBody = model.selectedTimelineFrame?.ocrText ?? ""
        ZStack {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .scaleEffect(model.stageZoom)
                .offset(panOffset)

            if model.showLiveText, !model.selectedFrameOCRBoxes.isEmpty {
                let ocrUTF16 = Array(ocrBody.utf16)
                GeometryReader { geo in
                    let transform = OCRHighlightTransform(
                        sourceSize: sourceSize,
                        viewportSize: geo.size,
                        zoom: model.stageZoom,
                        contentOffset: panOffset
                    )
                    ForEach(Array(model.selectedFrameOCRBoxes.enumerated()), id: \.offset) { _, box in
                        let slice = Self.ocrSlice(ocrUTF16, offset: box.textOffset, length: box.textLength)
                        let isHit = Self.boxMatchesTokens(slice, tokens: model.stageHighlightTokens)
                        if let rect = transform.project(box) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(isHit ? model.accentSwiftUIColor.opacity(0.35) : model.accentSwiftUIColor.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .stroke(
                                            isHit ? model.accentSwiftUIColor : model.accentSwiftUIColor.opacity(0.45),
                                            lineWidth: isHit ? 2 : 1
                                        )
                                )
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .clipped()
    }

    private func stageSourceSize(for image: NSImage) -> CGSize {
        // OCR boxes address the original capture, while the stage bitmap is intentionally
        // downsampled. Fall back to preview dimensions only for legacy rows without dimensions.
        let storedWidth = model.selectedTimelineFrame?.width ?? 0
        let storedHeight = model.selectedTimelineFrame?.height ?? 0
        return CGSize(
            width: storedWidth > 0 ? CGFloat(storedWidth) : max(image.size.width, 1),
            height: storedHeight > 0 ? CGFloat(storedHeight) : max(image.size.height, 1)
        )
    }

    private func stageDragGesture(viewportSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: model.stageZoom > 1 ? 3 : 20)
            .onChanged { value in
                guard model.stageZoom > 1, let image = model.selectedFrameImage else { return }
                let start = stagePanGestureStart ?? stagePanOffset
                if stagePanGestureStart == nil { stagePanGestureStart = start }
                stagePanOffset = TimelineStagePanGeometry.clampedOffset(
                    CGSize(
                        width: start.width + value.translation.width,
                        height: start.height + value.translation.height
                    ),
                    sourceSize: stageSourceSize(for: image),
                    viewportSize: viewportSize,
                    zoom: model.stageZoom
                )
            }
            .onEnded { value in
                defer { stagePanGestureStart = nil }
                guard model.stageZoom <= 1 else {
                    clampStagePan(to: viewportSize)
                    return
                }

                // Horizontal swipe steps moments only when the stage is not zoomed in.
                if value.translation.width < -40 {
                    model.stopReplay()
                    model.stepTimeline(by: 1)
                } else if value.translation.width > 40 {
                    model.stopReplay()
                    model.stepTimeline(by: -1)
                }
            }
    }

    private func clampStagePan(to viewportSize: CGSize) {
        guard model.stageZoom > 1, let image = model.selectedFrameImage else {
            stagePanOffset = .zero
            stagePanGestureStart = nil
            return
        }
        stagePanOffset = TimelineStagePanGeometry.clampedOffset(
            stagePanOffset,
            sourceSize: stageSourceSize(for: image),
            viewportSize: viewportSize,
            zoom: model.stageZoom
        )
    }

    private var stageAccessibilityHint: String {
        if model.stageZoom > 1 {
            return "Drag to pan the zoomed moment. Use Left and Right Arrow to move between moments, or Command-0 to reset zoom"
        }
        return "Use Left and Right Arrow to move between moments, or Space to play and pause"
    }

    private var stageAccessibilityValue: String {
        guard let frame = model.selectedTimelineFrame else { return "No moment selected" }
        let availability = frame.imagePath == nil && frame.videoID == nil ? ", preview unavailable" : ""
        let displayContext: String
        if model.selectedTimelineMomentFrames.count > 1,
            let index = model.selectedTimelineDisplayIndex
        {
            let displayLabel = model.selectedTimelineDisplayLabel ?? "Display \(index + 1)"
            displayContext = ", \(displayLabel), \(index + 1) of \(model.selectedTimelineMomentFrames.count)"
        } else {
            displayContext = ""
        }
        return "\(frame.appLabel), \(SLTimeFormat.full(frame.timestampMs))\(displayContext)\(availability)"
    }

    private static func ocrSlice(_ utf16: [UInt16], offset: Int, length: Int) -> String {
        guard offset >= 0, length > 0 else { return "" }
        guard offset < utf16.count else { return "" }
        let end = min(utf16.count, offset + length)
        let slice = Array(utf16[offset..<end])
        return String(utf16CodeUnits: slice, count: slice.count)
    }

    private static func boxMatchesTokens(_ text: String, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        let lower = text.lowercased()
        return tokens.contains { lower.contains($0) }
    }

}
