import Foundation
import ScreenlogCore
import XCTest

final class CaptureStatusPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCanonicalSingleStatePresentations() {
        struct TestCase {
            let name: String
            let input: CaptureStatusInput
            let phase: CaptureStatusPhase
            let scope: CaptureStatusScope
            let label: String
            let tone: CaptureStatusTone
            let action: CaptureStatusPrimaryAction?
            let destination: CaptureStatusDestination
            let symbol: String
        }

        let resumeAt = now.addingTimeInterval(3_600)
        let cases = [
            TestCase(
                name: "opening Library",
                input: input(library: .opening(.unavailable)),
                phase: .openingLibrary,
                scope: .library,
                label: "Opening Library...",
                tone: .working,
                action: nil,
                destination: .libraryRecovery,
                symbol: "arrow.clockwise"
            ),
            TestCase(
                name: "Library unavailable",
                input: input(library: .unavailable(.integrityCheckFailed)),
                phase: .libraryUnavailable(.integrityCheckFailed),
                scope: .library,
                label: "Library Unavailable",
                tone: .warning,
                action: .retryLibrary,
                destination: .libraryRecovery,
                symbol: "externaldrive.badge.exclamationmark"
            ),
            TestCase(
                name: "restoring Library",
                input: input(library: .restoring),
                phase: .restoringLibrary,
                scope: .library,
                label: "Restoring Library...",
                tone: .working,
                action: nil,
                destination: .libraryRecovery,
                symbol: "arrow.triangle.2.circlepath"
            ),
            TestCase(
                name: "setup required",
                input: input(screenRecordingAllowed: false),
                phase: .setupRequired(resumeAt: nil),
                scope: .capture,
                label: "Setup Required",
                tone: .warning,
                action: .setupCapture(.screenRecording),
                destination: .setup,
                symbol: "exclamationmark.shield"
            ),
            TestCase(
                name: "capture failed",
                input: input(captureIssue: .startFailed),
                phase: .captureFailed(.startFailed),
                scope: .capture,
                label: "Capture Couldn't Start",
                tone: .warning,
                action: .retryCapture(.startFailed),
                destination: .capture,
                symbol: "exclamationmark.circle"
            ),
            TestCase(
                name: "timed pause",
                input: input(timedPauseUntil: resumeAt),
                phase: .timedPause(until: resumeAt),
                scope: .capture,
                label: "Capture Paused",
                tone: .neutral,
                action: .resumeCapture,
                destination: .capture,
                symbol: "pause.circle.fill"
            ),
            TestCase(
                name: "low disk",
                input: input(isRecording: true, pauseReason: .lowDiskSpace),
                phase: .lowDiskSpace,
                scope: .capture,
                label: "Low Disk Space",
                tone: .warning,
                action: .manageStorage,
                destination: .storage,
                symbol: "externaldrive.badge.exclamationmark"
            ),
            TestCase(
                name: "website address unavailable",
                input: input(isRecording: true, pauseReason: .browserAddressUnavailable),
                phase: .websiteAddressUnavailable,
                scope: .capture,
                label: "Website Address Unavailable",
                tone: .warning,
                action: .reviewWebsiteExclusions,
                destination: .websiteExclusions,
                symbol: "globe.badge.chevron.backward"
            ),
            TestCase(
                name: "automatic privacy pause",
                input: input(isRecording: true, pauseReason: .privateBrowsing),
                phase: .automaticPause(.privateBrowsing),
                scope: .capture,
                label: "Private Browsing Protected",
                tone: .neutral,
                action: nil,
                destination: .capture,
                symbol: "hand.raised"
            ),
            TestCase(
                name: "capture on",
                input: input(isRecording: true),
                phase: .on,
                scope: .capture,
                label: "Capture On",
                tone: .success,
                action: nil,
                destination: .capture,
                symbol: "record.circle.fill"
            ),
            TestCase(
                name: "capture on with reduced energy use",
                input: input(isRecording: true, energySaverReason: .battery),
                phase: .energySaving(.battery),
                scope: .capture,
                label: "Battery Saver",
                tone: .neutral,
                action: nil,
                destination: .capture,
                symbol: "battery.50percent"
            ),
            TestCase(
                name: "capture off",
                input: input(),
                phase: .off,
                scope: .capture,
                label: "Capture Off",
                tone: .neutral,
                action: .startCapture,
                destination: .capture,
                symbol: "record.circle"
            ),
        ]

        for testCase in cases {
            let result = resolve(testCase.input)
            XCTAssertEqual(result.phase, testCase.phase, testCase.name)
            XCTAssertEqual(result.scope, testCase.scope, testCase.name)
            XCTAssertEqual(result.compactLabel, testCase.label, testCase.name)
            XCTAssertEqual(result.tone, testCase.tone, testCase.name)
            XCTAssertEqual(result.primaryAction, testCase.action, testCase.name)
            XCTAssertEqual(result.inspectionDestination, testCase.destination, testCase.name)
            XCTAssertEqual(result.symbolName, testCase.symbol, testCase.name)
            XCTAssertFalse(result.headline.isEmpty, testCase.name)
            XCTAssertFalse(result.detail.isEmpty, testCase.name)
        }
    }

    func testCanonicalPrecedenceForConflictingPublishedState() {
        let resumeAt = now.addingTimeInterval(3_600)

        let libraryWins = resolve(
            input(
                library: .unavailable(.unavailable),
                screenRecordingAllowed: false,
                isRecording: true,
                timedPauseUntil: resumeAt,
                pauseReason: .lowDiskSpace,
                captureIssue: .stopFailed
            ))
        XCTAssertEqual(libraryWins.phase, .libraryUnavailable(.unavailable))
        XCTAssertEqual(libraryWins.primaryAction, .retryLibrary)
        XCTAssertTrue(libraryWins.controls.canStop)

        let permissionWins = resolve(
            input(
                screenRecordingAllowed: false,
                timedPauseUntil: resumeAt,
                pauseReason: .lowDiskSpace,
                captureIssue: .startFailed
            ))
        XCTAssertEqual(permissionWins.phase, .setupRequired(resumeAt: resumeAt))
        XCTAssertEqual(permissionWins.primaryAction, .setupCapture(.screenRecording))
        XCTAssertTrue(permissionWins.detail.contains("10:00"))

        let failureWins = resolve(
            input(
                isRecording: true,
                timedPauseUntil: resumeAt,
                pauseReason: .lowDiskSpace,
                captureIssue: .pauseFailed
            ))
        XCTAssertEqual(failureWins.phase, .captureFailed(.pauseFailed))
        XCTAssertEqual(failureWins.primaryAction, .retryCapture(.pauseFailed))

        let timedPauseWins = resolve(
            input(
                timedPauseUntil: resumeAt,
                pauseReason: .lowDiskSpace
            ))
        XCTAssertEqual(timedPauseWins.phase, .timedPause(until: resumeAt))
        XCTAssertEqual(timedPauseWins.primaryAction, .resumeCapture)

        let expiredPauseDoesNotWin = resolve(
            input(
                timedPauseUntil: now,
                pauseReason: .lowDiskSpace
            ))
        XCTAssertEqual(expiredPauseDoesNotWin.phase, .lowDiskSpace)

        let permissionStillWinsOverEnergySaving = resolve(
            input(
                screenRecordingAllowed: false,
                isRecording: true,
                energySaverReason: .battery
            ))
        XCTAssertEqual(
            permissionStillWinsOverEnergySaving.phase,
            .setupRequired(resumeAt: nil)
        )
    }

    func testAccessibilityOnlyRecoveryNamesAndRoutesTheMissingPermission() {
        let result = resolve(input(accessibilityAllowed: false))

        XCTAssertEqual(result.primaryAction, .setupCapture(.accessibility))
        XCTAssertEqual(result.actionLabel, "Allow Accessibility...")
        XCTAssertEqual(result.actionHint, "Open Accessibility setup.")
        XCTAssertTrue(result.detail.contains("exclusions and app context"))
        XCTAssertFalse(result.detail.contains("Screen Recording"))
        XCTAssertFalse(result.controls.canCaptureOnce)
    }

    func testDiskMirrorNormalizesToOnePauseReason() {
        let diskMirror = resolve(
            input(
                isRecording: true,
                pauseReason: .inactivity,
                pausedForDisk: true
            ))
        XCTAssertEqual(diskMirror.phase, .lowDiskSpace)
        XCTAssertEqual(diskMirror.primaryAction, .manageStorage)

        let permissionStillWins = resolve(
            input(
                isRecording: true,
                pauseReason: .permissionRequired,
                pausedForDisk: true
            ))
        XCTAssertEqual(permissionStillWins.phase, .setupRequired(resumeAt: nil))
        XCTAssertEqual(permissionStillWins.primaryAction, .setupCapture(.screenRecording))
    }

    func testControlsPreserveStopAndProtectBlockedCaptureNow() {
        let unavailableWhileRunning = resolve(
            input(
                library: .unavailable(.databaseUnavailable),
                isRecording: true
            ))
        XCTAssertEqual(
            unavailableWhileRunning.controls,
            CaptureStatusControls(
                canStop: true,
                canSchedulePause: false,
                canCaptureOnce: false
            )
        )

        let normalRecording = resolve(input(isRecording: true))
        XCTAssertEqual(
            normalRecording.controls,
            CaptureStatusControls(
                canStop: true,
                canSchedulePause: true,
                canCaptureOnce: true
            )
        )

        let energySaving = resolve(
            input(isRecording: true, energySaverReason: .lowPowerMode)
        )
        XCTAssertTrue(energySaving.controls.canStop)
        XCTAssertTrue(energySaving.controls.canSchedulePause)
        XCTAssertTrue(energySaving.controls.canCaptureOnce)

        let privacyPause = resolve(input(isRecording: true, pauseReason: .privateBrowsing))
        XCTAssertTrue(privacyPause.controls.canStop)
        XCTAssertTrue(privacyPause.controls.canSchedulePause)
        XCTAssertFalse(privacyPause.controls.canCaptureOnce)

        let captureOff = resolve(input())
        XCTAssertFalse(captureOff.controls.canStop)
        XCTAssertFalse(captureOff.controls.canSchedulePause)
        XCTAssertTrue(captureOff.controls.canCaptureOnce)
    }

    func testNonRetryableFailureHasNoPrimaryAction() {
        let result = resolve(input(isRecording: true, captureIssue: .automaticCaptureFailed))

        XCTAssertEqual(result.phase, .captureFailed(.automaticCaptureFailed))
        XCTAssertNil(result.primaryAction)
        XCTAssertNil(result.actionLabel)
        XCTAssertEqual(result.inspectionDestination, .capture)
        XCTAssertFalse(result.controls.canCaptureOnce)
    }

    func testLocalProcessingCopyDoesNotClaimSavingWhileCaptureIsOff() {
        let offStatus = resolve(input())
        let onStatus = resolve(input(isRecording: true))
        let pausedStatus = resolve(input(isRecording: true, pauseReason: .privateBrowsing))

        let off = CaptureLocalProcessingCopy.caption(
            intervalSeconds: 2,
            isSaving: CaptureLocalProcessingCopy.isActivelySaving(offStatus)
        )
        let on = CaptureLocalProcessingCopy.caption(
            intervalSeconds: 2,
            isSaving: CaptureLocalProcessingCopy.isActivelySaving(onStatus)
        )
        let paused = CaptureLocalProcessingCopy.caption(
            intervalSeconds: 2,
            isSaving: CaptureLocalProcessingCopy.isActivelySaving(pausedStatus)
        )

        XCTAssertEqual(offStatus.phase, .off)
        XCTAssertEqual(onStatus.phase, .on)
        XCTAssertEqual(pausedStatus.phase, .automaticPause(.privateBrowsing))
        XCTAssertFalse(off.contains("are saved"))
        XCTAssertFalse(paused.contains("are saved"))
        XCTAssertTrue(off.localizedCaseInsensitiveContains("when capture is on"))
        XCTAssertTrue(on.contains("are saved"))
        XCTAssertEqual(CaptureLocalProcessingCopy.intervalLabel(2), "Every 2 seconds")
    }

    func testOpeningLibraryDoesNotOfferDuplicateRetry() {
        let result = resolve(input(library: .opening(.schemaMigrationFailed)))

        XCTAssertEqual(result.phase, .openingLibrary)
        XCTAssertNil(result.primaryAction)
        XCTAssertEqual(result.tone, .working)
    }

    func testToolbarKeepsOneDirectCaptureControlAndHidesRecoveryActions() {
        struct TestCase {
            let name: String
            let status: CaptureStatusPresentation
            let expected: CaptureStatusToolbarPresentation
        }

        let cases = [
            TestCase(
                name: "capture off",
                status: resolve(input()),
                expected: toolbar(
                    "Start Capture",
                    "play.fill",
                    .perform(.startCapture),
                    "Start automatic capture."
                )
            ),
            TestCase(
                name: "setup routes through start",
                status: resolve(input(screenRecordingAllowed: false)),
                expected: toolbar(
                    "Set Up Screen Recording",
                    "play.fill",
                    .perform(.setupCapture(.screenRecording)),
                    "Allow Screen Recording, then choose whether capture starts."
                )
            ),
            TestCase(
                name: "accessibility recovery routes exactly",
                status: resolve(input(accessibilityAllowed: false)),
                expected: toolbar(
                    "Set Up Accessibility",
                    "play.fill",
                    .perform(.setupCapture(.accessibility)),
                    "Allow Accessibility, then choose whether capture starts."
                )
            ),
            TestCase(
                name: "start retry remains a direct control",
                status: resolve(input(captureIssue: .startFailed)),
                expected: toolbar(
                    "Start Capture",
                    "play.fill",
                    .perform(.retryCapture(.startFailed)),
                    "Try starting automatic capture again."
                )
            ),
            TestCase(
                name: "timed pause",
                status: resolve(input(timedPauseUntil: now.addingTimeInterval(3_600))),
                expected: toolbar(
                    "Resume Capture",
                    "play.fill",
                    .perform(.resumeCapture),
                    "Resume automatic capture now."
                )
            ),
            TestCase(
                name: "running capture",
                status: resolve(input(isRecording: true)),
                expected: toolbar(
                    "Stop Capture",
                    "stop.fill",
                    .stopCapture,
                    "Stop automatic capture."
                )
            ),
            TestCase(
                name: "energy saving capture",
                status: resolve(input(isRecording: true, energySaverReason: .battery)),
                expected: toolbar(
                    "Stop Capture",
                    "stop.fill",
                    .stopCapture,
                    "Stop automatic capture."
                )
            ),
            TestCase(
                name: "running low disk state preserves stop",
                status: resolve(input(isRecording: true, pauseReason: .lowDiskSpace)),
                expected: toolbar(
                    "Stop Capture",
                    "stop.fill",
                    .stopCapture,
                    "Stop automatic capture."
                )
            ),
            TestCase(
                name: "Library recovery stays out of the toolbar",
                status: resolve(input(library: .unavailable(.databaseUnavailable))),
                expected: toolbar("Capture Unavailable", "record.circle")
            ),
            TestCase(
                name: "automatic failure stays out of the toolbar",
                status: resolve(input(captureIssue: .automaticCaptureFailed)),
                expected: toolbar("Capture Off", "record.circle")
            ),
        ]

        for testCase in cases {
            XCTAssertEqual(
                CaptureStatusToolbarResolver.resolve(testCase.status),
                testCase.expected,
                testCase.name
            )
        }
    }

    private func resolve(_ input: CaptureStatusInput) -> CaptureStatusPresentation {
        CaptureStatusResolver.resolve(input, at: now) { _ in "10:00 AM" }
    }

    private func input(
        library: CaptureStatusInput.LibraryState = .ready,
        screenRecordingAllowed: Bool = true,
        accessibilityAllowed: Bool = true,
        isRecording: Bool = false,
        timedPauseUntil: Date? = nil,
        pauseReason: CapturePauseReason? = nil,
        energySaverReason: CaptureEnergySaverReason? = nil,
        pausedForDisk: Bool = false,
        captureIssue: CaptureIssue? = nil
    ) -> CaptureStatusInput {
        CaptureStatusInput(
            library: library,
            permissions: PermissionsSnapshot(
                screenRecording: screenRecordingAllowed,
                accessibility: accessibilityAllowed
            ),
            isRecording: isRecording,
            timedPauseUntil: timedPauseUntil,
            pauseReason: pauseReason,
            energySaverReason: energySaverReason,
            pausedForDisk: pausedForDisk,
            captureIssue: captureIssue
        )
    }

    private func toolbar(
        _ title: String,
        _ symbolName: String,
        _ action: CaptureStatusToolbarAction? = nil,
        _ actionHint: String? = nil
    ) -> CaptureStatusToolbarPresentation {
        CaptureStatusToolbarPresentation(
            title: title,
            symbolName: symbolName,
            action: action,
            actionHint: actionHint
        )
    }
}
