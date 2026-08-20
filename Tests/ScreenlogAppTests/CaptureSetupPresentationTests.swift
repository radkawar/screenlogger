import XCTest

final class CaptureSetupPresentationTests: XCTestCase {
    func testFirstRunMissingPermissionAndReadyGuidanceBothNameLibrary() {
        let origin = CaptureSetupOrigin.directFirstRun

        XCTAssertEqual(origin.returnSurfaceName, "Library")
        XCTAssertFalse(origin.returnsToInitiatingSurface)

        let missing = CaptureSetupGuidance.missingPermissionFooter(for: origin)
        let ready = CaptureSetupGuidance.readyFooter(for: origin)
        let destination = CaptureSetupGuidance.completionDestination(for: origin)

        XCTAssertTrue(missing.contains("Library"))
        XCTAssertTrue(ready.contains("Library"))
        XCTAssertEqual(destination, "Starting capture opens Library.")
        XCTAssertFalse(missing.contains("Timeline"))
        XCTAssertFalse(ready.contains("Timeline"))
    }

    func testInitiatingSurfacesKeepTheirOwnReturnNames() {
        XCTAssertEqual(
            CaptureSetupGuidance.completionDestination(for: .library),
            "Starting capture returns you to Library."
        )
        XCTAssertEqual(
            CaptureSetupGuidance.completionDestination(for: .timeline),
            "Starting capture returns you to Timeline."
        )
        XCTAssertEqual(
            CaptureSetupGuidance.completionDestination(for: .settings),
            "Starting capture returns you to Settings."
        )
        XCTAssertEqual(
            CaptureSetupGuidance.completionDestination(for: .settingsGuide),
            "Starting capture returns you to Getting Started."
        )
        XCTAssertEqual(
            CaptureSetupGuidance.completionDestination(for: .direct),
            "Starting capture opens Timeline."
        )
    }
}
