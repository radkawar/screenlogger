@testable import ScreenlogCore
import XCTest

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

    func testHeatAndLowPowerModeDeferEvenWhenBatteryDeferralIsOff() {
        XCTAssertTrue(
            MaintenancePowerPolicy.shouldDeferAutomaticWork(
                conditions: CapturePowerConditions(
                    powerSource: .externalPower,
                    thermalState: .serious
                ),
                deferOnBattery: false
            )
        )
        XCTAssertTrue(
            MaintenancePowerPolicy.shouldDeferAutomaticWork(
                conditions: CapturePowerConditions(
                    powerSource: .externalPower,
                    lowPowerModeEnabled: true
                ),
                deferOnBattery: false
            )
        )
    }

    func testPluggedInAndCoolRunsAutomaticWork() {
        XCTAssertFalse(
            MaintenancePowerPolicy.shouldDeferAutomaticWork(
                conditions: CapturePowerConditions(
                    powerSource: .externalPower,
                    thermalState: .fair
                ),
                deferOnBattery: true
            )
        )
    }
}
