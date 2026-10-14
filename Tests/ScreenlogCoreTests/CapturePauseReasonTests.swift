import Foundation
@testable import ScreenlogCore
import XCTest

final class CapturePauseReasonTests: XCTestCase {
    func testOnlyPermissionAndLowDiskRequireUserAction() {
        XCTAssertTrue(CapturePauseReason.permissionRequired.needsUserAction)
        XCTAssertTrue(CapturePauseReason.lowDiskSpace.needsUserAction)
        XCTAssertTrue(CapturePauseReason.browserAddressUnavailable.needsUserAction)
        XCTAssertFalse(CapturePauseReason.excludedContent.needsUserAction)
        XCTAssertFalse(CapturePauseReason.privateBrowsing.needsUserAction)
        XCTAssertFalse(CapturePauseReason.inactivity.needsUserAction)
    }

    func testPauseReasonsRoundTripForDiagnosticsAndFutureIPC() throws {
        let encoded = try JSONEncoder().encode(CapturePauseReason.allCases)
        let decoded = try JSONDecoder().decode([CapturePauseReason].self, from: encoded)

        XCTAssertEqual(decoded, CapturePauseReason.allCases)
    }

    func testDaemonStatusCarriesPauseReasonWithoutBreakingOlderPayloads() throws {
        let status = DaemonStatus(
            version: "test",
            recording: true,
            pauseReason: .privateBrowsing,
            connections: 1
        )
        let encoded = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(DaemonStatus.self, from: encoded), status)

        let olderPayload = Data(#"{"version":"test","recording":true,"connections":1}"#.utf8)
        let olderStatus = try JSONDecoder().decode(DaemonStatus.self, from: olderPayload)
        XCTAssertNil(olderStatus.pauseReason)
    }

    @MainActor
    func testStoppingEngineClearsPauseStateAndLegacyFlags() {
        let engine = RecordingEngine()

        XCTAssertTrue(engine.stop())
        XCTAssertNil(engine.pauseReason)
        XCTAssertFalse(engine.pausedForDisk)
        XCTAssertFalse(engine.pausedForInactivity)
    }
}

final class BrowserCapturePrivacyPolicyTests: XCTestCase {
    func testStrictProtectionPreferenceIsOptInAndRoundTrips() {
        let suite = "BrowserCapturePrivacyPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(BrowserAddressProtectionPreference.value(from: defaults))
        BrowserAddressProtectionPreference.save(true, to: defaults)
        XCTAssertTrue(BrowserAddressProtectionPreference.value(from: defaults))
        BrowserAddressProtectionPreference.save(false, to: defaults)
        XCTAssertFalse(BrowserAddressProtectionPreference.value(from: defaults))
    }

    func testStrictProtectionPausesSupportedBrowserWithoutDomain() {
        XCTAssertTrue(
            BrowserCapturePrivacyPolicy.shouldPause(
                capturedBundleID: "com.apple.Safari",
                attribution: nil,
                pauseWhenAddressUnavailable: true
            ))
        XCTAssertTrue(
            BrowserCapturePrivacyPolicy.shouldPause(
                capturedBundleID: "com.google.Chrome",
                attribution: BrowserURLAttribution(
                    url: nil,
                    domain: nil,
                    title: "New Tab",
                    observedBundleID: "com.google.Chrome"
                ),
                pauseWhenAddressUnavailable: true
            ))
    }

    func testStrictProtectionAllowsAttributedBrowserAndNonBrowserApps() {
        XCTAssertFalse(
            BrowserCapturePrivacyPolicy.shouldPause(
                capturedBundleID: "com.apple.Safari",
                attribution: BrowserURLAttribution(
                    url: "https://example.com/path",
                    domain: "example.com",
                    title: "Example",
                    observedBundleID: "com.apple.Safari"
                ),
                pauseWhenAddressUnavailable: true
            ))
        XCTAssertFalse(
            BrowserCapturePrivacyPolicy.shouldPause(
                capturedBundleID: "com.apple.TextEdit",
                attribution: nil,
                pauseWhenAddressUnavailable: true
            ))
    }

    func testStrictProtectionRejectsRacedBrowserAndInternalURL() {
        XCTAssertTrue(
            BrowserCapturePrivacyPolicy.shouldPause(
                capturedBundleID: "com.apple.Safari",
                attribution: BrowserURLAttribution(
                    url: "https://example.com",
                    domain: "example.com",
                    title: "Example",
                    observedBundleID: "com.google.Chrome"
                ),
                pauseWhenAddressUnavailable: true
            ))
        XCTAssertTrue(
            BrowserCapturePrivacyPolicy.shouldPause(
                capturedBundleID: "com.google.Chrome",
                attribution: BrowserURLAttribution(
                    url: "chrome://settings",
                    domain: nil,
                    title: "Settings",
                    observedBundleID: "com.google.Chrome"
                ),
                pauseWhenAddressUnavailable: true
            ))
    }

    func testCompatibilityModeAllowsUnknownBrowserAddress() {
        XCTAssertFalse(
            BrowserCapturePrivacyPolicy.shouldPause(
                capturedBundleID: "com.apple.Safari",
                attribution: nil,
                pauseWhenAddressUnavailable: false
            ))
    }
}
