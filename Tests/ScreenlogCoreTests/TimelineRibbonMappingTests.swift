import XCTest

@testable import ScreenlogCore

final class TimelineRibbonMappingTests: XCTestCase {
    func testFullRangeIgnoresSelection() {
        let window = TimelineRibbonMapping.window(
            firstTimestampMs: 0,
            lastTimestampMs: 240_000,
            selectedTimestampMs: 60_000,
            scaleStep: 0
        )

        XCTAssertEqual(window, .init(startMs: 0, endMs: 240_000))
    }

    func testScaledWindowCentersSelectionAndClampsAtRangeEdges() {
        XCTAssertEqual(
            TimelineRibbonMapping.window(
                firstTimestampMs: 0,
                lastTimestampMs: 240_000,
                selectedTimestampMs: 120_000,
                scaleStep: 2
            ),
            .init(startMs: 90_000, endMs: 150_000)
        )
        XCTAssertEqual(
            TimelineRibbonMapping.window(
                firstTimestampMs: 0,
                lastTimestampMs: 240_000,
                selectedTimestampMs: 0,
                scaleStep: 2
            ),
            .init(startMs: 0, endMs: 60_000)
        )
        XCTAssertEqual(
            TimelineRibbonMapping.window(
                firstTimestampMs: 0,
                lastTimestampMs: 240_000,
                selectedTimestampMs: 240_000,
                scaleStep: 2
            ),
            .init(startMs: 180_000, endMs: 240_000)
        )
    }

    func testPositionAndTimestampMappingsClampToVisibleWindow() {
        let window = TimelineRibbonMapping.Window(startMs: 90_000, endMs: 150_000)

        XCTAssertEqual(TimelineRibbonMapping.x(timestampMs: 90_000, in: window, width: 200), 0)
        XCTAssertEqual(TimelineRibbonMapping.x(timestampMs: 120_000, in: window, width: 200), 100)
        XCTAssertEqual(TimelineRibbonMapping.x(timestampMs: 170_000, in: window, width: 200), 200)
        XCTAssertEqual(TimelineRibbonMapping.timestamp(x: -20, in: window, width: 200), 90_000)
        XCTAssertEqual(TimelineRibbonMapping.timestamp(x: 150, in: window, width: 200), 135_000)
        XCTAssertEqual(TimelineRibbonMapping.timestamp(x: 220, in: window, width: 200), 150_000)
    }

    func testRetainingInitialWindowPreventsSelectionFeedbackDuringScrub() {
        let initialWindow = TimelineRibbonMapping.window(
            firstTimestampMs: 0,
            lastTimestampMs: 240_000,
            selectedTimestampMs: 120_000,
            scaleStep: 2
        )
        let firstSelection = TimelineRibbonMapping.timestamp(x: 150, in: initialWindow, width: 200)
        let recenteredWindow = TimelineRibbonMapping.window(
            firstTimestampMs: 0,
            lastTimestampMs: 240_000,
            selectedTimestampMs: firstSelection,
            scaleStep: 2
        )

        XCTAssertEqual(firstSelection, 135_000)
        XCTAssertEqual(
            TimelineRibbonMapping.timestamp(x: 150, in: initialWindow, width: 200),
            135_000
        )
        XCTAssertEqual(
            TimelineRibbonMapping.timestamp(x: 150, in: recenteredWindow, width: 200),
            150_000,
            "Recentering during the drag would move the pointer's meaning by 15 seconds"
        )
    }
}
