import CoreGraphics
import Foundation
import OSLog
import Vision

private let log = Logger(subsystem: "dev.screenlog", category: "ocr")

public struct OCRResult: Sendable {
    public var fullText: String
    public var boxes: [OCRBox]

    public init(fullText: String, boxes: [OCRBox]) {
        self.fullText = fullText
        self.boxes = boxes
    }
}

/// OCR text split into focused-app (foreground) vs other-window (background) layers.
/// `boxes` use `text_offset` into the concatenation `foreground + background`.
public struct AttributedOCRResult: Sendable {
    public var foreground: String
    public var background: String
    public var boxes: [OCRBox]

    public init(foreground: String, background: String, boxes: [OCRBox]) {
        self.foreground = foreground
        self.background = background
        self.boxes = boxes
    }

    /// Concatenation addressed by persisted OCR box offsets.
    public var concatenated: String { foreground + background }
}

/// On-device Vision-based OCR.
public final class OCRService: @unchecked Sendable {
    /// `.accurate` is high quality; capture pipeline can switch to `.fast` under load.
    public var recognitionLevel: VNRequestTextRecognitionLevel = .accurate
    public var usesLanguageCorrection = true
    /// Cap concurrent Vision work slightly for stability on long sessions.
    public var maximumCandidates = 1
    /// BCP-47 language codes for Vision (`en-US`, `fr-FR`, ...). Empty = system default.
    public var recognitionLanguages: [String] = []

    public init() {}

    public func recognize(image: CGImage) async throws -> OCRResult {
        // Run Vision off the cooperative pool; never require MainActor.
        try await withCheckedThrowingContinuation { cont in
            // Perform on a background queue so callers on any executor stay free.
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = self.recognitionLevel
                request.usesLanguageCorrection = self.usesLanguageCorrection
                if !self.recognitionLanguages.isEmpty {
                    request.recognitionLanguages = self.recognitionLanguages
                }
                // Prefer GPU / ANE when available - Vision picks the best path.
                if #available(macOS 13.0, *) {
                    request.revision = VNRecognizeTextRequestRevision3
                }
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let observations: [VNRecognizedTextObservation] = request.results ?? []
                    var text = ""
                    var boxes: [OCRBox] = []
                    boxes.reserveCapacity(observations.count)
                    let imgW = image.width
                    let imgH = image.height
                    let cand = max(1, self.maximumCandidates)
                    for obs in observations {
                        guard let top = obs.topCandidates(cand).first else { continue }
                        let s = top.string
                        if !text.isEmpty { text += "\n" }
                        let offset = text.utf16.count
                        text += s
                        let bb = obs.boundingBox
                        // Vision: origin bottom-left normalized to image top-left pixel space
                        let x = Int(bb.origin.x * CGFloat(imgW))
                        let y = Int((1.0 - bb.origin.y - bb.size.height) * CGFloat(imgH))
                        let w = Int(bb.size.width * CGFloat(imgW))
                        let h = Int(bb.size.height * CGFloat(imgH))
                        boxes.append(
                            OCRBox(
                                x: max(0, x),
                                y: max(0, y),
                                width: max(1, w),
                                height: max(1, h),
                                textOffset: offset,
                                textLength: s.utf16.count
                            )
                        )
                    }
                    log.debug("ocr boxes=\(boxes.count) chars=\(text.count)")
                    cont.resume(returning: OCRResult(fullText: text, boxes: boxes))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Projects native-resolution Vision boxes into the stored still's pixel
    /// space. Text offsets are unchanged because only geometry is resized.
    public static func rescaleBoxes(
        _ boxes: [OCRBox],
        sourceWidth: Int,
        sourceHeight: Int,
        destinationWidth: Int,
        destinationHeight: Int
    ) -> [OCRBox] {
        guard sourceWidth > 0, sourceHeight > 0,
            destinationWidth > 0, destinationHeight > 0,
            sourceWidth != destinationWidth || sourceHeight != destinationHeight
        else { return boxes }

        let scaleX = Double(destinationWidth) / Double(sourceWidth)
        let scaleY = Double(destinationHeight) / Double(sourceHeight)
        return boxes.map { box in
            let x = min(
                destinationWidth - 1,
                max(0, Int((Double(box.x) * scaleX).rounded()))
            )
            let y = min(
                destinationHeight - 1,
                max(0, Int((Double(box.y) * scaleY).rounded()))
            )
            let maxX = min(
                destinationWidth,
                max(x + 1, Int((Double(box.x + box.width) * scaleX).rounded()))
            )
            let maxY = min(
                destinationHeight,
                max(y + 1, Int((Double(box.y + box.height) * scaleY).rounded()))
            )
            return OCRBox(
                x: x,
                y: y,
                width: maxX - x,
                height: maxY - y,
                textOffset: box.textOffset,
                textLength: box.textLength
            )
        }
    }

    // MARK: - Foreground / background attribution

    /// Attribute full-screen OCR boxes to the focused/frontmost window (foreground) vs other windows (background).
    ///
    /// Text packing contract:
    /// 1. Prefer boxes whose screen-space geometry intersects the focused app's frontmost window rect as FG.
    /// 2. Remaining boxes become BG.
    /// 3. If `windowBounds` is empty, keep the full OCR text as foreground (no split).
    /// 4. `text_offset` addresses the concatenation `foreground || background`.
    public static func attributeToForegroundBackground(
        result: OCRResult,
        imageWidth: Int,
        imageHeight: Int,
        captureDisplay: CaptureDisplayRect?,
        windowBounds: [WindowBound],
        foregroundBundleID: String?,
        allowVisibleWindowFallback: Bool = true
    ) -> AttributedOCRResult {
        // No boxes / bad dims / no window geometry to full text is foreground.
        guard !result.boxes.isEmpty, imageWidth > 0, imageHeight > 0 else {
            return AttributedOCRResult(foreground: result.fullText, background: "", boxes: result.boxes)
        }
        guard !windowBounds.isEmpty else {
            if !allowVisibleWindowFallback, foregroundBundleID != nil {
                return AttributedOCRResult(
                    foreground: "",
                    background: result.fullText,
                    boxes: result.boxes
                )
            }
            return AttributedOCRResult(foreground: result.fullText, background: "", boxes: result.boxes)
        }

        let sortedWindows = windowBounds.sorted { $0.zOrder < $1.zOrder }
        let focusedWindow: WindowBound? =
            if !allowVisibleWindowFallback,
                let foregroundBundleID,
                !foregroundBundleID.isEmpty
            {
                sortedWindows.first(where: { $0.bundleID == foregroundBundleID })
            } else {
                Self.focusedWindow(in: sortedWindows, bundleID: foregroundBundleID)
            }
        let fgBundle = foregroundBundleID

        struct Piece {
            var text: String
            var box: OCRBox
            var isForeground: Bool
            var sortY: Int
            var sortX: Int
        }

        var pieces: [Piece] = []
        pieces.reserveCapacity(result.boxes.count)

        for box in result.boxes {
            let snippet = Self.sliceUTF16(result.fullText, offset: box.textOffset, length: box.textLength)
            let screenRect = Self.imageRectToScreen(
                x: box.x,
                y: box.y,
                width: box.width,
                height: box.height,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                captureDisplay: captureDisplay
            )
            let center = (
                x: screenRect.x + screenRect.width / 2,
                y: screenRect.y + screenRect.height / 2
            )

            let isFG: Bool
            if let focused = focusedWindow {
                // Primary: intersect (or contain center of) the focused/frontmost window rect.
                if Self.rectsIntersect(screenRect, focused) || Self.window(focused, contains: center) {
                    isFG = true
                } else if let hit = Self.frontmostWindow(containing: center, windows: sortedWindows) {
                    // Visible box over another window of the same focused app still counts as FG.
                    if let bid = hit.bundleID, let fgBundle, !fgBundle.isEmpty {
                        isFG = bid == fgBundle
                    } else {
                        isFG = hit.zOrder == focused.zOrder
                    }
                } else {
                    // Outside every window (desktop / menubar fringe) to background.
                    isFG = false
                }
            } else if !allowVisibleWindowFallback, foregroundBundleID != nil {
                // A synchronized secondary display can have visible windows but
                // no window from the globally focused app. Its OCR remains
                // searchable background context instead of being attributed to
                // an unrelated app on that display.
                isFG = false
            } else if let hit = Self.frontmostWindow(containing: center, windows: sortedWindows) {
                // No focused window identity: only the global frontmost window (zOrder 0) is FG.
                isFG = hit.zOrder == 0 || hit.bundleID == sortedWindows.first?.bundleID
            } else {
                isFG = true
            }

            pieces.append(
                Piece(text: snippet, box: box, isForeground: isFG, sortY: box.y, sortX: box.x)
            )
        }

        // Stable reading order within each layer
        let fgPieces = pieces.filter(\.isForeground).sorted { ($0.sortY, $0.sortX) < ($1.sortY, $1.sortX) }
        let bgPieces = pieces.filter { !$0.isForeground }.sorted { ($0.sortY, $0.sortX) < ($1.sortY, $1.sortX) }

        var foreground = ""
        var background = ""
        var outBoxes: [OCRBox] = []
        outBoxes.reserveCapacity(pieces.count)

        for p in fgPieces {
            if !foreground.isEmpty { foreground += "\n" }
            let offset = foreground.utf16.count
            foreground += p.text
            outBoxes.append(
                OCRBox(
                    x: p.box.x,
                    y: p.box.y,
                    width: p.box.width,
                    height: p.box.height,
                    textOffset: offset,
                    textLength: p.text.utf16.count
                )
            )
        }

        let fgUTF16 = foreground.utf16.count
        for p in bgPieces {
            if !background.isEmpty { background += "\n" }
            let offsetInBG = background.utf16.count
            background += p.text
            // Offsets address the foreground||background concatenation.
            outBoxes.append(
                OCRBox(
                    x: p.box.x,
                    y: p.box.y,
                    width: p.box.width,
                    height: p.box.height,
                    textOffset: fgUTF16 + offsetInBG,
                    textLength: p.text.utf16.count
                )
            )
        }

        log.debug(
            "ocr attribute fgChars=\(foreground.count) bgChars=\(background.count) boxes=\(outBoxes.count) fgBundle=\(fgBundle ?? "-", privacy: .private(mask: .hash))"
        )
        return AttributedOCRResult(foreground: foreground, background: background, boxes: outBoxes)
    }

    // MARK: - Helpers

    /// Frontmost window for the focused app (lowest zOrder with matching bundle), else global frontmost.
    public static func focusedWindow(in windows: [WindowBound], bundleID: String?) -> WindowBound? {
        let sorted = windows.sorted { $0.zOrder < $1.zOrder }
        if let bundleID, !bundleID.isEmpty {
            if let match = sorted.first(where: { $0.bundleID == bundleID }) {
                return match
            }
        }
        return sorted.first
    }

    private static func sliceUTF16(_ string: String, offset: Int, length: Int) -> String {
        guard length > 0, offset >= 0 else { return "" }
        let u = string.utf16
        guard offset < u.count else { return "" }
        let start = u.index(u.startIndex, offsetBy: offset)
        let endOffset = min(offset + length, u.count)
        let end = u.index(u.startIndex, offsetBy: endOffset)
        return String(utf16CodeUnits: Array(u[start..<end]), count: endOffset - offset)
    }

    /// Map image-pixel rect to global screen points used by `kCGWindowBounds` / `SCDisplay.frame`.
    ///
    /// Image space and window-list bounds both use top-left origin (y down) per Apple
    /// `kCGWindowBounds` docs, so mapping is a pure scale + display offset (no Y flip).
    private static func imageRectToScreen(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        imageWidth: Int,
        imageHeight: Int,
        captureDisplay: CaptureDisplayRect?
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        guard let d = captureDisplay, d.width > 0, d.height > 0, imageWidth > 0, imageHeight > 0 else {
            return (Double(x), Double(y), Double(width), Double(height))
        }
        let sx = d.x + (Double(x) / Double(imageWidth)) * d.width
        let sy = d.y + (Double(y) / Double(imageHeight)) * d.height
        let sw = (Double(width) / Double(imageWidth)) * d.width
        let sh = (Double(height) / Double(imageHeight)) * d.height
        return (sx, sy, sw, sh)
    }

    private static func window(_ w: WindowBound, contains point: (x: Double, y: Double)) -> Bool {
        let minX = Double(w.x)
        let minY = Double(w.y)
        let maxX = minX + Double(w.width)
        let maxY = minY + Double(w.height)
        return point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    private static func rectsIntersect(
        _ a: (x: Double, y: Double, width: Double, height: Double),
        _ w: WindowBound
    ) -> Bool {
        let ax2 = a.x + a.width
        let ay2 = a.y + a.height
        let bx1 = Double(w.x)
        let by1 = Double(w.y)
        let bx2 = bx1 + Double(w.width)
        let by2 = by1 + Double(w.height)
        return a.x < bx2 && ax2 > bx1 && a.y < by2 && ay2 > by1
    }

    /// First window in z-order (front to back) whose bounds contain the point.
    private static func frontmostWindow(
        containing point: (x: Double, y: Double),
        windows: [WindowBound]
    ) -> WindowBound? {
        for w in windows {
            if window(w, contains: point) { return w }
        }
        return nil
    }

}
