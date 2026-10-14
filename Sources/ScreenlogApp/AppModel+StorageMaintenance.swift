import Foundation
import ScreenlogCore

@MainActor
extension AppModel {
    func invalidateRetainedPreviewMedia() {
        previewMediaInvalidationTask?.cancel()
        extractTask?.cancel()
        prefetchTask?.cancel()
        previewCache.removeAllObjects()
        selectedFrameImage = nil
        selectedFrameExtracting = false
        selectedFramePreviewIssue = nil
        previewMediaGeneration &+= 1
        let pipeline = previewImagePipeline
        previewMediaInvalidationTask = Task { @MainActor [weak self] in
            await pipeline.removeAll()
            guard let self, !Task.isCancelled else { return }
            if self.selectedTimelineID != nil {
                self.scheduleSelectedFrameExtract()
            }
            self.previewMediaInvalidationTask = nil
        }
    }

    func compactNow() {
        guard let store, !storageMaintenanceInProgress, !isPreparingForShutdown,
            !libraryRestoreState.isBusy, libraryRestoreReview == nil
        else { return }
        statusMessage = "Freeing space..."
        storageMaintenanceState = .running(.compaction)
        Task(priority: .utility) {
            do {
                let n = try await VideoCompactionService().compact(store: store)
                self.statusMessage = n > 0 ? "Compressed older captures" : "Nothing to compress yet"
                await self.refreshData()
                self.refreshLibrarySize()
                self.refreshStorageCleanupPreflight()
                // Keep restore disabled until every old-Store read in this
                // operation has completed, not merely its mutation.
                self.storageMaintenanceState =
                    n > 0
                    ? .success(.compacted(imageCount: n))
                    : .success(.nothingToCompact)
            } catch {
                self.writeBootstrapLog("storage compaction failed: \(error)")
                self.statusMessage = "Ready"
                self.storageMaintenanceState = .failure(.compactionFailed)
            }
        }
    }

    func retentionNow() {
        guard let store, !storageMaintenanceInProgress, !isPreparingForShutdown,
            !libraryRestoreState.isBusy, libraryRestoreReview == nil
        else { return }
        let (days, cap) = effectiveRetentionForEngine()
        // Manual clean always uses the Limit fields when mode is limit;
        // for Off/Compress still allow age purge using the configured days/cap if user clicks Clean.
        let policy: RetentionPolicy
        switch storageMode {
        case .limit:
            policy = RetentionPolicy(retentionDays: days, storageCapMB: cap)
        case .off, .compress:
            policy = RetentionPolicy(
                retentionDays: max(1, retentionDays),
                storageCapMB: max(0, storageCapMB)
            )
        }
        statusMessage = "Cleaning Library..."
        storageMaintenanceState = .running(.retention)
        Task.detached(priority: .utility) {
            do {
                let report = try RetentionService(policy: policy).runDetailed(store: store)
                let result: StorageMaintenanceOperationState
                if report.hasFailures {
                    result = .failure(.retentionCouldNotRemoveFiles)
                } else if !report.capSatisfied {
                    result = .failure(.retentionLimitNotSatisfied)
                } else {
                    let count = report.purgedStillCount + report.purgedVideoCount
                    result =
                        count > 0
                        ? .success(
                            .retentionApplied(
                                removedMediaCount: count,
                                freedBytes: report.freedBytes
                            )
                        )
                        : .success(.alreadyWithinLimits)
                }
                await MainActor.run {
                    switch result {
                    case .failure(.retentionCouldNotRemoveFiles):
                        self.statusMessage = "Screenlogger kept some storage items"
                    case .failure(.retentionLimitNotSatisfied):
                        self.statusMessage = "Storage limit not reached"
                    default:
                        self.statusMessage = "Storage limits applied"
                    }
                }
                await self.refreshData()
                await MainActor.run {
                    self.refreshLibrarySize()
                    self.refreshStorageCleanupPreflight()
                    self.storageMaintenanceState = result
                }
            } catch {
                await MainActor.run {
                    self.writeBootstrapLog("storage retention failed: \(error)")
                    self.statusMessage = "Ready"
                    self.storageMaintenanceState = .failure(.retentionFailed)
                }
            }
        }
    }

    /// This task owns all migration work, including retries and file reclamation.
    /// It never changes capture intent or starts capture.
    func startAutomaticDatabaseMigration() {
        guard databaseMigrationTask == nil, let store, !isPreparingForShutdown else { return }
        databaseMigrationTask = Task.detached(priority: .utility) { [weak self] in
            do {
                var complete = false
                var pending = false
                while !complete {
                    try Task.checkCancellation()
                    do {
                        let batch = try store.migrateDatabasePayloadBatch()
                        complete = batch.isComplete
                        pending = batch.reclamationPending
                        await self?.setDatabaseMigrationStatus(
                            complete
                                ? (pending ? "Database space reclamation pending" : nil)
                                : "Updating database storage"
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        await self?.setDatabaseMigrationStatus("Database storage update pending")
                        try await Task.sleep(nanoseconds: 300_000_000_000)
                    }
                    if !complete { try await Task.sleep(nanoseconds: 20_000_000) }
                }
                // Do not make a full-file rewrite part of startup. Pending
                // reclamation retries only at a stopped-capture opportunity.
                if pending { try await Task.sleep(nanoseconds: 30_000_000_000) }
                while pending {
                    try Task.checkCancellation()
                    if await self?.beginAutomaticDatabaseReclamation() == true {
                        do {
                            _ = try store.reclaimMigratedDatabaseSpace()
                            pending = false
                            await self?.finishAutomaticDatabaseReclamation(completed: true)
                        } catch is CancellationError {
                            await self?.finishAutomaticDatabaseReclamation(completed: false)
                            throw CancellationError()
                        } catch {
                            await self?.finishAutomaticDatabaseReclamation(completed: false)
                        }
                    }
                    if pending { try await Task.sleep(nanoseconds: 300_000_000_000) }
                }
            } catch {
                // Cancellation leaves committed progress and the pending marker.
            }
        }
    }

    private func setDatabaseMigrationStatus(_ message: String?) {
        guard !isPreparingForShutdown, !Task.isCancelled else { return }
        databaseMigrationStatus = message
    }

    private func beginAutomaticDatabaseReclamation() async -> Bool {
        guard !Task.isCancelled, !isPreparingForShutdown,
            !engine.isRecording, captureOnceState != .inProgress,
            recordingPausedUntil == nil, !shouldResumeAfterTimedPause,
            !storageMaintenanceInProgress, !libraryRestoreState.isBusy,
            libraryRestoreReview == nil, !libraryExportState.isExporting,
            !libraryDeletionInProgress, libraryDeletionReview == nil
        else { return false }
        isDatabaseReclamationRunning = true
        databaseMigrationStatus = "Reclaiming database space"
        updateStatusMessage()
        databaseReclamationRestartsSocket = ScreenlogSocketHost.shared.isRunning
        databaseReclamationRestartsXPC = ScreenlogXPCHost.shared.isRunning
        await suspendSemanticSearch()
        await ScreenlogSocketHost.shared.stopAndDrain()
        await ScreenlogXPCHost.shared.stopAndDrain()
        // An already-admitted IPC Start can finish while its host drains.
        // Preserve that Start rather than stopping the user's capture.
        guard !Task.isCancelled, !isPreparingForShutdown, !engine.isRecording,
            captureOnceState != .inProgress, recordingPausedUntil == nil,
            !shouldResumeAfterTimedPause, !libraryRestoreState.isBusy
        else {
            await finishAutomaticDatabaseReclamation(completed: false)
            return false
        }
        databaseReclamationQuiescedEngine = true
        await engine.quiesceForLibraryReplacement()
        guard !Task.isCancelled, !isPreparingForShutdown else {
            await finishAutomaticDatabaseReclamation(completed: false)
            return false
        }
        return true
    }

    private func finishAutomaticDatabaseReclamation(completed: Bool) async {
        isDatabaseReclamationRunning = false
        guard !isPreparingForShutdown, !Task.isCancelled else { return }
        if databaseReclamationQuiescedEngine, let store {
            engine.configure(store: store, dataRoot: root, exclusions: exclusionStore)
            applySettingsToEngine()
            synchronizeRecordingState()
        }
        databaseReclamationQuiescedEngine = false
        await resumeSemanticSearch()
        if databaseReclamationRestartsSocket, cliEnabled {
            applyCLIEnabled()
        }
        if databaseReclamationRestartsXPC, let store {
            do {
                try ScreenlogXPCHost.shared.start(
                    store: store, root: root, engine: RecordingEngineBox()
                )
            } catch {
                writeBootstrapLog("XPC restart after space reclamation failed: \(error)")
            }
        }
        databaseReclamationRestartsSocket = false
        databaseReclamationRestartsXPC = false
        updateStatusMessage()
        databaseMigrationStatus = completed ? nil : "Database space reclamation pending"
        if completed {
            refreshLibrarySize()
            refreshStorageCleanupPreflight()
        }
    }

    func prepareForShutdown() async {
        isPreparingForShutdown = true
        await suspendSemanticSearch()
        databaseMigrationTask?.cancel()
        await databaseMigrationTask?.value
        databaseMigrationTask = nil
        await ScreenlogSocketHost.shared.stopAndDrain()
        await ScreenlogXPCHost.shared.stopAndDrain()
        await engine.quiesceForLibraryReplacement()
    }

    func retryStorageMaintenance() {
        switch storageMaintenanceState.retryOperation {
        case .compaction:
            compactNow()
        case .retention:
            retentionNow()
        case nil:
            break
        }
    }

    func dismissStorageMaintenanceStatus() {
        guard !storageMaintenanceState.isRunning else { return }
        storageMaintenanceState = .idle
        updateStatusMessage()
    }
}
