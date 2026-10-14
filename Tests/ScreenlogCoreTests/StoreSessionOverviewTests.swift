import Foundation
@testable import ScreenlogCore
import XCTest

final class StoreSessionOverviewTests: XCTestCase {
    private var root: URL!
    private var store: Store!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-session-overview-\(UUID().uuidString)", isDirectory: true)
        store = try Store(root: root.appendingPathComponent("live", isDirectory: true))
    }

    override func tearDownWithError() throws {
        store = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testNameSurvivesReopeningAndLiveGrowthWithoutChangingIdentity() throws {
        try seed(1_000, app: "dev.editor")
        let original = try XCTUnwrap(store.sessions().first)
        XCTAssertNil(original.customName)
        XCTAssertEqual(try store.setSessionName(startMs: original.startMs, name: "  Launch review\n"), "Launch review")

        store = nil
        store = try Store(root: root.appendingPathComponent("live", isDirectory: true))
        try seed(3_000, app: "dev.browser")
        let grown = try XCTUnwrap(store.sessions().first)
        XCTAssertEqual(grown.customName, "Launch review")
        XCTAssertEqual(grown.displayTitle, "Launch review")
        XCTAssertEqual(grown.id, original.id)
        XCTAssertEqual(grown.startMs, original.startMs)
        XCTAssertEqual(grown.endMs, 3_000)
        XCTAssertEqual(grown.momentCount, 2)
        XCTAssertEqual(try store.sessions(fromTimestampMs: original.startMs).first?.customName, "Launch review")
    }

    func testResetAndWhitespaceRemoveOnlySelectedName() throws {
        try seed(1_000, app: "dev.editor")
        try seed(600_000, app: "dev.browser")
        try store.setSessionName(startMs: 1_000, name: "First")
        try store.setSessionName(startMs: 600_000, name: "Second")
        XCTAssertNil(try store.setSessionName(startMs: 1_000, name: " \n\t "))
        XCTAssertNil(try store.getMeta(key: "session.name.1000"))
        let first = try XCTUnwrap(store.sessions().last)
        XCTAssertNil(first.customName)
        XCTAssertEqual(first.displayTitle, first.appLabel)
        XCTAssertEqual(try store.sessions(limit: 1).first?.customName, "Second")

        XCTAssertNil(try store.setSessionName(startMs: 600_000, name: nil))
        store = nil
        store = try Store(root: root.appendingPathComponent("live", isDirectory: true))
        XCTAssertTrue(try store.sessions().allSatisfy { $0.customName == nil })
    }

    func testNameIsIncludedInExistingLibraryBackup() throws {
        try seed(1_000, app: "dev.editor")
        try store.setSessionName(startMs: 1_000, name: "Backed up name")
        let destination = root.appendingPathComponent("Saved.screenloggerbackup", isDirectory: true)
        let service = LibraryExportService()
        let exported = try service.export(store: store, to: destination)
        XCTAssertEqual(service.preflightRestore(at: destination), .ready(exported.manifest))
        let copy = try Store(root: destination.appendingPathComponent("Library", isDirectory: true))
        XCTAssertEqual(try copy.sessions().first?.customName, "Backed up name")
    }

    func testCoverageMatchesRibbonMidpointsWithoutDoubleCountingDisplaysOrGaps() throws {
        let firstID = try seed(1_000, app: "dev.alpha", domain: "alpha.test")
        let otherDisplayID = try seed(1_000, app: "dev.ignored", domain: "ignored.test")
        try seed(3_001, app: "dev.beta", domain: "beta.test")
        // Exactly the 10-second continuity threshold: none of this gap counts.
        try seed(13_001, app: "dev.beta")
        try seed(15_001, app: "dev.alpha", domain: "alpha.test")
        let session = try XCTUnwrap(store.sessions().first)
        let overview = try store.sessionOverview(session: session, expectedCaptureIntervalMs: 1_000)
        XCTAssertEqual(overview.momentCount, 4)
        XCTAssertEqual(overview.coveredDurationMs, 4_001)
        XCTAssertEqual(session.durationMs, 14_001)
        XCTAssertEqual(overview.applicationCount, 2)
        let apps = Dictionary(uniqueKeysWithValues: overview.applications.map { ($0.identifier, $0.durationMs) })
        XCTAssertEqual(apps, ["dev.alpha": 2_000, "dev.beta": 2_001])
        XCTAssertEqual(overview.applications.reduce(0) { $0 + $1.durationMs }, overview.coveredDurationMs)
        let domains = Dictionary(uniqueKeysWithValues: overview.domains.map { ($0.identifier, $0.durationMs) })
        XCTAssertEqual(domains, ["alpha.test": 2_000, "beta.test": 1_001])
        XCTAssertEqual(overview.moments.first?.id, firstID)
        XCTAssertFalse(overview.moments.contains { $0.id == otherDisplayID })

        let frames = try store.timeline(session: session).sorted(by: TimelineFrame.chronologicalAscending)
        let index = TimelineNavigationIndex(frames: frames)
        let representatives = index.representativeFramePositions.map { frames[$0] }
        let ribbon = TimelineActivityPresentation(
            chronologicalFrames: representatives,
            visibleStartMs: session.startMs,
            visibleEndMs: session.endMs,
            expectedCaptureIntervalMs: 1_000
        )
        XCTAssertEqual(ribbon.intervals.reduce(0) { $0 + $1.durationMs }, overview.coveredDurationMs)
    }

    func testInclusiveBoundsDoNotBorrowCoverageFromNeighboringCaptures() throws {
        try seed(999, app: "dev.before")
        let selectedID = try seed(1_000, app: "dev.selected")
        try seed(1_001, app: "dev.after")
        let selected = SessionRow(startMs: 1_000, endMs: 1_000, frameCount: 1)
        let overview = try store.sessionOverview(session: selected, expectedCaptureIntervalMs: 1_000)
        XCTAssertEqual(overview.momentCount, 1)
        XCTAssertEqual(overview.coveredDurationMs, 0)
        XCTAssertEqual(overview.applications.map(\.identifier), ["dev.selected"])
        XCTAssertEqual(overview.moments.map(\.id), [selectedID])
    }

    func testCadenceUsesSameContinuityThresholdAsTimeline() throws {
        try seed(1_000, app: "dev.editor")
        try seed(11_000, app: "dev.editor")
        let session = try XCTUnwrap(store.sessions().first)
        let fast = try store.sessionOverview(session: session, expectedCaptureIntervalMs: 1_000)
        let slow = try store.sessionOverview(session: session, expectedCaptureIntervalMs: 5_000)
        XCTAssertEqual(fast.coveredDurationMs, 0)
        XCTAssertEqual(slow.gapThresholdMs, 20_000)
        XCTAssertEqual(slow.coveredDurationMs, 10_000)
    }

    func testRepresentativeMomentsAndBreakdownsRemainBounded() throws {
        for index in 0..<30 {
            try seed(Int64(index + 1) * 1_000, app: "dev.app\(index)", domain: "site\(index).test")
        }
        let session = try XCTUnwrap(store.sessions().first)
        let overview = try store.sessionOverview(session: session, expectedCaptureIntervalMs: 1_000)
        XCTAssertEqual(overview.momentCount, 30)
        XCTAssertEqual(overview.applicationCount, 30)
        XCTAssertEqual(overview.domainCount, 30)
        XCTAssertEqual(overview.applications.count, 8)
        XCTAssertEqual(overview.domains.count, 8)
        XCTAssertEqual(overview.moments.count, 6)
        XCTAssertEqual(Set(overview.moments.map(\.timestampMs)).count, overview.moments.count)
        XCTAssertEqual(overview.moments.first?.timestampMs, session.startMs)
        XCTAssertEqual(overview.moments.last?.timestampMs, session.endMs)
        XCTAssertEqual(overview.coveredDurationMs, session.durationMs)
    }

    func testEmptyRangeHasNoInventedActivity() throws {
        try seed(1_000, app: "dev.outside")
        let overview = try store.sessionOverview(
            session: SessionRow(startMs: 5_000, endMs: 8_000, frameCount: 0),
            expectedCaptureIntervalMs: 1_000
        )
        XCTAssertEqual(overview.coveredDurationMs, 0)
        XCTAssertEqual(overview.momentCount, 0)
        XCTAssertTrue(overview.applications.isEmpty)
        XCTAssertTrue(overview.domains.isEmpty)
        XCTAssertTrue(overview.moments.isEmpty)
    }

    @discardableResult
    private func seed(_ timestamp: Int64, app: String, domain: String? = nil) throws -> Int64 {
        try store.insertSeedFrame(
            timestampMs: timestamp,
            foreground: "Recorded context",
            title: "Window at \(timestamp)",
            bundleID: app,
            domain: domain
        )
    }
}
