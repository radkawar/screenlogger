import CoreGraphics
import XCTest

@testable import ScreenlogCore

final class OCRHighlightTransformTests: XCTestCase {
    func testLandscapeImageUsesVerticalLetterboxing() throws {
        let transform = OCRHighlightTransform(
            sourceSize: CGSize(width: 1920, height: 1080),
            viewportSize: CGSize(width: 1000, height: 1000)
        )

        let content = try XCTUnwrap(transform.renderedContentRect)
        assertRect(content, x: 0, y: 218.75, width: 1000, height: 562.5)

        let projected = try XCTUnwrap(
            transform.project(box(x: 192, y: 108, width: 384, height: 216))
        )
        assertRect(projected, x: 100, y: 275, width: 200, height: 112.5)
    }

    func testPortraitImageUsesHorizontalLetterboxing() throws {
        let transform = OCRHighlightTransform(
            sourceSize: CGSize(width: 1000, height: 2000),
            viewportSize: CGSize(width: 1200, height: 600)
        )

        let content = try XCTUnwrap(transform.renderedContentRect)
        assertRect(content, x: 450, y: 0, width: 300, height: 600)

        let projected = try XCTUnwrap(
            transform.project(box(x: 100, y: 200, width: 200, height: 400))
        )
        assertRect(projected, x: 480, y: 60, width: 60, height: 120)
    }

    func testUltrawideAspectRatioRemainsCentered() throws {
        let transform = OCRHighlightTransform(
            sourceSize: CGSize(width: 3440, height: 1440),
            viewportSize: CGSize(width: 800, height: 600)
        )
        let scale = 800.0 / 3440.0
        let expectedHeight = 1440.0 * scale

        let content = try XCTUnwrap(transform.renderedContentRect)
        assertRect(
            content,
            x: 0,
            y: (600 - expectedHeight) / 2,
            width: 800,
            height: expectedHeight
        )
    }

    func testZoomOutScalesAroundViewportCenter() throws {
        let transform = OCRHighlightTransform(
            sourceSize: CGSize(width: 1920, height: 1080),
            viewportSize: CGSize(width: 1000, height: 1000),
            zoom: 0.5
        )

        let content = try XCTUnwrap(transform.renderedContentRect)
        assertRect(content, x: 250, y: 359.375, width: 500, height: 281.25)
    }

    func testZoomInProjectsCenterBoxAndClipsFullImage() throws {
        let transform = OCRHighlightTransform(
            sourceSize: CGSize(width: 1920, height: 1080),
            viewportSize: CGSize(width: 1000, height: 1000),
            zoom: 2
        )

        let content = try XCTUnwrap(transform.renderedContentRect)
        assertRect(content, x: -500, y: -62.5, width: 2000, height: 1125)

        let center = try XCTUnwrap(
            transform.project(box(x: 480, y: 270, width: 960, height: 540))
        )
        assertRect(center, x: 0, y: 218.75, width: 1000, height: 562.5)

        let fullImage = try XCTUnwrap(
            transform.project(box(x: 0, y: 0, width: 1920, height: 1080))
        )
        assertRect(fullImage, x: 0, y: 0, width: 1000, height: 1000)
    }

    func testMalformedBoxIsClippedToSourceBeforeProjection() throws {
        let transform = OCRHighlightTransform(
            sourceSize: CGSize(width: 100, height: 100),
            viewportSize: CGSize(width: 200, height: 200)
        )

        let projected = try XCTUnwrap(
            transform.project(box(x: -10, y: 20, width: 30, height: 40))
        )
        assertRect(projected, x: 0, y: 40, width: 40, height: 80)
    }

    func testZoomedBoxIsClippedToVisibleViewport() throws {
        let transform = OCRHighlightTransform(
            sourceSize: CGSize(width: 100, height: 100),
            viewportSize: CGSize(width: 100, height: 100),
            zoom: 2
        )

        let projected = try XCTUnwrap(
            transform.project(box(x: 0, y: 25, width: 40, height: 50))
        )
        assertRect(projected, x: 0, y: 0, width: 30, height: 100)
    }

    func testPannedZoomProjectsAndClipsWithTheImage() throws {
        let transform = OCRHighlightTransform(
            sourceSize: CGSize(width: 100, height: 100),
            viewportSize: CGSize(width: 100, height: 100),
            zoom: 2,
            contentOffset: CGSize(width: 50, height: 0)
        )

        let leftEdge = try XCTUnwrap(
            transform.project(box(x: 0, y: 25, width: 25, height: 50))
        )
        assertRect(leftEdge, x: 0, y: 0, width: 50, height: 100)
        XCTAssertNil(transform.project(box(x: 75, y: 25, width: 25, height: 50)))
    }

    func testBoxesOutsideSourceAndInvalidGeometryAreRejected() {
        let valid = OCRHighlightTransform(
            sourceSize: CGSize(width: 100, height: 100),
            viewportSize: CGSize(width: 200, height: 200)
        )
        XCTAssertNil(valid.project(box(x: 120, y: 10, width: 20, height: 20)))
        XCTAssertNil(valid.project(box(x: 10, y: 10, width: 0, height: 20)))
        XCTAssertNil(valid.project(box(x: 10, y: 10, width: -5, height: 20)))

        XCTAssertNil(
            OCRHighlightTransform(
                sourceSize: .zero,
                viewportSize: CGSize(width: 100, height: 100)
            ).renderedContentRect
        )
        XCTAssertNil(
            OCRHighlightTransform(
                sourceSize: CGSize(width: 100, height: 100),
                viewportSize: CGSize(width: 100, height: 100),
                zoom: 0
            ).project(box(x: 0, y: 0, width: 10, height: 10))
        )
    }

    private func box(x: Int, y: Int, width: Int, height: Int) -> OCRBox {
        OCRBox(
            x: x,
            y: y,
            width: width,
            height: height,
            textOffset: 0,
            textLength: 1
        )
    }

    private func assertRect(
        _ rect: CGRect,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        accuracy: CGFloat = 0.000_1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(rect.origin.x, x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rect.origin.y, y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rect.size.width, width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rect.size.height, height, accuracy: accuracy, file: file, line: line)
    }
}
