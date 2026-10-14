@testable import ScreenlogCore
import XCTest

/// Pure FG/BG OCR attribution - no Vision / ScreenCaptureKit.
final class OCRAttributionTests: XCTestCase {
    func testNativeOCRBoxesScaleIntoStoredImageCoordinates() {
        let boxes = [
            OCRBox(
                x: 1_000,
                y: 500,
                width: 400,
                height: 200,
                textOffset: 7,
                textLength: 11
            )
        ]

        let scaled = OCRService.rescaleBoxes(
            boxes,
            sourceWidth: 4_000,
            sourceHeight: 2_000,
            destinationWidth: 2_000,
            destinationHeight: 1_000
        )

        XCTAssertEqual(
            scaled,
            [
                OCRBox(
                    x: 500,
                    y: 250,
                    width: 200,
                    height: 100,
                    textOffset: 7,
                    textLength: 11
                )
            ]
        )
    }

    func testOCRBoxScalingClipsGeometryAndPreservesTextOffsets() {
        let box = OCRBox(
            x: 3_900,
            y: 1_900,
            width: 400,
            height: 300,
            textOffset: 3,
            textLength: 5
        )

        let scaled = OCRService.rescaleBoxes(
            [box],
            sourceWidth: 4_000,
            sourceHeight: 2_000,
            destinationWidth: 1_000,
            destinationHeight: 500
        )

        XCTAssertEqual(scaled[0].x, 975)
        XCTAssertEqual(scaled[0].y, 475)
        XCTAssertEqual(scaled[0].width, 25)
        XCTAssertEqual(scaled[0].height, 25)
        XCTAssertEqual(scaled[0].textOffset, 3)
        XCTAssertEqual(scaled[0].textLength, 5)
    }

    func testOCRBoxScalingNeverPersistsZeroAreaAtImageBoundary() {
        let scaled = OCRService.rescaleBoxes(
            [OCRBox(x: 4_000, y: 2_000, width: 1, height: 1, textOffset: 0, textLength: 1)],
            sourceWidth: 4_000,
            sourceHeight: 2_000,
            destinationWidth: 1_000,
            destinationHeight: 500
        )

        XCTAssertEqual(scaled[0].x, 999)
        XCTAssertEqual(scaled[0].y, 499)
        XCTAssertEqual(scaled[0].width, 1)
        XCTAssertEqual(scaled[0].height, 1)
    }

    private let display = CaptureDisplayRect(x: 0, y: 0, width: 1000, height: 800)
    private let imageW = 1000
    private let imageH = 800

    /// Build an OCRResult from ordered snippets + absolute image boxes.
    private func makeResult(_ items: [(text: String, x: Int, y: Int, w: Int, h: Int)]) -> OCRResult {
        var full = ""
        var boxes: [OCRBox] = []
        for item in items {
            if !full.isEmpty { full += "\n" }
            let offset = full.utf16.count
            full += item.text
            boxes.append(
                OCRBox(
                    x: item.x,
                    y: item.y,
                    width: item.w,
                    height: item.h,
                    textOffset: offset,
                    textLength: item.text.utf16.count
                )
            )
        }
        return OCRResult(fullText: full, boxes: boxes)
    }

    func testNoWindowBoundsKeepsFullTextAsForeground() {
        let result = makeResult([
            ("Focused", 10, 10, 80, 20),
            ("Other", 500, 400, 80, 20),
        ])
        let attributed = OCRService.attributeToForegroundBackground(
            result: result,
            imageWidth: imageW,
            imageHeight: imageH,
            captureDisplay: display,
            windowBounds: [],
            foregroundBundleID: "dev.focused"
        )
        XCTAssertEqual(attributed.foreground, result.fullText)
        XCTAssertEqual(attributed.background, "")
        XCTAssertEqual(attributed.boxes.count, result.boxes.count)
        XCTAssertEqual(attributed.boxes.map(\.textOffset), result.boxes.map(\.textOffset))
    }

    func testEmptyOCRResultPassthrough() {
        let result = OCRResult(fullText: "", boxes: [])
        let attributed = OCRService.attributeToForegroundBackground(
            result: result,
            imageWidth: imageW,
            imageHeight: imageH,
            captureDisplay: display,
            windowBounds: [
                WindowBound(bundleID: "dev.focused", x: 0, y: 0, width: 500, height: 800, zOrder: 0)
            ],
            foregroundBundleID: "dev.focused"
        )
        XCTAssertEqual(attributed.foreground, "")
        XCTAssertEqual(attributed.background, "")
        XCTAssertTrue(attributed.boxes.isEmpty)
    }

    func testBoxesIntersectingFocusedWindowAreForeground() {
        // Focused app occupies left half; other app right half.
        let windows = [
            WindowBound(bundleID: "dev.focused", windowTitle: "Main", x: 0, y: 0, width: 500, height: 800, zOrder: 0),
            WindowBound(bundleID: "dev.other", windowTitle: "Side", x: 500, y: 0, width: 500, height: 800, zOrder: 1),
        ]
        let result = makeResult([
            ("FGLine", 100, 100, 120, 24),  // center ~ (160, 112) to left window
            ("BGLine", 700, 200, 120, 24),  // center ~ (760, 212) to right window
        ])

        let attributed = OCRService.attributeToForegroundBackground(
            result: result,
            imageWidth: imageW,
            imageHeight: imageH,
            captureDisplay: display,
            windowBounds: windows,
            foregroundBundleID: "dev.focused"
        )

        XCTAssertTrue(attributed.foreground.contains("FGLine"), "foreground=\(attributed.foreground)")
        XCTAssertFalse(attributed.foreground.contains("BGLine"))
        XCTAssertTrue(attributed.background.contains("BGLine"), "background=\(attributed.background)")
        XCTAssertFalse(attributed.background.contains("FGLine"))
    }

    func testBoxOffsetsAddressForegroundThenBackground() {
        let windows = [
            WindowBound(bundleID: "dev.focused", x: 0, y: 0, width: 500, height: 800, zOrder: 0),
            WindowBound(bundleID: "dev.other", x: 500, y: 0, width: 500, height: 800, zOrder: 1),
        ]
        let result = makeResult([
            ("Alpha", 50, 50, 40, 20),
            ("Beta", 600, 50, 40, 20),
        ])
        let attributed = OCRService.attributeToForegroundBackground(
            result: result,
            imageWidth: imageW,
            imageHeight: imageH,
            captureDisplay: display,
            windowBounds: windows,
            foregroundBundleID: "dev.focused"
        )

        let concat = attributed.concatenated
        XCTAssertEqual(concat, attributed.foreground + attributed.background)
        XCTAssertFalse(attributed.boxes.isEmpty)

        for box in attributed.boxes {
            let slice = sliceUTF16(concat, offset: box.textOffset, length: box.textLength)
            XCTAssertFalse(slice.isEmpty)
            XCTAssertTrue(
                attributed.foreground.contains(slice) || attributed.background.contains(slice),
                "slice '\(slice)' not in FG/BG"
            )
        }

        // FG boxes must come first in offset space
        let fgLen = attributed.foreground.utf16.count
        let bgBoxes = attributed.boxes.filter { $0.textOffset >= fgLen }
        let fgBoxes = attributed.boxes.filter { $0.textOffset < fgLen }
        XCTAssertEqual(fgBoxes.count, 1)
        XCTAssertEqual(bgBoxes.count, 1)
        XCTAssertEqual(sliceUTF16(concat, offset: fgBoxes[0].textOffset, length: fgBoxes[0].textLength), "Alpha")
        XCTAssertEqual(sliceUTF16(concat, offset: bgBoxes[0].textOffset, length: bgBoxes[0].textLength), "Beta")
    }

    func testSameAppSecondaryWindowStillForeground() {
        // Two windows of focused app; text in the back one should still be FG by bundle match.
        let windows = [
            WindowBound(bundleID: "dev.focused", x: 0, y: 0, width: 400, height: 400, zOrder: 0),
            WindowBound(bundleID: "dev.focused", x: 400, y: 400, width: 400, height: 400, zOrder: 1),
            WindowBound(bundleID: "dev.other", x: 800, y: 0, width: 200, height: 800, zOrder: 2),
        ]
        let result = makeResult([
            ("Main", 50, 50, 40, 20),
            ("Aux", 500, 500, 40, 20),
            ("Other", 850, 100, 40, 20),
        ])
        let attributed = OCRService.attributeToForegroundBackground(
            result: result,
            imageWidth: imageW,
            imageHeight: imageH,
            captureDisplay: display,
            windowBounds: windows,
            foregroundBundleID: "dev.focused"
        )
        XCTAssertTrue(attributed.foreground.contains("Main"))
        XCTAssertTrue(attributed.foreground.contains("Aux"))
        XCTAssertTrue(attributed.background.contains("Other"))
        XCTAssertFalse(attributed.foreground.contains("Other"))
    }

    func testSecondaryDisplayWithoutFocusedWindowKeepsAllTextAsBackground() {
        let windows = [
            WindowBound(
                bundleID: "dev.secondary",
                x: 0,
                y: 0,
                width: 1_000,
                height: 800,
                zOrder: 0
            )
        ]
        let result = makeResult([
            ("Secondary context", 100, 100, 200, 24)
        ])

        let attributed = OCRService.attributeToForegroundBackground(
            result: result,
            imageWidth: imageW,
            imageHeight: imageH,
            captureDisplay: display,
            windowBounds: windows,
            foregroundBundleID: "dev.focused",
            allowVisibleWindowFallback: false
        )

        XCTAssertEqual(attributed.foreground, "")
        XCTAssertEqual(attributed.background, "Secondary context")
    }

    func testFocusedWindowHelperPicksLowestZForBundle() {
        let windows = [
            WindowBound(bundleID: "dev.other", x: 0, y: 0, width: 100, height: 100, zOrder: 0),
            WindowBound(bundleID: "dev.focused", x: 10, y: 10, width: 100, height: 100, zOrder: 2),
            WindowBound(bundleID: "dev.focused", x: 20, y: 20, width: 100, height: 100, zOrder: 1),
        ]
        let focused = OCRService.focusedWindow(in: windows, bundleID: "dev.focused")
        XCTAssertEqual(focused?.zOrder, 1)
        XCTAssertEqual(focused?.x, 20)

        let front = OCRService.focusedWindow(in: windows, bundleID: nil)
        XCTAssertEqual(front?.zOrder, 0)
        XCTAssertEqual(front?.bundleID, "dev.other")
    }

    func testStorePersistsAttributedForegroundBackgroundAndZOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-ocr-attr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)

        let windows = [
            WindowBound(bundleID: "dev.focused", windowTitle: "Main", x: 0, y: 0, width: 500, height: 800, zOrder: 0),
            WindowBound(bundleID: "dev.other", windowTitle: "Side", x: 500, y: 0, width: 500, height: 800, zOrder: 1, url: nil),
        ]
        let result = makeResult([
            ("Invoice", 100, 100, 80, 20),
            ("Sidebar", 700, 100, 80, 20),
        ])
        let attributed = OCRService.attributeToForegroundBackground(
            result: result,
            imageWidth: imageW,
            imageHeight: imageH,
            captureDisplay: display,
            windowBounds: windows,
            foregroundBundleID: "dev.focused"
        )
        var stamped = windows
        stamped[0].url = "https://app.example/doc"

        let id = try store.store(
            payload: CapturePayload(
                imageData: Data([0x00]),
                timestampMs: 1,
                width: imageW,
                height: imageH,
                foreground: attributed.foreground,
                background: attributed.background,
                title: "Main",
                bundleID: "dev.focused",
                displayName: "Focused",
                url: "https://app.example/doc",
                domain: "app.example",
                ocrBoxes: attributed.boxes,
                windowBounds: stamped,
                imageFileExtension: "bin",
                captureDisplay: display
            )
        )

        let frame = try store.frame(id: id)
        XCTAssertEqual(frame?.foreground, attributed.foreground)
        XCTAssertEqual(frame?.background, attributed.background)
        XCTAssertTrue(frame?.foreground?.contains("Invoice") == true)
        XCTAssertTrue(frame?.background?.contains("Sidebar") == true)

        let bounds = try store.windowBounds(frameID: id)
        XCTAssertEqual(bounds.count, 2)
        XCTAssertEqual(bounds.map(\.zOrder), [0, 1])
        XCTAssertEqual(bounds.first?.url, "https://app.example/doc")

        let boxes = try store.ocrBoxes(frameID: id)
        XCTAssertEqual(boxes.count, 2)
        let concat = (frame?.foreground ?? "") + (frame?.background ?? "")
        for box in boxes {
            let s = sliceUTF16(concat, offset: box.textOffset, length: box.textLength)
            XCTAssertTrue(s == "Invoice" || s == "Sidebar", "unexpected slice \(s)")
        }
    }

    func testSegmentExtendsUntilAppDomainOrURLChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-seg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root)

        let a1 = try store.insertSeedFrame(
            timestampMs: 1,
            foreground: "a",
            bundleID: "dev.app",
            domain: "ex.com",
            url: "https://ex.com/1"
        )
        let a2 = try store.insertSeedFrame(
            timestampMs: 2,
            foreground: "a",
            bundleID: "dev.app",
            domain: "ex.com",
            url: "https://ex.com/1"
        )
        let bURL = try store.insertSeedFrame(
            timestampMs: 3,
            foreground: "b",
            bundleID: "dev.app",
            domain: "ex.com",
            url: "https://ex.com/2"
        )
        let cDomain = try store.insertSeedFrame(
            timestampMs: 4,
            foreground: "c",
            bundleID: "dev.app",
            domain: "other.com",
            url: "https://other.com/"
        )
        let dApp = try store.insertSeedFrame(
            timestampMs: 5,
            foreground: "d",
            bundleID: "dev.other",
            domain: "other.com",
            url: "https://other.com/"
        )

        let f1 = try store.frame(id: a1)!
        let f2 = try store.frame(id: a2)!
        let f3 = try store.frame(id: bURL)!
        let f4 = try store.frame(id: cDomain)!
        let f5 = try store.frame(id: dApp)!

        XCTAssertEqual(f1.segmentID, f2.segmentID, "same app/domain/url extends segment")
        XCTAssertNotEqual(f2.segmentID, f3.segmentID, "url change opens new segment")
        XCTAssertNotEqual(f3.segmentID, f4.segmentID, "domain change opens new segment")
        XCTAssertNotEqual(f4.segmentID, f5.segmentID, "app change opens new segment")
    }

    // MARK: - Helpers

    private func sliceUTF16(_ string: String, offset: Int, length: Int) -> String {
        guard length > 0, offset >= 0 else { return "" }
        let u = string.utf16
        guard offset < u.count else { return "" }
        let start = u.index(u.startIndex, offsetBy: offset)
        let endOffset = min(offset + length, u.count)
        let end = u.index(u.startIndex, offsetBy: endOffset)
        return String(utf16CodeUnits: Array(u[start..<end]), count: endOffset - offset)
    }
}
