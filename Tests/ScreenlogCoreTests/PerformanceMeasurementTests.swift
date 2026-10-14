import XCTest

@testable import ScreenlogCore

final class PerformanceMeasurementTests: XCTestCase {
    func testNearestRankPercentileIsDeterministicAndBoundsPercentile() {
        let samples = [9.0, 1.0, 5.0, 3.0, 7.0]
        XCTAssertEqual(PerformanceStatistics.percentile(samples, percentile: 0), 1)
        XCTAssertEqual(PerformanceStatistics.percentile(samples, percentile: 0.5), 5)
        XCTAssertEqual(PerformanceStatistics.percentile(samples, percentile: 0.95), 9)
        XCTAssertEqual(PerformanceStatistics.percentile(samples, percentile: 2), 9)
        XCTAssertNil(PerformanceStatistics.percentile([], percentile: 0.95))
    }

    func testBudgetEvaluationClassifiesWithinNearOverAndMissing() throws {
        let budgets = [
            PerformanceBudget(
                metric: .warmLibrarySearch,
                statistic: "p95",
                unit: .milliseconds,
                limit: 100
            ),
            PerformanceBudget(
                metric: .firstThumbnailDecode,
                statistic: "first",
                unit: .milliseconds,
                limit: 100
            ),
            PerformanceBudget(
                metric: .timelineFrameExtraction,
                statistic: "p95",
                unit: .milliseconds,
                limit: 100
            ),
            PerformanceBudget(
                metric: .residentMemory,
                statistic: "peak",
                unit: .mebibytes,
                limit: 100
            ),
        ]
        let observations = [
            observation(.warmLibrarySearch, statistic: "p95", value: 79),
            observation(.firstThumbnailDecode, statistic: "first", value: 80),
            observation(.timelineFrameExtraction, statistic: "p95", value: 100.01),
        ]

        let evaluations = PerformanceBudgetEvaluator.evaluate(
            budgets: budgets,
            observations: observations
        )

        XCTAssertEqual(
            evaluations.map(\.status),
            [
                .withinBudget,
                .nearBudget,
                .overBudget,
                .missing,
            ])
        XCTAssertEqual(try XCTUnwrap(evaluations[0].utilization), 0.79, accuracy: 0.0001)
        XCTAssertNil(evaluations[3].observation)
        XCTAssertNil(evaluations[3].utilization)
    }

    func testEvaluationRequiresMatchingStatisticAndUnit() {
        let budget = PerformanceBudget(
            metric: .processCPU,
            statistic: "paced-average",
            unit: .percent,
            limit: 25
        )
        let mismatches = [
            PerformanceObservation(
                metric: .processCPU,
                statistic: "peak",
                unit: .percent,
                value: 1,
                sampleCount: 1
            ),
            PerformanceObservation(
                metric: .processCPU,
                statistic: "paced-average",
                unit: .milliseconds,
                value: 1,
                sampleCount: 1
            ),
        ]

        XCTAssertEqual(
            PerformanceBudgetEvaluator.evaluate(
                budgets: [budget],
                observations: mismatches
            ).first?.status,
            .missing
        )
    }

    func testDefaultBudgetsCoverEveryRequiredMetricExactlyOnce() {
        let budgets = PerformanceBudget.screenloggerDefaults
        XCTAssertEqual(budgets.count, PerformanceMetricID.allCases.count)
        XCTAssertEqual(Set(budgets.map(\.metric)), Set(PerformanceMetricID.allCases))
        XCTAssertTrue(budgets.allSatisfy { $0.limit > 0 })
        XCTAssertTrue(budgets.allSatisfy { (0..<1).contains($0.warningRatio) })
    }

    func testRapidTimelineSelectionsCoalesceToLatestRequest() {
        let offsets = (0..<25).map { $0 * 20 }

        XCTAssertEqual(
            TimelinePreviewPolicy.settledSelectionIndices(eventOffsetsMilliseconds: offsets),
            [24]
        )
    }

    func testSelectedTimelinePreviewDoesNotDownsampleAppleSixKDisplays() {
        XCTAssertGreaterThanOrEqual(TimelinePreviewPolicy.selectedMaxPixelSize, 6_016)
        XCTAssertGreaterThanOrEqual(FrameExtractor.exportedStillQuality, 0.95)
    }

    func testTimelineSelectionAfterPauseIsAllowedToDecode() {
        XCTAssertEqual(
            TimelinePreviewPolicy.settledSelectionIndices(
                eventOffsetsMilliseconds: [0, 20, 100, 120]
            ),
            [1, 3]
        )
    }

    func testTimelineSelectionPolicyRejectsInvalidInput() {
        XCTAssertEqual(
            TimelinePreviewPolicy.settledSelectionIndices(
                eventOffsetsMilliseconds: [20, 10]
            ),
            []
        )
        XCTAssertEqual(
            TimelinePreviewPolicy.settledSelectionIndices(
                eventOffsetsMilliseconds: [0],
                debounceMilliseconds: -1
            ),
            []
        )
    }

    func testTimelineNavigationIndexFindsPositionsAndDetectsOrder() {
        let frames = [
            timelineFrame(id: 10),
            timelineFrame(id: 20),
            timelineFrame(id: 30),
        ]
        let index = TimelineNavigationIndex(frames: frames)

        XCTAssertTrue(index.isChronological)
        XCTAssertEqual(index.position(of: 10), 0)
        XCTAssertEqual(index.position(of: 20), 1)
        XCTAssertEqual(index.position(of: 30), 2)
        XCTAssertNil(index.position(of: 40))
    }

    func testTimelineNavigationIndexDetectsUnorderedInputAndPreservesFirstDuplicate() {
        let index = TimelineNavigationIndex(
            frames: [
                timelineFrame(id: 30),
                timelineFrame(id: 10),
                timelineFrame(id: 30),
            ])

        XCTAssertFalse(index.isChronological)
        XCTAssertEqual(index.position(of: 30), 0)
        XCTAssertEqual(index.position(of: 10), 1)
    }

    func testTimelineNavigationIndexGroupsDisplaysIntoSynchronizedMoments() {
        let index = TimelineNavigationIndex(
            frames: [
                TimelineFrame(id: 10, timestampMs: 1_000),
                TimelineFrame(id: 11, timestampMs: 1_000),
                TimelineFrame(id: 20, timestampMs: 2_000),
                TimelineFrame(id: 21, timestampMs: 2_000),
            ])

        XCTAssertTrue(index.isChronological)
        XCTAssertEqual(index.momentCount, 2)
        XCTAssertEqual(index.momentPosition(of: 10), 0)
        XCTAssertEqual(index.momentPosition(of: 11), 0)
        XCTAssertEqual(index.momentPosition(of: 20), 1)
        XCTAssertEqual(index.framePositions(inMomentContaining: 11), [0, 1])
        XCTAssertEqual(index.framePositions(inMoment: 1), [2, 3])
        XCTAssertEqual(index.representativeFramePositions, [0, 2])
    }

    func testTimelineNavigationIndexAcceptsRestoredIDsInTimestampOrder() {
        let frames = [
            TimelineFrame(id: 30, timestampMs: 1_000),
            TimelineFrame(id: 10, timestampMs: 2_000),
        ]
        let index = TimelineNavigationIndex(frames: frames)

        XCTAssertTrue(index.isChronological)
        XCTAssertEqual(index.momentCount, 2)
        XCTAssertEqual(
            frames.reversed().sorted(by: TimelineFrame.chronologicalAscending).map(\.id),
            [30, 10]
        )
    }

    private func observation(
        _ metric: PerformanceMetricID,
        statistic: String,
        value: Double
    ) -> PerformanceObservation {
        PerformanceObservation(
            metric: metric,
            statistic: statistic,
            unit: .milliseconds,
            value: value,
            sampleCount: 1
        )
    }

    private func timelineFrame(id: Int64) -> TimelineFrame {
        TimelineFrame(id: id, timestampMs: id * 1_000)
    }
}
