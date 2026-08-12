import ScreenlogCore
import XCTest

final class TimelineTranscriptPresentationTests: XCTestCase {
    func testAdjacentSameSourceSegmentsMergeWithoutChangingCanonicalRows() {
        let segments = [
            segment(id: 1, start: 1_000, end: 2_000, source: .microphone, text: "First thought."),
            segment(id: 2, start: 2_800, end: 4_000, source: .microphone, text: "Second thought."),
        ]

        let passages = TimelineTranscriptPresentation.passages(from: segments)

        XCTAssertEqual(passages.count, 1)
        XCTAssertEqual(passages[0].segmentIDs, [1, 2])
        XCTAssertEqual(passages[0].text, "First thought. Second thought.")
        XCTAssertEqual(segments.map(\.text), ["First thought.", "Second thought."])
    }

    func testSourceGapAndDurationBoundariesKeepPassagesReadable() {
        let segments = [
            segment(id: 1, start: 1_000, end: 2_000, source: .microphone, text: "One"),
            segment(id: 2, start: 2_200, end: 3_000, source: .computer, text: "Two"),
            segment(id: 3, start: 5_000, end: 6_000, source: .computer, text: "Three"),
            segment(id: 4, start: 6_200, end: 40_000, source: .computer, text: "Four"),
        ]

        let passages = TimelineTranscriptPresentation.passages(from: segments)

        XCTAssertEqual(passages.map(\.segmentIDs), [[1], [2], [3], [4]])
    }

    func testVisiblePassagesStayCenteredOnActiveSpeech() {
        var segments: [TranscriptSegment] = []
        for index in 0..<5 {
            let start = Int64(index) * 10_000
            segments.append(
                segment(
                    id: Int64(index + 1),
                    start: start,
                    end: start + 2_000,
                    source: .microphone,
                    text: "Passage \(index + 1)"
                )
            )
        }
        let passages = TimelineTranscriptPresentation.passages(from: segments)

        let visible = TimelineTranscriptPresentation.visiblePassages(
            from: passages,
            selectedTimestampMs: 31_000,
            limit: 3
        )

        XCTAssertEqual(visible.map { $0.id }, [3, 4, 5])
        XCTAssertTrue(visible[1].contains(timestampMs: 31_000))
    }

    func testTranscriptPanelHidesWhenSelectionIsFarFromSpeech() {
        let passages = TimelineTranscriptPresentation.passages(
            from: [segment(id: 1, start: 1_000, end: 2_000, source: .computer, text: "Hello")]
        )

        XCTAssertTrue(
            TimelineTranscriptPresentation.visiblePassages(
                from: passages,
                selectedTimestampMs: 30_000
            ).isEmpty
        )
    }

    private func segment(
        id: Int64,
        start: Int64,
        end: Int64,
        source: TranscriptSource,
        text: String
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            frameID: id,
            startTimestampMs: start,
            endTimestampMs: end,
            source: source,
            text: text
        )
    }
}
