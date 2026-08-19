import XCTest

@testable import ScreenlogCore

final class MaintenancePowerPolicyTests: XCTestCase {
    func testAutomaticWorkWaitsOnBatteryByDefault() {
        XCTAssertTrue(
            MaintenancePowerPolicy.shouldDeferAutomaticWork(
                powerSource: .battery,
                deferOnBattery: true
            )
        )
        XCTAssertFalse(
            MaintenancePowerPolicy.shouldDeferAutomaticWork(
                powerSource: .externalPower,
                deferOnBattery: true
            )
        )
    }

    func testExplicitPolicyOverrideRunsOnBattery() {
        XCTAssertFalse(
            MaintenancePowerPolicy.shouldDeferAutomaticWork(
                powerSource: .battery,
                deferOnBattery: false
            )
        )
    }
}
