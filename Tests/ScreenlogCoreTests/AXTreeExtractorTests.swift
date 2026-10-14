import ApplicationServices
@testable import ScreenlogCore
import XCTest

final class AXTreeExtractorTests: XCTestCase {
    func testAccessibilityElementRejectsUnexpectedCoreFoundationType() {
        let value = "not an accessibility element" as CFString
        XCTAssertNil(AXTreeExtractor.accessibilityElement(from: value))
    }

    func testAccessibilityElementAcceptsAXElement() {
        let element = AXUIElementCreateSystemWide()
        XCTAssertNotNil(AXTreeExtractor.accessibilityElement(from: element))
    }

    func testPointAndSizeRequireMatchingAXValueTypes() throws {
        var point = CGPoint(x: -120, y: 48)
        var size = CGSize(width: 1_440, height: 900)
        let pointValue = try XCTUnwrap(AXValueCreate(.cgPoint, &point))
        let sizeValue = try XCTUnwrap(AXValueCreate(.cgSize, &size))

        XCTAssertEqual(AXTreeExtractor.point(from: pointValue), point)
        XCTAssertEqual(AXTreeExtractor.size(from: sizeValue), size)
        XCTAssertNil(AXTreeExtractor.point(from: sizeValue))
        XCTAssertNil(AXTreeExtractor.size(from: pointValue))
        XCTAssertNil(AXTreeExtractor.point(from: "wrong" as CFString))
        XCTAssertNil(AXTreeExtractor.size(from: NSNumber(value: 42)))
    }

    func testBackgroundExtractionRejectsTheCurrentProcess() {
        XCTAssertFalse(
            AXTreeExtractor.shouldInspect(
                focusedPID: 42,
                expectedPID: 42,
                currentProcessID: 42
            )
        )
    }

    func testExtractionRejectsFocusChangesAfterTheScreenshot() {
        XCTAssertFalse(
            AXTreeExtractor.shouldInspect(
                focusedPID: 43,
                expectedPID: 42,
                currentProcessID: 99
            )
        )
        XCTAssertTrue(
            AXTreeExtractor.shouldInspect(
                focusedPID: 42,
                expectedPID: 42,
                currentProcessID: 99
            )
        )
    }

    func testGeometryIsLimitedToWindowsAndShallowChrome() {
        XCTAssertTrue(AXTreeExtractor.shouldCaptureGeometry(role: "AXGroup", depth: 0))
        XCTAssertTrue(AXTreeExtractor.shouldCaptureGeometry(role: "AXGroup", depth: 1))
        XCTAssertFalse(AXTreeExtractor.shouldCaptureGeometry(role: "AXGroup", depth: 2))
        XCTAssertTrue(AXTreeExtractor.shouldCaptureGeometry(role: "AXWindow", depth: 4))
        XCTAssertTrue(AXTreeExtractor.shouldCaptureGeometry(role: "AXSheet", depth: 3))
        XCTAssertFalse(AXTreeExtractor.shouldCaptureGeometry(role: "AXWebArea", depth: 6))
    }

    func testBrowserNodeCapIsLowerThanDefault() {
        XCTAssertEqual(AXTreeExtractor.nodeLimit(bundleID: "com.apple.Safari"), 800)
        XCTAssertEqual(AXTreeExtractor.nodeLimit(bundleID: "com.apple.dt.Xcode"), 1_500)
        XCTAssertLessThan(AXTreeExtractor.browserMaxNodes, AXTreeExtractor.defaultMaxNodes)
    }

    func testAXErrorValuesAreTreatedAsMissingAttributes() {
        var error = AXError.attributeUnsupported
        let wrapped = AXValueCreate(.axError, &error)
        XCTAssertNotNil(wrapped)
        if let wrapped {
            XCTAssertNil(AXTreeExtractor.unpackedAttributeValue(wrapped))
        }
        XCTAssertNil(AXTreeExtractor.unpackedAttributeValue(NSNull()))
        XCTAssertNotNil(AXTreeExtractor.unpackedAttributeValue("AXButton" as CFString))
    }
}
