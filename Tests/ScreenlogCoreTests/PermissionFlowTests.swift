import UniformTypeIdentifiers
import XCTest

@testable import ScreenlogCore

final class PermissionFlowTests: XCTestCase {
    func testBothPermissionsAreRequiredForCaptureReadiness() {
        let bothMissing = PermissionsSnapshot(
            screenRecording: false,
            accessibility: false
        )
        let accessibilityMissing = PermissionsSnapshot(
            screenRecording: true,
            accessibility: false
        )
        let screenRecordingMissing = PermissionsSnapshot(
            screenRecording: false,
            accessibility: true
        )
        let ready = PermissionsSnapshot(screenRecording: true, accessibility: true)

        XCTAssertFalse(
            accessibilityMissing.isCaptureReady
        )
        XCTAssertFalse(
            screenRecordingMissing.isCaptureReady
        )
        XCTAssertTrue(ready.isCaptureReady)
        XCTAssertEqual(bothMissing.missingRequiredPermissions, [.screenRecording, .accessibility])
        XCTAssertEqual(
            accessibilityMissing.missingRequiredPermissions,
            [.accessibility]
        )
        XCTAssertEqual(bothMissing.primaryMissingRequiredPermission, .screenRecording)
        XCTAssertEqual(accessibilityMissing.primaryMissingRequiredPermission, .accessibility)
        XCTAssertEqual(screenRecordingMissing.primaryMissingRequiredPermission, .screenRecording)
        XCTAssertNil(ready.primaryMissingRequiredPermission)
        XCTAssertTrue(accessibilityMissing.isGranted(.screenRecording))
        XCTAssertFalse(accessibilityMissing.isGranted(.accessibility))
    }

    func testCoordinatorInitializationDoesNotCheckOrRequestPermission() {
        var statusCalls = 0
        var requestCalls = 0
        var openCalls = 0
        let requester = PermissionRequestClient(
            status: { _ in
                statusCalls += 1
                return false
            },
            request: { _ in
                requestCalls += 1
                return false
            }
        )
        let opener = PermissionSystemSettingsOpener { _ in
            openCalls += 1
            return false
        }

        _ = PermissionFlowCoordinator(
            snapshot: PermissionsSnapshot(screenRecording: false, accessibility: false),
            requestClient: requester,
            settingsOpener: opener
        )

        XCTAssertEqual(statusCalls, 0)
        XCTAssertEqual(requestCalls, 0)
        XCTAssertEqual(openCalls, 0)
    }

    func testOneExplicitActionMakesOneSupportedRequestWithoutStackingSystemSettings() {
        var requested: [ScreenlogPermission] = []
        var checked: [ScreenlogPermission] = []
        var opened: [URL] = []
        let coordinator = PermissionFlowCoordinator(
            snapshot: PermissionsSnapshot(screenRecording: false, accessibility: false),
            requestClient: PermissionRequestClient(
                status: {
                    checked.append($0)
                    return false
                },
                request: {
                    requested.append($0)
                    return false
                }
            ),
            settingsOpener: PermissionSystemSettingsOpener { url in
                opened.append(url)
                return opened.count == 1
            }
        )

        let outcome = coordinator.request(.screenRecording)

        XCTAssertEqual(requested, [.screenRecording])
        XCTAssertEqual(checked, [.screenRecording])
        XCTAssertTrue(opened.isEmpty)
        XCTAssertNil(outcome.settingsResult)
        XCTAssertEqual(coordinator.journey.screenRecording, .verificationFailed)
        XCTAssertEqual(coordinator.journey.action(for: .screenRecording), .openSettings)
    }

    func testRepeatedPermissionActionRequestsOnlyOnce() {
        var requestCount = 0
        var statusCount = 0
        var settingsOpenCount = 0
        let coordinator = PermissionFlowCoordinator(
            snapshot: PermissionsSnapshot(screenRecording: false, accessibility: true),
            requestClient: PermissionRequestClient(
                status: { _ in
                    statusCount += 1
                    return false
                },
                request: { _ in
                    requestCount += 1
                    return false
                }
            ),
            settingsOpener: PermissionSystemSettingsOpener { _ in
                settingsOpenCount += 1
                return true
            }
        )

        _ = coordinator.request(.screenRecording)
        _ = coordinator.request(.screenRecording)

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(statusCount, 2)
        XCTAssertEqual(settingsOpenCount, 1)
        XCTAssertEqual(coordinator.journey.action(for: .screenRecording), .openSettings)
    }

    func testExplicitAccessibilityActionNeverRequestsScreenRecording() {
        var requested: [ScreenlogPermission] = []
        var checked: [ScreenlogPermission] = []
        var opened: [URL] = []
        let coordinator = PermissionFlowCoordinator(
            snapshot: PermissionsSnapshot(screenRecording: false, accessibility: false),
            requestClient: PermissionRequestClient(
                status: {
                    checked.append($0)
                    return false
                },
                request: {
                    requested.append($0)
                    return false
                }
            ),
            settingsOpener: PermissionSystemSettingsOpener { url in
                opened.append(url)
                return true
            }
        )

        _ = coordinator.request(.accessibility)

        XCTAssertEqual(requested, [.accessibility])
        XCTAssertEqual(checked, [.accessibility])
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(coordinator.journey.accessibility, .verificationFailed)
        XCTAssertEqual(coordinator.journey.screenRecording, .needsRequest)
    }

    func testPermissionDeepLinksTargetDistinctSystemSettingsPanes() {
        let screenLinks = PermissionSystemSettingsOpener.deepLinks(for: .screenRecording)
        let accessibilityLinks = PermissionSystemSettingsOpener.deepLinks(for: .accessibility)

        XCTAssertFalse(screenLinks.isEmpty)
        XCTAssertFalse(accessibilityLinks.isEmpty)
        XCTAssertNotEqual(screenLinks, accessibilityLinks)
        XCTAssertTrue(screenLinks[0].absoluteString.contains("Privacy_ScreenCapture"))
        XCTAssertTrue(accessibilityLinks[0].absoluteString.contains("Privacy_Accessibility"))
    }

    func testSettingsRoutingTriesDeepLinksThenApplicationFallback() {
        var attempts: [URL] = []
        let application = URL(fileURLWithPath: "/test/System Settings.app")
        let opener = PermissionSystemSettingsOpener(systemSettingsURL: application) { url in
            attempts.append(url)
            return url == application
        }

        let result = opener.open(.accessibility)

        XCTAssertEqual(result.route, .systemSettingsApplication)
        XCTAssertEqual(attempts, PermissionSystemSettingsOpener.deepLinks(for: .accessibility) + [application])
        XCTAssertTrue(result.instructions.contains("Privacy & Security > Accessibility"))
    }

    func testSettingsRoutingReportsVisibleManualFallbackWhenNothingOpens() {
        let opener = PermissionSystemSettingsOpener { _ in false }

        let result = opener.open(.screenRecording)

        XCTAssertEqual(result.route, .unavailable)
        XCTAssertFalse(result.opened)
    }

    func testRefreshPreservesAwaitingStateUntilPermissionBecomesReady() {
        var journey = PermissionJourney(
            snapshot: PermissionsSnapshot(screenRecording: false, accessibility: true)
        )
        journey.markSettingsOpened(for: .screenRecording, opened: true)

        journey.refresh(
            with: PermissionsSnapshot(screenRecording: false, accessibility: true)
        )
        XCTAssertEqual(journey.screenRecording, .awaitingSystemSettings)

        journey.refresh(
            with: PermissionsSnapshot(screenRecording: true, accessibility: true)
        )
        XCTAssertTrue(journey.isCaptureReady)
    }

    func testApplicationDragProviderCarriesFileURLAndApplicationBundleTypes() throws {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionFlowTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Screenlogger.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }
        let provider = AppBundleDragProvider.make(for: appURL)

        XCTAssertTrue(provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier))
        XCTAssertTrue(
            provider.registeredTypeIdentifiers.contains(UTType.applicationBundle.identifier)
        )

        let loaded = expectation(description: "application bundle payload")
        provider.loadFileRepresentation(
            forTypeIdentifier: UTType.applicationBundle.identifier
        ) { loadedURL, error in
            XCTAssertNil(error)
            XCTAssertEqual(loadedURL?.lastPathComponent, appURL.lastPathComponent)
            if let loadedURL {
                var isDirectory: ObjCBool = false
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: loadedURL.path,
                        isDirectory: &isDirectory
                    )
                )
                XCTAssertTrue(isDirectory.boolValue)
            }
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 2)
    }
}
