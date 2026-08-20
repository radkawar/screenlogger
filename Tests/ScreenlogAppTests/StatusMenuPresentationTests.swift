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

        XCTAssertEqual(off.compactLabel, "Capture Off")
        XCTAssertEqual(off.actionLabel, "Start Capture")
        XCTAssertEqual(StatusMenuCapturePresentation.statusTitle(off), "Capture Off")
        XCTAssertFalse(StatusMenuCapturePresentation.statusTitle(off).contains("Start Capture"))

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

        XCTAssertEqual(StatusMenuCapturePresentation.statusTitle(setup), "Setup Required")
        XCTAssertFalse(StatusMenuCapturePresentation.statusTitle(setup).contains(" - "))
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
        XCTAssertEqual(enabled.title, "Audio Transcription")
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertTrue(enabled.isChecked)
        XCTAssertEqual(enabled.action, .toggle)

        let disabled = AudioTranscriptionMenuPresentation.resolve(
            isSupported: true,
            isEnabled: false,
            hasSelectedSources: true,
            status: .off
        )
        XCTAssertEqual(disabled.title, "Audio Transcription")
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

        XCTAssertEqual(presentation.title, "Choose Audio Transcription Sources...")
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

        XCTAssertEqual(presentation.title, "Audio Transcription Requires macOS 26")
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

        XCTAssertEqual(presentation.title, "Audio Transcription - Needs Attention")
        XCTAssertEqual(presentation.action, .toggle)
        XCTAssertTrue(presentation.isChecked)
    }
}
