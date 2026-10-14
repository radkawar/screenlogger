import Foundation
import ScreenlogCore

/// Capture controls, permission refresh, and explicit storage maintenance.
///
/// RecordingEngine remains lifecycle-owned by AppModel; this extension is the
/// feature boundary for user commands and authoritative state synchronization.
@MainActor
extension AppModel {
    // MARK: - Recording

    var captureIntent: Bool? {
        CaptureIntentPreference.value(from: preferences)
    }

    /// The user's automatic-capture choice, distinct from whether the engine
    /// is saving a frame at this instant. A timed pause keeps capture enabled.
    var automaticCaptureEnabled: Bool {
        if shouldResumeAfterTimedPause,
            let until = recordingPausedUntil,
            until > Date()
        {
            return true
        }
        return isRecording
    }

    func setAutomaticCaptureEnabled(_ enabled: Bool) {
        if enabled {
            if shouldResumeAfterTimedPause, recordingPausedUntil != nil {
                resumeRecordingFromPause()
            } else {
                _ = startCapture()
            }
        } else {
            clearTimedPause(resume: false)
            _ = stopCapture()
        }
    }

    /// Records a real onboarding choice so choosing 'Not Now' does not make
    /// Setup reappear on every launch. Capture can still be started anywhere.
    @discardableResult
    func keepCaptureOff() -> Bool {
        clearTimedPause(resume: false)
        if engine.isRecording, !stopCapture() {
            // `stopCapture` publishes a scoped recovery issue and a truthful
            // status. Never claim capture is off if the engine disagrees.
            return false
        }
        resetFirstRunValueProgress()
        CaptureIntentPreference.save(false, to: preferences)
        statusMessage =
            permissions.isCaptureReady
            ? "Ready - capture off"
            : "Permissions setup incomplete - capture off"
        return true
    }

    /// Starts the first-run capture journey without claiming success until the
    /// engine publishes a frame that completed storage and indexing.
    @discardableResult
    func startFirstRunCapture() -> Bool {
        var progress = firstRunValueProgress
        progress.begin(after: engine.lastFrameID)
        firstRunValueProgress = progress

        let started = isRecording || startCapture()
        if !started {
            resetFirstRunValueProgress()
        }
        return started
    }

    func resetFirstRunValueProgress() {
        guard firstRunValueProgress.phase != .idle else { return }
        firstRunValueProgress = FirstRunValueProgress()
    }

    @discardableResult
    func startCapture(persistIntent: Bool = true) -> Bool {
        guard !isDatabaseReclamationRunning, !isPreparingForShutdown else {
            statusMessage = "Wait for database space reclamation before you start capture"
            return false
        }
        #if DEBUG
            if AppUITestFixture.startCaptureIfRequested(on: self) {
                captureIssue = nil
                return true
            }
        #endif
        guard libraryRestoreState != .restoring else {
            statusMessage = "Capture is paused while Screenlogger restores the Library"
            return false
        }
        guard libraryStartupIssue == nil, store != nil else {
            statusMessage = libraryStartupIssue?.statusTitle ?? "Library Unavailable"
            recordDiagnostic(.capture, .failed)
            return false
        }
        guard permissions.isCaptureReady else {
            statusMessage = "Allow \(missingCapturePermissionNames) to start capture"
            recordDiagnostic(.capture, .failed)
            return false
        }
        if persistIntent {
            discardTimedPause()
            CaptureIntentPreference.save(true, to: preferences)
        }
        guard !engine.isRecording else {
            synchronizeRecordingState()
            updateStatusMessage()
            return true
        }
        applySettingsToEngine()
        recordDiagnostic(.capture, .started)
        let started = engine.start()
        synchronizeRecordingState()
        if started {
            captureIssue = nil
            statusMessage = captureRunningStatusMessage
        } else {
            captureIssue = .startFailed
            statusMessage = "Could not start capture"
        }
        recordDiagnostic(.capture, started ? .succeeded : .failed)
        return started
    }

    @discardableResult
    func stopCapture(persistIntent: Bool = true) -> Bool {
        if persistIntent {
            discardTimedPause()
        }
        guard engine.isRecording else {
            synchronizeRecordingState()
            if persistIntent {
                CaptureIntentPreference.save(false, to: preferences)
            }
            statusMessage = "Capture is already off"
            return true
        }
        let stopped = engine.stop()
        synchronizeRecordingState()
        captureIssue = stopped ? nil : .stopFailed
        if stopped, persistIntent {
            CaptureIntentPreference.save(false, to: preferences)
        }
        statusMessage = stopped ? "Capture stopped" : "Could not stop capture"
        recordDiagnostic(.capture, stopped ? .stopped : .failed)
        return stopped
    }

    func toggleRecording() {
        // Explicit start/stop cancels a timed pause.
        clearTimedPause(resume: false)
        if engine.isRecording {
            stopCapture()
        } else {
            startCapture()
        }
    }

    /// Stop capture and auto-resume after one hour.
    func pauseRecordingForOneHour() {
        guard engine.isRecording else {
            clearTimedPause(resume: false)
            synchronizeRecordingState()
            statusMessage = "Capture is already off"
            return
        }

        let stopped = engine.stop()
        synchronizeRecordingState()
        guard stopped else {
            captureIssue = .pauseFailed
            statusMessage = "Could not pause capture"
            return
        }

        let startedAt = Date()
        let until = startedAt.addingTimeInterval(60 * 60)
        CaptureIntentPreference.save(true, to: preferences)
        TimedCapturePausePreference.save(
            startedAt: startedAt,
            resumeAt: until,
            to: preferences
        )
        recordingPausedUntil = until
        shouldResumeAfterTimedPause = true
        _ = restoreTimedPauseAfterLibraryReopen()
    }

    /// Re-arm an in-memory timed pause after restore temporarily tears down and
    /// reopens capture. A true result tells bootstrap not to apply ordinary
    /// capture intent while the pause remains active.
    @discardableResult
    func restoreTimedPauseAfterLibraryReopen() -> Bool {
        guard captureIntent == true else {
            discardTimedPause()
            return false
        }
        guard
            let until = TimedCapturePausePreference.restoredResumeDate(
                from: preferences
            )
        else {
            discardTimedPause()
            return false
        }

        recordingPausedUntil = until
        shouldResumeAfterTimedPause = true
        pauseResumeTask?.cancel()
        let remaining = until.timeIntervalSinceNow
        guard remaining > 0 else {
            resumeRecordingFromPause()
            return true
        }
        statusMessage = "Paused until \(Self.shortTimeFormatter.string(from: until))"
        pauseResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resumeRecordingFromPause()
        }
        return true
    }

    /// Resume after timed pause (or cancel pause early from the menu).
    func resumeRecordingFromPause() {
        clearTimedPause(resume: true)
    }

    /// Reconciles explicit CLI/IPC capture commands with the in-memory timer.
    /// Those commands share preferences with the app but do not own AppModel.
    func reconcileTimedPausePreference(now: Date = Date()) {
        guard shouldResumeAfterTimedPause || recordingPausedUntil != nil else { return }
        guard captureIntent == true else {
            clearTimedPause(resume: false)
            updateStatusMessage()
            return
        }

        guard
            let restoredUntil = TimedCapturePausePreference.restoredResumeDate(
                from: preferences,
                now: now
            )
        else {
            clearTimedPause(resume: true)
            return
        }

        if recordingPausedUntil != restoredUntil {
            recordingPausedUntil = restoredUntil
            shouldResumeAfterTimedPause = true
            _ = restoreTimedPauseAfterLibraryReopen()
        }
    }

    private func clearTimedPause(resume: Bool) {
        pauseResumeTask?.cancel()
        pauseResumeTask = nil
        let wasPaused = recordingPausedUntil != nil
        let shouldResume = shouldResumeAfterTimedPause
        recordingPausedUntil = nil
        shouldResumeAfterTimedPause = false
        TimedCapturePausePreference.clear(from: preferences)
        guard resume, wasPaused, shouldResume else { return }
        guard captureIntent == true else {
            updateStatusMessage()
            return
        }
        if !engine.isRecording {
            let started = startCapture(persistIntent: false)
            if !started, permissions.isCaptureReady {
                captureIssue = .resumeFailed
                statusMessage = "Could not resume capture"
            } else if started {
                statusMessage = "Capture resumed"
            }
        }
    }

    private func discardTimedPause() {
        pauseResumeTask?.cancel()
        pauseResumeTask = nil
        recordingPausedUntil = nil
        shouldResumeAfterTimedPause = false
        TimedCapturePausePreference.clear(from: preferences)
    }

    /// Mirrors engine-owned state after every transition instead of predicting it.
    func synchronizeRecordingState() {
        isRecording = engine.isRecording
        pausedForDisk = engine.pausedForDisk
    }

    func dismissCaptureIssue() {
        captureIssue = nil
        updateStatusMessage()
    }

    func retryCaptureIssue() {
        guard let issue = captureIssue, issue.canRetry else { return }
        captureIssue = nil
        switch issue {
        case .startFailed, .resumeFailed:
            _ = startCapture()
        case .stopFailed:
            _ = stopCapture()
        case .pauseFailed:
            pauseRecordingForOneHour()
        case .automaticCaptureFailed:
            break
        }
    }

    static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// Exclude the exact application the menu presented to the user. The
    /// frontmost app may change between menu display and action delivery.
    func excludeApplication(bundleID: String, displayName: String? = nil) {
        guard !bundleID.isEmpty else { return }
        addExclusion(bundleID)
        let name = displayName ?? SLAppIdentity.displayName(bundleID: bundleID)
        recentCaptureExclusion = .application(
            ExcludedApplicationChange(
                bundleID: bundleID,
                displayName: name
            )
        )
        statusMessage = "Will not capture \(name)"
    }

    func excludeWebsite(domain: String) {
        guard let normalized = DomainExclusionParser.normalize(domain) else { return }
        exclusionStore.addDomain(normalized)
        recentCaptureExclusion = .website(domain: normalized)
        reloadExclusionsFromStore()
        statusMessage = "Will not capture \(normalized)"
    }

    func undoRecentCaptureExclusion() {
        guard let change = recentCaptureExclusion else { return }
        switch change {
        case .application(let application):
            exclusionStore.remove(application.bundleID)
            statusMessage = "Will capture \(application.displayName) again"
        case .website(let domain):
            exclusionStore.removeDomain(domain)
            statusMessage = "Will capture \(domain) again"
        }
        recentCaptureExclusion = nil
        reloadExclusionsFromStore()
    }

    func captureOnce() async {
        guard captureOnceState != .inProgress, libraryRestoreState != .restoring,
            !isDatabaseReclamationRunning, !isPreparingForShutdown
        else { return }
        guard permissions.isCaptureReady else {
            captureOnceState = .failure(.permissionRequired)
            statusMessage = "Allow \(missingCapturePermissionNames) to save a capture"
            return
        }

        captureOnceState = .inProgress
        do {
            applySettingsToEngine()
            let id = try await engine.captureOneNow()
            captureOnceState = .success(frameID: id)
            statusMessage =
                engine.lastCycleFrameCount > 1
                ? "Saved \(engine.lastCycleFrameCount) displays"
                : "Saved a capture"
            // `lastFrameID` publishes after the durable write and drives the
            // Library refresh; avoid issuing a duplicate Timeline query here.
        } catch is CancellationError {
            // Restore deliberately drains one-shot capture. Keep the idle state.
            captureOnceState = .idle
        } catch {
            writeBootstrapLog("manual capture failed: \(error)")
            let failure = CaptureOnceFailure.classify(error, pauseReason: engine.pauseReason)
            captureOnceState = .failure(failure)
            switch failure {
            case .permissionRequired:
                statusMessage = "Permissions setup required"
            case .lowDiskSpace:
                statusMessage = "Capture paused - low disk space"
            case .excludedContent, .privateBrowsing, .browserAddressUnavailable:
                statusMessage = "Capture skipped for privacy"
            case .displayUnavailable, .encodingFailed, .captureFailed:
                statusMessage = "Could not save capture"
            }
        }
    }

    var lastCaptureDisplayCount: Int {
        max(1, engine.lastCycleFrameCount)
    }

    var captureNowDescription: String {
        switch captureDisplayMode {
        case .active:
            return "Save the active display without changing automatic capture"
        case .all:
            return "Save every connected display without changing automatic capture"
        }
    }

    var captureRunningStatusMessage: String {
        let seconds =
            intervalSeconds == floor(intervalSeconds)
            ? "\(Int(intervalSeconds))"
            : String(format: "%.1f", intervalSeconds)
        return captureDisplayMode == .all
            ? "Capturing all displays every \(seconds)s"
            : "Capturing every \(seconds)s"
    }

    /// Clears only the permission failure that is no longer actionable. Other
    /// one-shot results remain visible until the user explicitly tries again.
    func reconcileCaptureOnceAfterPermissionGrant() {
        guard permissions.isCaptureReady,
            captureOnceState == .failure(.permissionRequired)
        else {
            return
        }
        captureOnceState = .idle
    }

    private var missingCapturePermissionNames: String {
        let names = permissions.missingRequiredPermissions.map(\.title)
        switch names.count {
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "required permissions"
        }
    }
}
