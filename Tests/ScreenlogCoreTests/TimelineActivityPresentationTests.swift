import XCTest

@testable import ScreenlogCore

final class TimelineActivityPresentationTests: XCTestCase {
    func testGapThresholdFollowsCadenceWithinSessionBoundary() {
        XCTAssertEqual(
            TimelineActivityPresentation.gapThreshold(expectedCaptureIntervalMs: 2_000),
            10_000
        )
        XCTAssertEqual(
            TimelineActivityPresentation.gapThreshold(expectedCaptureIntervalMs: 10_000),
            40_000
        )
        XCTAssertEqual(
            TimelineActivityPresentation.gapThreshold(
                expectedCaptureIntervalMs: 120_000,
                sessionBoundaryMs: 300_000
            ),
            300_000
        )
    }

    func testSourceRunsMeetAtMidpointWhileCaptureGapRemainsEmpty() throws {
        let presentation = makePresentation(
            frames: [
                frame(1, at: 0, app: "Mail", bundleID: "com.apple.mail"),
                frame(2, at: 2_000, app: "Mail", bundleID: "com.apple.mail"),
                frame(3, at: 4_000, app: "Safari", bundleID: "com.apple.Safari"),
                frame(4, at: 30_000, app: "Notes", bundleID: "com.apple.Notes"),
                frame(5, at: 32_000, app: "Notes", bundleID: "com.apple.Notes"),
            ],
            endMs: 32_000
        )

        XCTAssertEqual(presentation.gapThresholdMs, 10_000)
        XCTAssertEqual(presentation.intervals.count, 3)

        let mail = try XCTUnwrap(presentation.intervals.first)
        XCTAssertEqual(mail.source.appLabel, "Mail")
        XCTAssertEqual(mail.startMs, 0)
        XCTAssertEqual(mail.endMs, 3_000)
        XCTAssertEqual(mail.momentCount, 2)

        let safari = presentation.intervals[1]
        XCTAssertEqual(safari.source.appLabel, "Safari")
        XCTAssertEqual(safari.startMs, 3_000)
        XCTAssertEqual(safari.endMs, 4_000)

        XCTAssertEqual(
            presentation.gaps,
            [.init(id: 4_000, startMs: 4_000, endMs: 30_000)]
        )

        let notes = presentation.intervals[2]
        XCTAssertEqual(notes.source.appLabel, "Notes")
        XCTAssertEqual(notes.startMs, 30_000)
        XCTAssertEqual(notes.endMs, 32_000)
    }

    func testVisibleWindowClipsIntervalsAndPreservesGapInterior() {
        let presentation = TimelineActivityPresentation(
            chronologicalFrames: [
                frame(1, at: 0, app: "Mail", bundleID: "com.apple.mail"),
                frame(2, at: 2_000, app: "Mail", bundleID: "com.apple.mail"),
                frame(3, at: 30_000, app: "Notes", bundleID: "com.apple.Notes"),
                frame(4, at: 32_000, app: "Notes", bundleID: "com.apple.Notes"),
            ],
            visibleStartMs: 1_000,
            visibleEndMs: 31_000,
            expectedCaptureIntervalMs: 2_000
        )

        XCTAssertEqual(presentation.intervals.map(\.startMs), [1_000, 30_000])
        XCTAssertEqual(presentation.intervals.map(\.endMs), [2_000, 31_000])
        XCTAssertEqual(presentation.gaps.map(\.startMs), [2_000])
        XCTAssertEqual(presentation.gaps.map(\.endMs), [30_000])
    }

    func testGapSelectionUsesNearestBoundaryAndEarlierOnTie() throws {
        let presentation = makePresentation(
            frames: [
                frame(1, at: 0, app: "Mail", bundleID: "com.apple.mail"),
                frame(2, at: 2_000, app: "Mail", bundleID: "com.apple.mail"),
                frame(3, at: 30_000, app: "Notes", bundleID: "com.apple.Notes"),
            ],
            endMs: 30_000
        )

        XCTAssertEqual(
            try XCTUnwrap(presentation.selection(at: 10_000)),
            .init(frameID: 2, timestampMs: 2_000, crossedGap: true)
        )
        XCTAssertEqual(
            try XCTUnwrap(presentation.selection(at: 16_000)),
            .init(frameID: 2, timestampMs: 2_000, crossedGap: true)
        )
        XCTAssertEqual(
            try XCTUnwrap(presentation.selection(at: 20_000)),
            .init(frameID: 3, timestampMs: 30_000, crossedGap: true)
        )
    }

    func testDeltaBelowThresholdDoesNotCreateGap() {
        let presentation = makePresentation(
            frames: [
                frame(1, at: 0, app: "Mail", bundleID: "com.apple.mail"),
                frame(2, at: 9_999, app: "Mail", bundleID: "com.apple.mail"),
            ],
            endMs: 9_999
        )

        XCTAssertTrue(presentation.gaps.isEmpty)
        XCTAssertEqual(presentation.intervals.count, 1)
        XCTAssertEqual(presentation.intervals[0].startMs, 0)
        XCTAssertEqual(presentation.intervals[0].endMs, 9_999)
    }

    func testThresholdSizedDeltaStartsANewCaptureBlock() {
        let presentation = makePresentation(
            frames: [
                frame(1, at: 0, app: "Mail", bundleID: "com.apple.mail"),
                frame(2, at: 10_000, app: "Mail", bundleID: "com.apple.mail"),
            ],
            endMs: 10_000
        )

        XCTAssertEqual(presentation.gaps.map(\.durationMs), [10_000])
        XCTAssertEqual(presentation.intervals.map(\.durationMs), [0, 0])
    }

    func testFallbackSourceIdentityDoesNotMergeDifferentAppLabels() {
        let presentation = makePresentation(
            frames: [
                frame(1, at: 0, app: "First app"),
                frame(2, at: 2_000, app: "Second app"),
            ],
            endMs: 2_000
        )

        XCTAssertEqual(presentation.intervals.map(\.source.appLabel), ["First app", "Second app"])
    }

    private func makePresentation(frames: [TimelineFrame], endMs: Int64) -> TimelineActivityPresentation {
        TimelineActivityPresentation(
            chronologicalFrames: frames,
            visibleStartMs: 0,
            visibleEndMs: endMs,
            expectedCaptureIntervalMs: 2_000
        )
    }

    private func frame(
        _ id: Int64,
        at timestampMs: Int64,
        app: String,
        bundleID: String? = nil,
        domain: String? = nil
    ) -> TimelineFrame {
        TimelineFrame(
            id: id,
            timestampMs: timestampMs,
            bundleID: bundleID,
            displayName: app,
            domain: domain
        )
    }
}
