import XCTest

@testable import ScreenlogCore

final class CapturePowerPolicyTests: XCTestCase {
    func testBatteryStretchesShortIntervalsAndLeavesLongOnesAlone() {
        XCTAssertEqual(
            CapturePowerPolicy.captureInterval(configured: 2, powerSource: .battery),
            5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            CapturePowerPolicy.captureInterval(configured: 8, powerSource: .battery),
            8,
            accuracy: 0.001
        )
        XCTAssertEqual(
            CapturePowerPolicy.captureInterval(configured: 2, powerSource: .externalPower),
            2,
            accuracy: 0.001
        )
    }

    func testBatteryCapsCaptureDimensionIncludingUltra() {
        XCTAssertEqual(
            CapturePowerPolicy.captureMaxDimension(configured: 0, powerSource: .battery),
            1_920
        )
        XCTAssertEqual(
            CapturePowerPolicy.captureMaxDimension(configured: 2_880, powerSource: .battery),
            1_920
        )
        XCTAssertEqual(
            CapturePowerPolicy.captureMaxDimension(configured: 1_280, powerSource: .battery),
            1_280
        )
        XCTAssertEqual(
            CapturePowerPolicy.captureMaxDimension(configured: 0, powerSource: .externalPower),
            0
        )
    }

    func testBatteryUsesFastRecognitionAndSkipsAX() {
        XCTAssertTrue(CapturePowerPolicy.prefersFastRecognition(powerSource: .battery))
        XCTAssertTrue(CapturePowerPolicy.skipAccessibilityTree(powerSource: .battery))
        XCTAssertFalse(CapturePowerPolicy.prefersFastRecognition(powerSource: .externalPower))
        XCTAssertFalse(CapturePowerPolicy.skipAccessibilityTree(powerSource: .externalPower))
    }

    func testEnergyProfileOnBatteryMatchesPolicy() {
        let profile = CaptureEnergyProfile.make(
            configuredMaxDimension: 0,
            stillQuality: 0.99,
            captureAXTree: true,
            powerSource: .battery
        )
        XCTAssertEqual(profile.maxDimension, 1_920)
        XCTAssertTrue(profile.fastRecognition)
        XCTAssertFalse(profile.collectAccessibilityTree)
        XCTAssertEqual(profile.unchangedHeartbeatSeconds, 60, accuracy: 0.001)
    }

    func testLowPowerModeStretchesTheIntervalOnAnyPowerSource() {
        let plugged = CapturePowerConditions(
            powerSource: .externalPower,
            lowPowerModeEnabled: true
        )
        XCTAssertEqual(
            CapturePowerPolicy.captureInterval(configured: 2, conditions: plugged),
            10,
            accuracy: 0.001
        )
        // A longer configured interval is always respected.
        XCTAssertEqual(
            CapturePowerPolicy.captureInterval(configured: 20, conditions: plugged),
            20,
            accuracy: 0.001
        )
    }

    func testThermalPressureStretchesTheIntervalWithoutStoppingCapture() {
        let fair = CapturePowerConditions(powerSource: .externalPower, thermalState: .fair)
        let serious = CapturePowerConditions(powerSource: .externalPower, thermalState: .serious)
        let critical = CapturePowerConditions(powerSource: .externalPower, thermalState: .critical)
        // Fair is normal under sustained work and must not degrade capture.
        XCTAssertEqual(
            CapturePowerPolicy.captureInterval(configured: 2, conditions: fair),
            2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            CapturePowerPolicy.captureInterval(configured: 2, conditions: serious),
            15,
            accuracy: 0.001
        )
        let criticalInterval = CapturePowerPolicy.captureInterval(
            configured: 2,
            conditions: critical
        )
        XCTAssertEqual(criticalInterval, 30, accuracy: 0.001)
        // Degrade, never stop.
        XCTAssertLessThan(criticalInterval, .infinity)
    }

    func testWorstConstraintWinsWhenSignalsStack() {
        let stacked = CapturePowerConditions(
            powerSource: .battery,
            thermalState: .critical,
            lowPowerModeEnabled: true
        )
        XCTAssertEqual(
            CapturePowerPolicy.captureInterval(configured: 2, conditions: stacked),
            30,
            accuracy: 0.001
        )
        XCTAssertEqual(
            CapturePowerPolicy.captureMaxDimension(configured: 0, conditions: stacked),
            1_280
        )
    }

    func testConstrainedConditionsCapDimensionAndCheapenRecognition() {
        let lowPower = CapturePowerConditions(
            powerSource: .externalPower,
            lowPowerModeEnabled: true
        )
        let hot = CapturePowerConditions(powerSource: .externalPower, thermalState: .serious)
        let nominal = CapturePowerConditions(powerSource: .externalPower)

        XCTAssertEqual(
            CapturePowerPolicy.captureMaxDimension(configured: 2_880, conditions: lowPower),
            1_920
        )
        XCTAssertEqual(
            CapturePowerPolicy.captureMaxDimension(configured: 1_280, conditions: hot),
            1_280
        )
        XCTAssertEqual(
            CapturePowerPolicy.captureMaxDimension(configured: 2_880, conditions: nominal),
            2_880
        )
        XCTAssertTrue(CapturePowerPolicy.prefersFastRecognition(conditions: lowPower))
        XCTAssertTrue(CapturePowerPolicy.skipAccessibilityTree(conditions: hot))
        XCTAssertFalse(CapturePowerPolicy.prefersFastRecognition(conditions: nominal))
        XCTAssertFalse(CapturePowerPolicy.skipAccessibilityTree(conditions: nominal))
    }

    func testEnergyProfileDegradesForHeatOnExternalPower() {
        let profile = CaptureEnergyProfile.make(
            configuredMaxDimension: 0,
            stillQuality: 0.99,
            captureAXTree: true,
            conditions: CapturePowerConditions(
                powerSource: .externalPower,
                thermalState: .critical
            )
        )
        XCTAssertEqual(profile.maxDimension, 1_280)
        XCTAssertTrue(profile.fastRecognition)
        XCTAssertFalse(profile.collectAccessibilityTree)
    }

    func testEnergySaverReasonReportsTheMostSevereSignal() {
        XCTAssertNil(
            CaptureEnergySaverReason.reason(
                for: CapturePowerConditions(powerSource: .externalPower)
            )
        )
        XCTAssertNil(
            CaptureEnergySaverReason.reason(
                for: CapturePowerConditions(powerSource: .externalPower, thermalState: .fair)
            )
        )
        XCTAssertEqual(
            CaptureEnergySaverReason.reason(
                for: CapturePowerConditions(powerSource: .battery)
            ),
            .battery
        )
        XCTAssertEqual(
            CaptureEnergySaverReason.reason(
                for: CapturePowerConditions(
                    powerSource: .battery,
                    lowPowerModeEnabled: true
                )
            ),
            .lowPowerMode
        )
        XCTAssertEqual(
            CaptureEnergySaverReason.reason(
                for: CapturePowerConditions(
                    powerSource: .battery,
                    thermalState: .serious,
                    lowPowerModeEnabled: true
                )
            ),
            .thermalPressure
        )
    }

    func testEveryEnergySaverReasonHasAnIcon() {
        for reason in CaptureEnergySaverReason.allCases {
            XCTAssertFalse(reason.systemImageName.isEmpty)
        }
    }

    func testLivePowerConditionsReadProcessInfo() {
        let conditions = CapturePowerConditions.current(powerSource: .externalPower)
        XCTAssertEqual(conditions.powerSource, .externalPower)
        XCTAssertEqual(conditions.thermalState, ProcessInfo.processInfo.thermalState)
        XCTAssertEqual(
            conditions.lowPowerModeEnabled,
            ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    func testUnchangedStoreSkipsUntilTheHeartbeat() {
        XCTAssertTrue(
            CapturePowerPolicy.shouldSkipUnchangedStore(
                reused: true,
                lastStoredAtMs: 1_000,
                nowMs: 30_000,
                heartbeatSeconds: 60
            )
        )
        XCTAssertFalse(
            CapturePowerPolicy.shouldSkipUnchangedStore(
                reused: true,
                lastStoredAtMs: 1_000,
                nowMs: 61_000,
                heartbeatSeconds: 60
            )
        )
        XCTAssertFalse(
            CapturePowerPolicy.shouldSkipUnchangedStore(
                reused: false,
                lastStoredAtMs: 1_000,
                nowMs: 2_000,
                heartbeatSeconds: 60
            )
        )
        XCTAssertFalse(
            CapturePowerPolicy.shouldSkipUnchangedStore(
                reused: true,
                lastStoredAtMs: nil,
                nowMs: 2_000,
                heartbeatSeconds: 60
            )
        )
    }

    func testAllDisplayIntervalStoresEveryScreenOrNone() {
        XCTAssertFalse(
            CapturePowerPolicy.shouldStoreInterval(
                displays: [
                    (reused: true, lastStoredAtMs: 1_000),
                    (reused: true, lastStoredAtMs: 1_000),
                ],
                nowMs: 30_000,
                heartbeatSeconds: 60
            )
        )
        XCTAssertTrue(
            CapturePowerPolicy.shouldStoreInterval(
                displays: [
                    (reused: true, lastStoredAtMs: 1_000),
                    (reused: false, lastStoredAtMs: 1_000),
                ],
                nowMs: 30_000,
                heartbeatSeconds: 60
            )
        )
        XCTAssertTrue(
            CapturePowerPolicy.shouldStoreInterval(
                displays: [
                    (reused: true, lastStoredAtMs: 1_000),
                    (reused: true, lastStoredAtMs: 1_000),
                ],
                nowMs: 61_000,
                heartbeatSeconds: 60
            )
        )
        XCTAssertFalse(
            CapturePowerPolicy.shouldStoreInterval(
                displays: [],
                nowMs: 61_000,
                heartbeatSeconds: 60
            )
        )
    }
}
