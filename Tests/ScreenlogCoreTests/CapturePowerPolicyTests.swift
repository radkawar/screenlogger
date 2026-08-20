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
