import CoreGraphics
import XCTest

@testable import ScreenlogCore

/// Pure DifferentialOCR logic - no Vision / ScreenCaptureKit permissions.
final class DifferentialOCRTests: XCTestCase {
    private final class RecognitionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        func recognize(_ image: CGImage) -> OCRResult {
            lock.lock()
            calls += 1
            let call = calls
            lock.unlock()
            return OCRResult(
                fullText: "result-\(call)",
                boxes: [
                    OCRBox(
                        x: 0,
                        y: 0,
                        width: image.width,
                        height: image.height,
                        textOffset: 0,
                        textLength: 8
                    )
                ]
            )
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    func testSimilarityIdenticalIsOne() {
        let sample: [UInt8] = [10, 20, 30, 40, 50]
        XCTAssertEqual(DifferentialOCRMath.similarity(sample, sample), 1.0, accuracy: 0.000_001)
    }

    func testSimilarityEmptyOrLengthMismatchIsZero() {
        XCTAssertEqual(DifferentialOCRMath.similarity([], []), 0)
        XCTAssertEqual(DifferentialOCRMath.similarity([1], []), 0)
        XCTAssertEqual(DifferentialOCRMath.similarity([1, 2], [1]), 0)
    }

    func testSimilarityNoiseToleranceWithinThree() {
        let a: [UInt8] = [100, 100, 100, 100]
        // |diff| == 3 still counts as same
        let near: [UInt8] = [103, 97, 100, 101]
        XCTAssertEqual(DifferentialOCRMath.similarity(a, near), 1.0, accuracy: 0.000_001)

        // One sample differs by 4 to 3/4 similar
        let farOne: [UInt8] = [104, 100, 100, 100]
        XCTAssertEqual(DifferentialOCRMath.similarity(a, farOne), 0.75, accuracy: 0.000_001)
    }

    func testSimilarityCompletelyDifferent() {
        let a: [UInt8] = [0, 0, 0, 0]
        let b: [UInt8] = [255, 255, 255, 255]
        XCTAssertEqual(DifferentialOCRMath.similarity(a, b), 0, accuracy: 0.000_001)
    }

    func testFNV1aDeterministicAndDistinct() {
        let a: [UInt8] = [1, 2, 3, 4]
        let b: [UInt8] = [1, 2, 3, 5]
        let h1 = DifferentialOCRMath.fnv1a(a)
        let h2 = DifferentialOCRMath.fnv1a(a)
        let h3 = DifferentialOCRMath.fnv1a(b)
        XCTAssertEqual(h1, h2)
        XCTAssertNotEqual(h1, h3)
        // Empty input still produces FNV offset basis
        XCTAssertEqual(DifferentialOCRMath.fnv1a([]), 0xcbf2_9ce4_8422_2325)
    }

    func testReuseThresholdDefaultInRange() {
        let service = DifferentialOCRService()
        XCTAssertGreaterThan(service.reuseThreshold, 0.9)
        XCTAssertLessThanOrEqual(service.reuseThreshold, 1.0)
        XCTAssertGreaterThan(service.sampleStride, 0)
        service.reset()  // no crash when empty
    }

    /// Snapshots OCR languages must reach DifferentialOCRService (default capture path).
    func testRecognitionLanguagesForwardToUnderlyingOCRService() {
        let service = DifferentialOCRService()
        XCTAssertTrue(service.recognitionLanguages.isEmpty)
        service.recognitionLanguages = ["en-US", "fr-FR"]
        XCTAssertEqual(service.recognitionLanguages, ["en-US", "fr-FR"])
        // Clearing must stick (system default).
        service.recognitionLanguages = []
        XCTAssertTrue(service.recognitionLanguages.isEmpty)
    }

    @MainActor
    func testEngineApplySnapshotPrefsSetsDifferentialOCRLanguages() {
        let engine = RecordingEngine()
        engine.applySnapshotSettings(
            preferJPEG: false,
            ocrLanguages: ["de-DE"],
            differentialOCR: true
        )
        // Engine stores languages for pipeline apply; re-apply must not crash.
        XCTAssertEqual(engine.ocrLanguages, ["de-DE"])
        XCTAssertTrue(engine.useDifferentialOCR)
        engine.applySnapshotSettings(
            preferJPEG: true,
            ocrLanguages: [],
            differentialOCR: false
        )
        XCTAssertTrue(engine.preferJPEGStill)
        XCTAssertTrue(engine.ocrLanguages.isEmpty)
        XCTAssertFalse(engine.useDifferentialOCR)
    }

    func testSimilarityMeetsDefaultReuseThresholdForNearIdentical() {
        // 992/1000 same to similarity 0.992 == default threshold
        let a = [UInt8](repeating: 128, count: 1000)
        var b = a
        for i in 0..<8 {
            b[i] = 255  // clearly different
        }
        let sim = DifferentialOCRMath.similarity(a, b)
        XCTAssertEqual(sim, 0.992, accuracy: 0.000_001)
        let service = DifferentialOCRService()
        XCTAssertGreaterThanOrEqual(sim, service.reuseThreshold)
    }

    func testResolutionChangeNeverReusesCachedOCRGeometry() async throws {
        let recorder = RecognitionRecorder()
        let service = DifferentialOCRService { image in
            recorder.recognize(image)
        }
        let original = try solidImage(width: 320, height: 180)
        let resized = try solidImage(width: 640, height: 360)

        let first = try await service.recognize(image: original)
        let repeated = try await service.recognize(image: original)
        let changedResolution = try await service.recognize(image: resized)

        XCTAssertFalse(first.reused)
        XCTAssertTrue(repeated.reused)
        XCTAssertFalse(changedResolution.reused)
        XCTAssertEqual(changedResolution.result.boxes[0].width, 640)
        XCTAssertEqual(changedResolution.result.boxes[0].height, 360)
        XCTAssertEqual(recorder.callCount, 2)
    }

    private func solidImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
