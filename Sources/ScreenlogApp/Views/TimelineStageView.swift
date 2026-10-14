import AppKit
import ScreenlogCore
import SwiftUI

extension HistoryPane {
    /// Image-led stage, with pan and OCR projection sharing the same viewport.
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
                Color(nsColor: .underPageBackgroundColor)
                if model.selectedFrameExtracting {
                    ProgressView()
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
                    VStack(spacing: SLDesign.space8) {
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Preview no longer available")
                            .font(SLDesign.sectionFont)
                        Text("Searchable text, app, and time are still available.")
                            .font(SLDesign.metadataFont)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(SLDesign.space24)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Preview no longer available. Searchable text, app, and time remain.")
                    .accessibilityIdentifier("timeline.preview.unavailable")
                } else if model.selectedFramePreviewIssue == nil {
                    Text("Select a moment to view its screenshot")
                        .font(SLDesign.bodyFont)
                        .foregroundStyle(.secondary)
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
        .clipShape(RoundedRectangle(cornerRadius: SLDesign.thumbRadius, style: .continuous))
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
        VStack(spacing: SLDesign.space16) {
            VStack(spacing: SLDesign.space8) {
                Label(issue.title, systemImage: issue.systemImage)
                    .font(SLDesign.sectionFont)
                Text(issue.message)
                    .font(SLDesign.bodyFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            HStack(spacing: SLDesign.space8) {
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
        .padding(SLDesign.space24)
        .foregroundStyle(.primary)
        .background(Color(nsColor: .underPageBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.preview.issue")
        .accessibilitySortPriority(2)
    }

    // Replay and inspection share the same image stage.

    /// Frame image with OCR boxes; search hits get stronger highlights on matching tokens.
    @ViewBuilder
    private func stageImageWithHighlights(
        _ img: NSImage,
        sourceSize: CGSize,
        panOffset: CGSize
    ) -> some View {
        ZStack {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .scaleEffect(model.stageZoom)
                .offset(panOffset)

            if model.showLiveText, !model.selectedFrameOCRBoxes.isEmpty {
                // Matching is keyed to the moment and the query, so hover, pan,
                // and zoom passes reuse the previous answer instead of rebuilding
                // a UTF-16 buffer and a lowercased String for every OCR box.
                let hits = ocrHighlightMatches.matchedBoxIndices(
                    frameID: model.selectedTimelineFrame?.id,
                    boxes: model.selectedFrameOCRBoxes,
                    ocrText: model.selectedTimelineFrame?.ocrText ?? "",
                    tokens: model.stageHighlightTokens
                )
                GeometryReader { geo in
                    let transform = OCRHighlightTransform(
                        sourceSize: sourceSize,
                        viewportSize: geo.size,
                        zoom: model.stageZoom,
                        contentOffset: panOffset
                    )
                    ForEach(model.selectedFrameOCRBoxes.indices, id: \.self) { index in
                        let box = model.selectedFrameOCRBoxes[index]
                        let isHit = hits.contains(index)
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
            return "Drag to pan the zoomed moment. Use Left and Right Arrow to move between moments. Use Command-0 to reset zoom."
        }
        return "Use Left and Right Arrow to move between moments. Use Space to play or pause."
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

}

/// Memoized search-hit lookup for the stage's Live Text overlay.
///
/// A real capture carries roughly a hundred OCR boxes. Deriving each box's text
/// inside `body` meant hundreds of String allocations for every pointer-hover,
/// pan, and zoom pass, none of which can change the answer. The match set only
/// depends on the selected moment and the current highlight tokens, so it is
/// computed once per change and replayed afterwards.
@MainActor
final class TimelineOCRHighlightMatches {
    private struct Key: Equatable {
        let frameID: Int64?
        let boxCount: Int
        let tokens: [String]
    }

    private var key: Key?
    private var matches: Set<Int> = []

    func matchedBoxIndices(
        frameID: Int64?,
        boxes: [OCRBox],
        ocrText: String,
        tokens: [String]
    ) -> Set<Int> {
        let requested = Key(frameID: frameID, boxCount: boxes.count, tokens: tokens)
        if key == requested { return matches }
        key = requested
        matches = Self.computeMatches(boxes: boxes, ocrText: ocrText, tokens: tokens)
        return matches
    }

    private static func computeMatches(
        boxes: [OCRBox],
        ocrText: String,
        tokens: [String]
    ) -> Set<Int> {
        guard !tokens.isEmpty, !boxes.isEmpty, !ocrText.isEmpty else { return [] }
        let utf16 = Array(ocrText.utf16)
        var matched: Set<Int> = []
        for index in boxes.indices {
            let box = boxes[index]
            let slice = ocrSlice(utf16, offset: box.textOffset, length: box.textLength)
            if boxMatchesTokens(slice, tokens: tokens) { matched.insert(index) }
        }
        return matched
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
