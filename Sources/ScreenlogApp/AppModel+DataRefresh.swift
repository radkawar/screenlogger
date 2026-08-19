import Foundation
import ScreenlogCore

@MainActor
extension AppModel {
    func refreshPermissions(force: Bool = false) async {
        #if DEBUG
            if let fixturePermissions = AppUITestFixture.permissionsSnapshot {
                permissions = fixturePermissions
                microphoneAuthorization = AppUITestFixture.microphoneAuthorization
                synchronizePermissionJourney(with: fixturePermissions)
                updateStatusMessage()
                return
            }
        #endif
        if force {
            ScreenRecordingPermission.invalidateCache()
            permissions = await PermissionsSnapshot.current(force: true)
        } else {
            // Prefer non-blocking preflight for UI path.
            permissions = PermissionsSnapshot.currentFast()
        }
        microphoneAuthorization = MicrophoneAuthorization.current
        synchronizePermissionJourney(with: permissions)
        updateStatusMessage()
    }

    /// - Parameter light: when true, only refresh stats (keeps menu bar loop snappy).
    func refreshData(light: Bool = false) async {
        guard let store else { return }
        if !light { timelineLoadState = .loading }
        let libraryResultFrameID =
            timelineNavigationOrigin == .libraryResult ? selectedTimelineID : nil
        let loadedSession = libraryResultFrameID == nil ? selectedSession : nil
        let loadedSessionTarget = selectedTimelineFrame?.timestampMs
        do {
            // All SQLite off MainActor.
            let snapshot = try await store.readAsync { s -> (RecordingStats, [FrameRow]?, [TimelineFrame]?) in
                let st = try s.stats()
                if light { return (st, nil, nil) }
                let recent = try s.recentFrames(limit: 40)
                let tl =
                    if let libraryResultFrameID {
                        try s.timelineAround(frameID: libraryResultFrameID, before: 40, after: 40)
                            .sorted(by: TimelineFrame.chronologicalAscending)
                    } else if let loadedSession {
                        try s.timeline(
                            session: loadedSession,
                            aroundTimestampMs: loadedSessionTarget ?? loadedSession.endMs,
                            before: loadedSessionTarget == nil ? 499 : 249,
                            after: loadedSessionTarget == nil ? 0 : 250
                        )
                            .sorted(by: TimelineFrame.chronologicalAscending)
                    } else {
                        try s.recentTimeline(limit: 100)
                            .sorted(by: TimelineFrame.chronologicalAscending)
                    }
                return (st, recent, tl)
            }
            stats = snapshot.0
            if light { return }
            if let r = snapshot.1 { recent = r }
            if let tl = snapshot.2 {
                let previousSelection = selectedTimelineID
                timeline = tl
                if let previousSelection,
                    tl.contains(where: { $0.id == previousSelection })
                {
                    selectedTimelineID = previousSelection
                } else {
                    selectedTimelineID = tl.last?.id
                    rememberTimelineDisplayPreference(frameID: selectedTimelineID)
                }
                timelineLoadState = .ready
            }
            if selectedTimelineID == nil {
                selectedTimelineID = timeline.last?.id
            } else if selectedFrameImage == nil,
                !selectedFrameExtracting,
                selectedFramePreviewIssue == nil
            {
                scheduleSelectedFrameExtract()
            }
            // Never re-run FTS from the background poller - search is user-driven only.
        } catch {
            writeBootstrapLog("data refresh FAILED: \(error)")
            recordDiagnostic(.dataRefresh, .failed)
            if !light {
                timelineLoadState = .failed
                timelineIssue = .refreshTimeline
            }
        }
    }

    /// Refresh navigation data after the engine has durably saved a frame.
    /// Selection follows live capture only when the user was already at the
    /// newest moment; reviewing older history is never pulled forward.
    func refreshAfterCapturedFrame() async {
        guard let store else { return }
        let shouldRefreshNavigation =
            MainShellController.shared.isVisible
            || SearchWindowController.shared.isVisible
        let preservesLibraryResultWindow = timelineNavigationOrigin == .libraryResult
        let selectedSessionStart = selectedSession?.startMs
        let previousSelection = selectedTimelineID
        let previousSelectionTimestamp = selectedTimelineFrame?.timestampMs
        let wasFollowingLatest =
            previousSelection == nil
            || selectedTimelineMomentIndex == timelineMomentCount - 1

        do {
            let snapshot = try await store.readAsync {
                store -> (
                    RecordingStats,
                    [FrameRow],
                    [SessionRow]?,
                    [TimelineFrame]?
                ) in
                let stats = try store.stats()
                let recent = try store.recentFrames(limit: 40)
                guard shouldRefreshNavigation else {
                    return (stats, recent, nil, nil)
                }

                let sessions = try store.sessions(gapMs: 5 * 60 * 1_000)
                if preservesLibraryResultWindow {
                    // The loaded neighborhood is the user's chosen search
                    // result, not a live-tail window. Refresh session metadata
                    // without replacing that older moment when capture grows.
                    return (stats, recent, sessions, nil)
                }
                if let selectedSessionStart,
                    let selected = sessions.first(where: { $0.startMs == selectedSessionStart })
                {
                    let target = wasFollowingLatest
                        ? selected.endMs
                        : (previousSelectionTimestamp ?? selected.endMs)
                    let timeline = try store.timeline(
                        session: selected,
                        aroundTimestampMs: target,
                        before: wasFollowingLatest ? 499 : 249,
                        after: wasFollowingLatest ? 0 : 250
                    )
                        .sorted(by: TimelineFrame.chronologicalAscending)
                    return (stats, recent, sessions, timeline)
                }
                let timeline = try store.recentTimeline(limit: 100)
                    .sorted(by: TimelineFrame.chronologicalAscending)
                return (stats, recent, sessions, timeline)
            }

            stats = snapshot.0
            recent = snapshot.1

            if let rows = snapshot.2 {
                applySessionRefresh(rows)
            }

            if let refreshedTimeline = snapshot.3 {
                timeline = refreshedTimeline
                timelineLoadState = .ready
                if wasFollowingLatest {
                    if timelineMomentCount > 0 {
                        selectTimelineMoment(at: timelineMomentCount - 1)
                    } else {
                        selectedTimelineID = nil
                    }
                } else if let previousSelection,
                    refreshedTimeline.contains(where: { $0.id == previousSelection })
                {
                    selectedTimelineID = previousSelection
                } else {
                    selectedTimelineID = refreshedTimeline.last?.id
                    rememberTimelineDisplayPreference(frameID: selectedTimelineID)
                }
            }
        } catch {
            writeBootstrapLog("captured-frame refresh FAILED: \(error)")
            recordDiagnostic(.dataRefresh, .failed)
            if MainShellController.shared.isVisible {
                timelineLoadState = .failed
                timelineIssue = .refreshTimeline
            }
        }
    }

    /// Map UI time chips onto pure `SearchTimeWindow` for shared filter logic.

    // MARK: - Permissions and maintenance

    func requestScreenRecordingPermission() {
        requestPermission(.screenRecording)
    }

    func requestAccessibilityPermission() {
        requestPermission(.accessibility)
    }

    func openScreenSettings() {
        openPermissionSettings(.screenRecording)
    }

    func openAccessibilitySettings() {
        openPermissionSettings(.accessibility)
    }

    private func requestPermission(_ permission: ScreenlogPermission) {
        let outcome = permissionFlowCoordinator.request(permission)
        #if DEBUG
            let snapshot =
                AppUITestFixture.permissionsSnapshot
                ?? PermissionsSnapshot.currentFast()
        #else
            let snapshot = PermissionsSnapshot.currentFast()
        #endif
        permissions = snapshot
        permissionFlowCoordinator.refresh(with: snapshot)
        permissionJourney = permissionFlowCoordinator.journey
        permissionSettingsResult = outcome.settingsResult
        updateStatusMessage()
    }

    private func openPermissionSettings(_ permission: ScreenlogPermission) {
        permissionSettingsResult = permissionFlowCoordinator.openSettings(permission)
        permissionJourney = permissionFlowCoordinator.journey
    }

    func synchronizePermissionJourney(with snapshot: PermissionsSnapshot) {
        permissionFlowCoordinator.refresh(with: snapshot)
        permissionJourney = permissionFlowCoordinator.journey
        permissionSettingsResult = permissionFlowCoordinator.lastSettingsResult
    }
}
