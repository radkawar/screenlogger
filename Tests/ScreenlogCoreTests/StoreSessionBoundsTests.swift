@testable import ScreenlogCore
import XCTest

/// `sessions(limit:)` bounds the window-function block scan to the newest N
/// sessions. Every case here pins the bounded result to the unbounded one so a
/// caller can adopt the limit without silently changing what it displays.
final class StoreSessionBoundsTests: XCTestCase {
    var tempRoot: URL!
    var store: Store!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-session-bounds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = try Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private static let gapMs: Int64 = 60_000

    /// `count` sessions of `momentsPerSession` moments each, one second apart,
    /// separated by a gap wide enough to break a session.
    @discardableResult
    private func seedSessions(count: Int, momentsPerSession: Int = 3) throws -> [Int64] {
        var startMs: [Int64] = []
        for session in 0..<count {
            let base = Int64(session) * 10 * Self.gapMs
            startMs.append(base)
            for moment in 0..<momentsPerSession {
                _ = try store.insertSeedFrame(
                    timestampMs: base + Int64(moment) * 1_000,
                    foreground: "session \(session) moment \(moment)",
                    bundleID: "dev.session.\(session)"
                )
            }
        }
        return startMs
    }

    func testLimitReturnsNewestSessionsIdenticalToUnboundedPrefix() throws {
        try seedSessions(count: 8)

        let all = try store.sessions(gapMs: Self.gapMs)
        XCTAssertEqual(all.count, 8)

        let bounded = try store.sessions(gapMs: Self.gapMs, limit: 3)
        XCTAssertEqual(bounded, Array(all.prefix(3)))
        XCTAssertEqual(bounded.map(\.frameCount), [3, 3, 3])
    }

    func testLimitLargerThanAvailableSessionsReturnsEverything() throws {
        try seedSessions(count: 4)

        let all = try store.sessions(gapMs: Self.gapMs)
        XCTAssertEqual(try store.sessions(gapMs: Self.gapMs, limit: 500), all)
    }

    func testLimitOfOneKeepsTheWholeNewestSession() throws {
        let starts = try seedSessions(count: 5, momentsPerSession: 6)

        let bounded = try store.sessions(gapMs: Self.gapMs, limit: 1)
        XCTAssertEqual(bounded.count, 1)
        XCTAssertEqual(bounded.first?.startMs, starts.last)
        // The block still starts at the true session start, not at an
        // arbitrary cut through the middle of it.
        XCTAssertEqual(bounded.first?.frameCount, 6)
        XCTAssertEqual(bounded.first?.endMs, (starts.last ?? 0) + 5_000)
    }

    func testNonPositiveLimitReturnsNoSessions() throws {
        try seedSessions(count: 3)

        XCTAssertEqual(try store.sessions(gapMs: Self.gapMs, limit: 0), [])
        XCTAssertEqual(try store.sessions(gapMs: Self.gapMs, limit: -1), [])
    }

    func testLimitOnAnEmptyLibraryReturnsNoSessions() throws {
        XCTAssertEqual(try store.sessions(gapMs: Self.gapMs, limit: 10), [])
    }

    func testLimitComposesWithAnExplicitTimeRange() throws {
        let starts = try seedSessions(count: 6)
        // Half-open [starts[1], starts[4]) covers sessions 1, 2 and 3.
        let from = starts[1]
        let to = starts[4]

        let ranged = try store.sessions(gapMs: Self.gapMs, fromTimestampMs: from, toTimestampMs: to)
        XCTAssertEqual(ranged.map(\.startMs), [starts[3], starts[2], starts[1]])

        let bounded = try store.sessions(
            gapMs: Self.gapMs,
            fromTimestampMs: from,
            toTimestampMs: to,
            limit: 2
        )
        XCTAssertEqual(bounded, Array(ranged.prefix(2)))
    }

    /// The range lower bound must not be mistaken for a session start when it
    /// falls inside a block, otherwise a bounded read would report a longer
    /// session than the unbounded read does.
    func testLimitRespectsRangeStartFallingInsideASession() throws {
        let starts = try seedSessions(count: 4, momentsPerSession: 5)
        let from = starts[2] + 2_000

        let ranged = try store.sessions(gapMs: Self.gapMs, fromTimestampMs: from)
        let bounded = try store.sessions(gapMs: Self.gapMs, fromTimestampMs: from, limit: 2)
        XCTAssertEqual(bounded, ranged)
        XCTAssertEqual(bounded.last?.startMs, from)
        XCTAssertEqual(bounded.last?.frameCount, 3)
    }

    /// Synchronized displays share one timestamp, so a moment must count once
    /// while the newest-session bound is being located.
    func testLimitCountsSynchronizedDisplaysAsOneMoment() throws {
        _ = try store.insertSeedFrame(timestampMs: 1_000, foreground: "main", bundleID: "dev.multi")
        _ = try store.insertSeedFrame(timestampMs: 1_000, foreground: "second", bundleID: "dev.multi")
        _ = try store.insertSeedFrame(timestampMs: 10 * Self.gapMs, foreground: "next", bundleID: "dev.next")

        let bounded = try store.sessions(gapMs: Self.gapMs, limit: 2)
        XCTAssertEqual(bounded.map(\.startMs), [10 * Self.gapMs, 1_000])
        XCTAssertEqual(bounded.last?.frameCount, 1)
    }

    /// The live-capture refresh recomputes only the newest session from its own
    /// start and reuses the rows it already holds. That tail must match what a
    /// full reload would produce.
    func testTailRecomputeFromNewestStartMatchesFullReload() throws {
        let starts = try seedSessions(count: 5)
        let before = try store.sessions(gapMs: Self.gapMs)
        let anchor = try XCTUnwrap(before.first?.startMs)
        XCTAssertEqual(anchor, starts.last)

        // A new frame lands inside the newest session.
        _ = try store.insertSeedFrame(
            timestampMs: anchor + 3_000,
            foreground: "live",
            bundleID: "dev.live"
        )

        let tail = try store.sessions(gapMs: Self.gapMs, fromTimestampMs: anchor)
        var merged = tail
        merged.append(contentsOf: before.filter { $0.startMs < anchor })
        XCTAssertEqual(merged, try store.sessions(gapMs: Self.gapMs))
        XCTAssertEqual(merged.first?.frameCount, 4)
    }

    /// A frame arriving after a long idle stretch opens a new session, and the
    /// tail recompute has to surface it rather than extend the old one.
    func testTailRecomputeSurfacesANewSession() throws {
        try seedSessions(count: 3)
        let before = try store.sessions(gapMs: Self.gapMs)
        let anchor = try XCTUnwrap(before.first?.startMs)

        let newStart = anchor + 10 * Self.gapMs
        _ = try store.insertSeedFrame(timestampMs: newStart, foreground: "fresh", bundleID: "dev.fresh")

        let tail = try store.sessions(gapMs: Self.gapMs, fromTimestampMs: anchor)
        XCTAssertEqual(tail.map(\.startMs), [newStart, anchor])
        var merged = tail
        merged.append(contentsOf: before.filter { $0.startMs < anchor })
        XCTAssertEqual(merged, try store.sessions(gapMs: Self.gapMs))
    }
}
