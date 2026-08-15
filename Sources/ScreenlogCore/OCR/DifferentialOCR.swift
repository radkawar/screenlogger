import CoreGraphics
import Foundation
import OSLog
import Vision

private let log = Logger(subsystem: "dev.screenlog", category: "diff-ocr")

/// Differential OCR: if the frame is nearly identical to the previous, reuse OCR
/// text and boxes to avoid redundant Vision work. Otherwise, run full OCR.
///
/// Intended for single-consumer use (e.g. `CapturePipeline` actor). Not MainActor-bound.
public final class DifferentialOCRService: @unchecked Sendable {
    private let ocr: OCRService
    private let recognizeFullImage: @Sendable (CGImage) async throws -> OCRResult
    private var lastImageHash: UInt64?
    private var lastResult: OCRResult?
    private var lastPixelSample: [UInt8]?
    private var lastImageWidth: Int?
    private var lastImageHeight: Int?

    /// Similarity threshold 0...1 (1 = identical). Above this, reuse previous OCR.
    public var reuseThreshold: Double = 0.988
    /// Stride on the *downscaled* sample image (larger = cheaper).
    public var sampleStride: Int = 4
    /// Max edge of luminance sample canvas (pixels). Keeps diff cheap at full display resolution.
    public var sampleMaxEdge: Int = 160

    /// Vision language codes for the underlying OCRService (empty = system).
    /// Must be set when Snapshots prefs change - default capture uses this path.
    public var recognitionLanguages: [String] {
        get { ocr.recognitionLanguages }
        set { ocr.recognitionLanguages = newValue }
    }

    public init() {
        let service = OCRService()
        ocr = service
        recognizeFullImage = { image in
            try await service.recognize(image: image)
        }
    }

    init(
        recognizeFullImage: @escaping @Sendable (CGImage) async throws -> OCRResult
    ) {
        ocr = OCRService()
        self.recognizeFullImage = recognizeFullImage
    }

    public func recognize(image: CGImage) async throws -> (result: OCRResult, reused: Bool) {
        // Downscale + sample off the main thread (never full-res RGBA for diff).
        let stride = sampleStride
        let maxEdge = sampleMaxEdge
        let threshold = reuseThreshold
        let sample: [UInt8] = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: Self.samplePixels(image, stride: stride, maxEdge: maxEdge))
            }
        }
        let hash = DifferentialOCRMath.fnv1a(sample)

        if lastImageWidth == image.width,
            lastImageHeight == image.height,
            let last = lastResult,
            let lastSample = lastPixelSample
        {
            if lastImageHash == hash {
                log.debug("differential OCR reuse (hash)")
                return (last, true)
            }
            // Cheap length gate before O(n) similarity.
            if lastSample.count == sample.count,
                DifferentialOCRMath.similarity(lastSample, sample) >= threshold
            {
                log.debug("differential OCR reuse (sim)")
                return (last, true)
            }
        }

        let result = try await recognizeFullImage(image)
        lastResult = result
        lastImageHash = hash
        lastPixelSample = sample
        lastImageWidth = image.width
        lastImageHeight = image.height
        return (result, false)
    }

    public func reset() {
        lastImageHash = nil
        lastResult = nil
        lastPixelSample = nil
        lastImageWidth = nil
        lastImageHeight = nil
    }

    /// Downscale to `maxEdge`, then sample luminance - avoids full-res CGContext for 1080p+.
    private static func samplePixels(_ image: CGImage, stride: Int, maxEdge: Int) -> [UInt8] {
        let srcW = image.width
        let srcH = image.height
        guard srcW > 0, srcH > 0 else { return [] }
        let scale = min(1.0, Double(maxEdge) / Double(max(srcW, srcH)))
        let w = max(1, Int(Double(srcW) * scale))
        let h = max(1, Int(Double(srcH) * scale))
        let bytesPerPixel = 4
        let bytesPerRow = w * bytesPerPixel
        var raw = [UInt8](repeating: 0, count: h * bytesPerRow)
        guard
            let ctx = CGContext(
                data: &raw,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let step = max(1, stride)
        var out: [UInt8] = []
        out.reserveCapacity(max(1, (w / step) * (h / step)))
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let i = y * bytesPerRow + x * bytesPerPixel
                let r = Int(raw[i])
                let g = Int(raw[i + 1])
                let b = Int(raw[i + 2])
                out.append(UInt8((r * 30 + g * 59 + b * 11) / 100))
                x += step
            }
            y += step
        }
        return out
    }
}
