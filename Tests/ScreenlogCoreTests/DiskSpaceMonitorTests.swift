import XCTest

@testable import ScreenlogCore

final class DiskSpaceMonitorTests: XCTestCase {
    func testRefreshCachesCapacityWithinTTL() {
        let monitor = DiskSpaceMonitor()
        let root = FileManager.default.temporaryDirectory
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var calls = 0
        monitor.now = { now }
        monitor.cacheTTL = 45
        monitor.minimumFreeBytes = 1_000
        monitor.capacityProvider = { _ in
            calls += 1
            return 5_000
        }

        XCTAssertTrue(monitor.refresh(at: root))
        XCTAssertTrue(monitor.refresh(at: root))
        now = now.addingTimeInterval(10)
        XCTAssertTrue(monitor.refresh(at: root))
        XCTAssertEqual(calls, 1)

        now = now.addingTimeInterval(40)
        XCTAssertTrue(monitor.refresh(at: root))
        XCTAssertEqual(calls, 2)
    }

    func testForceRefreshBypassesCache() {
        let monitor = DiskSpaceMonitor()
        let root = FileManager.default.temporaryDirectory
        var calls = 0
        monitor.now = { Date(timeIntervalSince1970: 1_700_000_000) }
        monitor.cacheTTL = 45
        monitor.minimumFreeBytes = 1_000
        monitor.capacityProvider = { _ in
            calls += 1
            return 5_000
        }

        XCTAssertTrue(monitor.refresh(at: root))
        XCTAssertTrue(monitor.refresh(at: root, force: true))
        XCTAssertEqual(calls, 2)
    }

    func testLowCapacityPausesUntilALaterRefreshSeesRecovery() {
        let monitor = DiskSpaceMonitor()
        let root = FileManager.default.temporaryDirectory
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var free: Int64 = 100
        monitor.now = { now }
        monitor.cacheTTL = 45
        monitor.minimumFreeBytes = 1_000
        monitor.capacityProvider = { _ in free }

        XCTAssertTrue(monitor.shouldPauseRecording(dataRoot: root))
        XCTAssertTrue(monitor.isPausedForDiskSpace)

        free = 5_000
        XCTAssertTrue(monitor.shouldPauseRecording(dataRoot: root))
        now = now.addingTimeInterval(46)
        XCTAssertFalse(monitor.shouldPauseRecording(dataRoot: root))
        XCTAssertFalse(monitor.isPausedForDiskSpace)
    }
}
