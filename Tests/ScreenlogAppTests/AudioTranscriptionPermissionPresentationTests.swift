import ScreenlogCore
import XCTest

final class AudioTranscriptionPermissionPresentationTests: XCTestCase {
    func testAuthorizationChangeReconcilesOnlyAnEnabledMicrophoneSource() {
        XCTAssertTrue(
            AudioTranscriptionPermissionPresentation.shouldReconcile(
                previous: .denied,
                current: .authorized,
                audioEnabled: true,
                microphoneEnabled: true
            )
        )
        XCTAssertFalse(
            AudioTranscriptionPermissionPresentation.shouldReconcile(
                previous: .authorized,
                current: .authorized,
                audioEnabled: true,
                microphoneEnabled: true
            )
        )
        XCTAssertFalse(
            AudioTranscriptionPermissionPresentation.shouldReconcile(
                previous: .denied,
                current: .authorized,
                audioEnabled: false,
                microphoneEnabled: true
            )
        )
        XCTAssertFalse(
            AudioTranscriptionPermissionPresentation.shouldReconcile(
                previous: .denied,
                current: .authorized,
                audioEnabled: true,
                microphoneEnabled: false
            )
        )
    }

    func testPermissionActionReflectsCurrentAuthorization() {
        XCTAssertEqual(action(for: .notDetermined), "Allow Microphone")
        XCTAssertEqual(action(for: .denied), "Open Settings")
        XCTAssertEqual(action(for: .restricted), "Open Settings")
        XCTAssertEqual(action(for: .authorized), "Try Again")
    }

    func testOnlyRecoverableAttentionStatesOfferAnAction() {
        XCTAssertEqual(
            AudioTranscriptionPermissionPresentation.statusActionTitle(
                phase: .failed,
                microphoneAuthorization: .authorized
            ),
            "Try Again"
        )
        XCTAssertNil(
            AudioTranscriptionPermissionPresentation.statusActionTitle(
                phase: .active,
                microphoneAuthorization: .authorized
            )
        )
    }

    private func action(for authorization: MicrophoneAuthorization) -> String? {
        AudioTranscriptionPermissionPresentation.statusActionTitle(
            phase: .permissionRequired,
            microphoneAuthorization: authorization
        )
    }
}
