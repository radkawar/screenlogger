import ScreenlogCore
import XCTest

final class StatusMenuPresentationTests: XCTestCase {
    func testCaptureStatusTitleStaysSeparateFromStartAndStopActions() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let off = CaptureStatusResolver.resolve(
            CaptureStatusInput(
                library: .ready,
                permissions: PermissionsSnapshot(
                    screenRecording: true,
                    accessibility: true
                ),
                isRecording: false,
                timedPauseUntil: nil,
                pauseReason: nil,
                pausedForDisk: false,
                captureIssue: nil
            ),
            at: now
        ) { _ in "10:00 AM" }

        XCTAssertEqual(off.phase, .off)
        XCTAssertEqual(off.primaryAction, .startCapture)
        XCTAssertEqual(StatusMenuCapturePresentation.statusTitle(off), off.compactLabel)
        XCTAssertNotEqual(StatusMenuCapturePresentation.statusTitle(off), off.actionLabel)

        let setup = CaptureStatusResolver.resolve(
            CaptureStatusInput(
                library: .ready,
                permissions: PermissionsSnapshot(
                    screenRecording: false,
                    accessibility: true
                ),
                isRecording: false,
                timedPauseUntil: nil,
                pauseReason: nil,
                pausedForDisk: false,
                captureIssue: nil
            ),
            at: now
        ) { _ in "10:00 AM" }

        XCTAssertEqual(StatusMenuCapturePresentation.statusTitle(setup), setup.compactLabel)
    }

    func testSupportedAudioControlIsAnIndependentCheckedToggle() {
        let active = AudioTranscriptionStatus(
            phase: .active,
            activeSources: [.computer],
            detail: "Transcribing Computer Audio."
        )

        let enabled = AudioTranscriptionMenuPresentation.resolve(
            isSupported: true,
            isEnabled: true,
            hasSelectedSources: true,
            status: active
        )
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertTrue(enabled.isChecked)
        XCTAssertEqual(enabled.action, .toggle)

        let disabled = AudioTranscriptionMenuPresentation.resolve(
            isSupported: true,
            isEnabled: false,
            hasSelectedSources: true,
            status: .off
        )
        XCTAssertTrue(disabled.isEnabled)
        XCTAssertFalse(disabled.isChecked)
        XCTAssertEqual(disabled.action, .toggle)
    }

    func testAudioControlRoutesMissingSourcesToSettings() {
        let presentation = AudioTranscriptionMenuPresentation.resolve(
            isSupported: true,
            isEnabled: true,
            hasSelectedSources: false,
            status: .off
        )

        XCTAssertEqual(presentation.action, .openSettings)
        XCTAssertTrue(presentation.isEnabled)
        XCTAssertFalse(presentation.isChecked)
    }

    func testUnsupportedAudioControlIsVisibleButUnavailable() {
        let presentation = AudioTranscriptionMenuPresentation.resolve(
            isSupported: false,
            isEnabled: false,
            hasSelectedSources: true,
            status: .off
        )

        XCTAssertEqual(presentation.action, .none)
        XCTAssertFalse(presentation.isEnabled)
        XCTAssertFalse(presentation.isChecked)
    }

    func testAttentionStateRemainsVisibleWithoutChangingToggleSemantics() {
        let presentation = AudioTranscriptionMenuPresentation.resolve(
            isSupported: true,
            isEnabled: true,
            hasSelectedSources: true,
            status: AudioTranscriptionStatus(
                phase: .failed,
                detail: "Audio transcription needs attention."
            )
        )

        let off = AudioTranscriptionMenuPresentation.resolve(
            isSupported: true,
            isEnabled: false,
            hasSelectedSources: true,
            status: .off
        )
        XCTAssertNotEqual(presentation.title, off.title)
        XCTAssertEqual(presentation.action, .toggle)
        XCTAssertTrue(presentation.isChecked)
    }
}
