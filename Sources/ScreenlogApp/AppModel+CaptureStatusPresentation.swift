import Foundation

@MainActor
extension AppModel {
    func captureStatusPresentation(
        at now: Date = Date()
    ) -> CaptureStatusPresentation {
        CaptureStatusResolver.resolve(captureStatusInput, at: now)
    }

    var captureStatusInput: CaptureStatusInput {
        CaptureStatusInput(
            library: captureStatusLibraryState,
            permissions: permissions,
            isRecording: isRecording,
            timedPauseUntil: recordingPausedUntil,
            pauseReason: capturePauseReason,
            energySaverReason: captureEnergySaverReason,
            pausedForDisk: pausedForDisk,
            captureIssue: captureIssue
        )
    }

    private var captureStatusLibraryState: CaptureStatusInput.LibraryState {
        if libraryBootstrapRetrying {
            return .opening(libraryStartupIssue)
        }
        if let libraryStartupIssue {
            return .unavailable(libraryStartupIssue)
        }
        if libraryRestoreState == .restoring {
            return .restoring
        }
        if isDatabaseReclamationRunning {
            return .reclaimingDatabase
        }
        return .ready
    }

    /// Perform the resolver's current primary action without letting a stale
    /// view or menu item invoke a command that no longer matches app state.
    func performCaptureStatusPrimaryAction(
        _ action: CaptureStatusPrimaryAction,
        setupOrigin: CaptureSetupOrigin
    ) {
        guard captureStatusPresentation().primaryAction == action else { return }

        switch action {
        case .retryLibrary:
            retryLibraryBootstrap()
        case .setupCapture(let permission):
            showPermissions(origin: setupOrigin, preferredPermission: permission)
        case .retryCapture:
            retryCaptureIssue()
        case .resumeCapture:
            resumeRecordingFromPause()
        case .startCapture:
            _ = startCapture()
        case .manageStorage:
            openProductSettings(.storageManagement)
        case .reviewWebsiteExclusions:
            openProductSettings(.exclusionsWebsites)
        }
    }
}
