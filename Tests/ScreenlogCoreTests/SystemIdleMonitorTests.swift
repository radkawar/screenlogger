import XCTest

@testable import ScreenlogCore

final class SystemIdleMonitorTests: XCTestCase {
    func testSecondsSinceLastInputIsFiniteNonNegative() {
        let s = SystemIdleMonitor.secondsSinceLastInput()
        XCTAssertTrue(s.isFinite)
        XCTAssertGreaterThanOrEqual(s, 0)
    }

    func testIsIdleRespectsThreshold() {
        // A huge threshold should never report idle during a test run.
        XCTAssertFalse(SystemIdleMonitor.isIdle(thresholdSeconds: 86_400 * 365))
        // Zero / negative threshold is treated as 'never idle'.
        XCTAssertFalse(SystemIdleMonitor.isIdle(thresholdSeconds: 0))
        XCTAssertFalse(SystemIdleMonitor.isIdle(thresholdSeconds: -1))
    }
}
