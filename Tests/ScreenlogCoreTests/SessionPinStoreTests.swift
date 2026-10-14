import XCTest

@testable import ScreenlogCore

final class SessionPinStoreTests: XCTestCase {
    var defaults: UserDefaults!
    var suiteName: String!
    var pins: SessionPinStore!
    var recent: RecentSearchStore!

    override func setUpWithError() throws {
        suiteName = "screenlog.pin.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        pins = SessionPinStore(defaults: defaults)
        recent = RecentSearchStore(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        pins = nil
        recent = nil
        defaults = nil
    }

    func testPinRoundTripAndSort() {
        let a = SessionRow(startMs: 1000, endMs: 2000, frameCount: 5)
        let b = SessionRow(startMs: 3000, endMs: 4000, frameCount: 2)
        XCTAssertFalse(pins.isPinned(a))
        pins.setPinned(a, pinned: true)
        XCTAssertTrue(pins.isPinned(a))
        XCTAssertFalse(pins.isPinned(b))

        let sorted = pins.sortedSessions([a, b])
        // a pinned to first even though older
        XCTAssertEqual(sorted.first?.startMs, 1000)

        _ = pins.toggle(a)
        XCTAssertFalse(pins.isPinned(a))
        let sorted2 = pins.sortedSessions([a, b])
        XCTAssertEqual(sorted2.first?.startMs, 3000)  // newer first when unpinned
    }

    func testPinSurvivesGrowingLiveSessionAndMigratesStoredRange() {
        let initial = SessionRow(startMs: 1_000, endMs: 2_000, frameCount: 5)
        let grown = SessionRow(startMs: 1_000, endMs: 8_000, frameCount: 12)

        XCTAssertEqual(initial.id, grown.id)
        XCTAssertNotEqual(initial.pinKey, grown.pinKey)
        pins.setPinned(initial, pinned: true)
        XCTAssertTrue(pins.isPinned(grown))
        XCTAssertEqual(
            pins.sortedSessions([
                SessionRow(startMs: 9_000, endMs: 10_000, frameCount: 1),
                grown,
            ]).first?.startMs, grown.startMs)
        XCTAssertEqual(
            SessionPinning.sections([grown], pinnedKeys: pins.pinnedIDs()).pinned,
            [grown]
        )

        pins.setPinned(grown, pinned: true)
        XCTAssertEqual(pins.pinnedIDs(), ["1000-8000"])
        pins.setPinned(grown, pinned: false)
        XCTAssertFalse(pins.isPinned(grown))
    }

    func testRecentSearchRecordDedupeAndCap() {
        for i in 0..<12 {
            recent.record("query\(i)")
        }
        let all = recent.all()
        XCTAssertEqual(all.count, RecentSearchStore.maxCount)
        XCTAssertEqual(all.first, "query11")
        recent.record("query11")  // move to front, no dup
        XCTAssertEqual(recent.all().filter { $0 == "query11" }.count, 1)
        recent.clear()
        XCTAssertTrue(recent.all().isEmpty)
    }

    func testPinIDStable() {
        XCTAssertEqual(SessionPinStore.pinID(startMs: 1, endMs: 2), "1-2")
        let s = SessionRow(startMs: 9, endMs: 10, frameCount: 1)
        XCTAssertEqual(SessionPinStore.pinID(for: s), "9-10")
        XCTAssertEqual(SessionPinning.pinKey(for: s), "9-10")
        XCTAssertEqual(SessionPinning.parsePinKey("100-200")?.startMs, 100)
        XCTAssertEqual(SessionPinning.parsePinKey("100-200")?.endMs, 200)
        XCTAssertNil(SessionPinning.parsePinKey("bad"))
    }

    func testDayGroupingAndSummaryLabel() {
        // Fixed "now" via absolute timestamps that are Today-relative is fragile;
        // exercise group structure and summary pure helpers.
        let older = SessionRow(
            startMs: 1_000,
            endMs: 61_000,
            frameCount: 12,
            primaryBundleID: "com.apple.Safari",
            primaryDisplayName: "Safari"
        )
        let newer = SessionRow(startMs: 120_000, endMs: 180_000, frameCount: 3)
        pins.setPinned(older, pinned: true)
        let sorted = pins.sortedSessions([newer, older])
        XCTAssertEqual(sorted.map(\.startMs), [1_000, 120_000])

        let sections = SessionPinning.sections(sorted, pinnedKeys: pins.pinnedIDs())
        XCTAssertEqual(sections.pinned.count, 1)
        XCTAssertEqual(sections.pinned.first?.startMs, 1_000)
        XCTAssertEqual(sections.dayGroups.flatMap(\.sessions).map(\.startMs), [120_000])

        XCTAssertTrue(SessionPinning.summaryLabel(for: older).contains("12"))
    }
}
