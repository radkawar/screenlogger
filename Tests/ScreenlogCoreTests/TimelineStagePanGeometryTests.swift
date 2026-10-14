import CoreGraphics
import XCTest

@testable import ScreenlogCore

final class TimelineStagePanGeometryTests: XCTestCase {
    func testLandscapeCaptureOnlyPansWhereZoomedContentExceedsViewport() {
        let bounds = TimelineStagePanGeometry.offsetBounds(
            sourceSize: CGSize(width: 1_920, height: 1_080),
            viewportSize: CGSize(width: 1_000, height: 1_000),
            zoom: 2
        )

        XCTAssertEqual(bounds.width, 500, accuracy: 0.000_1)
        XCTAssertEqual(bounds.height, 62.5, accuracy: 0.000_1)
    }

    func testPortraitCaptureUsesIndependentAxisBounds() {
        let bounds = TimelineStagePanGeometry.offsetBounds(
            sourceSize: CGSize(width: 1_000, height: 2_000),
            viewportSize: CGSize(width: 1_200, height: 600),
            zoom: 3
        )

        XCTAssertEqual(bounds.width, 0, accuracy: 0.000_1)
        XCTAssertEqual(bounds.height, 600, accuracy: 0.000_1)
    }

    func testOffsetClampsBothDirections() {
        let clamped = TimelineStagePanGeometry.clampedOffset(
            CGSize(width: -900, height: 400),
            sourceSize: CGSize(width: 1_920, height: 1_080),
            viewportSize: CGSize(width: 1_000, height: 1_000),
            zoom: 2
        )

        XCTAssertEqual(clamped.width, -500, accuracy: 0.000_1)
        XCTAssertEqual(clamped.height, 62.5, accuracy: 0.000_1)
    }

    func testNoPanAtOneHundredPercentOrForInvalidGeometry() {
        XCTAssertEqual(
            TimelineStagePanGeometry.offsetBounds(
                sourceSize: CGSize(width: 1_920, height: 1_080),
                viewportSize: CGSize(width: 1_000, height: 1_000),
                zoom: 1
            ),
            .zero
        )
        XCTAssertEqual(
            TimelineStagePanGeometry.clampedOffset(
                CGSize(width: CGFloat.infinity, height: 1),
                sourceSize: CGSize(width: 1_920, height: 1_080),
                viewportSize: CGSize(width: 1_000, height: 1_000),
                zoom: 2
            ),
            .zero
        )
    }
}
