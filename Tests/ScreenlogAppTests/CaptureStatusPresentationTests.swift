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
            XCTAssertEqual(result.tone, testCase.tone, testCase.name)
            XCTAssertEqual(result.primaryAction, testCase.action, testCase.name)
            XCTAssertEqual(result.inspectionDestination, testCase.destination, testCase.name)
            XCTAssertEqual(result.symbolName, testCase.symbol, testCase.name)
            XCTAssertFalse(result.headline.isEmpty, testCase.name)
            XCTAssertFalse(result.detail.isEmpty, testCase.name)
        }
    }

    func testReclamationBlocksNewCaptureButPreservesAnAdmittedStop() {
        let reclaiming = resolve(input(library: .reclaimingDatabase))
        XCTAssertEqual(reclaiming.phase, .reclaimingDatabase)
        XCTAssertEqual(reclaiming.primaryAction, .manageStorage)
        XCTAssertEqual(reclaiming.inspectionDestination, .storage)
        XCTAssertFalse(reclaiming.controls.canCaptureOnce)
        XCTAssertFalse(reclaiming.controls.canSchedulePause)
        XCTAssertNil(CaptureStatusToolbarResolver.resolve(reclaiming).action)

        let admittedStart = resolve(input(library: .reclaimingDatabase, isRecording: true))
        XCTAssertTrue(admittedStart.controls.canStop)
        XCTAssertEqual(CaptureStatusToolbarResolver.resolve(admittedStart).action, .stopCapture)

        let ready = resolve(input())
        XCTAssertEqual(ready.primaryAction, .startCapture)
        XCTAssertTrue(ready.controls.canCaptureOnce)
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
        XCTAssertFalse(CaptureLocalProcessingCopy.isActivelySaving(offStatus))
        XCTAssertFalse(CaptureLocalProcessingCopy.isActivelySaving(pausedStatus))
        XCTAssertTrue(CaptureLocalProcessingCopy.isActivelySaving(onStatus))
        XCTAssertTrue(off.localizedCaseInsensitiveContains("when capture is on"))
        XCTAssertTrue(paused.localizedCaseInsensitiveContains("when capture is on"))
        XCTAssertFalse(on.localizedCaseInsensitiveContains("when capture is on"))
        XCTAssertEqual(CaptureLocalProcessingCopy.intervalLabel(2), "Every 2 seconds")
    }

    func testOpeningLibraryDoesNotOfferDuplicateRetry() {
        let result = resolve(input(library: .opening(.schemaMigrationFailed)))

        XCTAssertEqual(result.phase, .openingLibrary)
        XCTAssertNil(result.primaryAction)
        XCTAssertEqual(result.tone, .working)
    }

    func testToolbarKeepsOneDirectCaptureControlAndHidesRecoveryActions() {
        let cases: [(CaptureStatusInput, CaptureStatusToolbarAction?)] = [
            (input(), .perform(.startCapture)),
            (input(screenRecordingAllowed: false), .perform(.setupCapture(.screenRecording))),
            (input(accessibilityAllowed: false), .perform(.setupCapture(.accessibility))),
            (input(captureIssue: .startFailed), .perform(.retryCapture(.startFailed))),
            (input(timedPauseUntil: now.addingTimeInterval(3_600)), .perform(.resumeCapture)),
            (input(isRecording: true), .stopCapture),
            (input(isRecording: true, energySaverReason: .battery), .stopCapture),
            (input(isRecording: true, pauseReason: .lowDiskSpace), .stopCapture),
            (input(library: .unavailable(.databaseUnavailable)), nil),
            (input(captureIssue: .automaticCaptureFailed), nil),
        ]

        for (input, expectedAction) in cases {
            let status = resolve(input)
            XCTAssertEqual(CaptureStatusToolbarResolver.resolve(status).action, expectedAction)
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

}
