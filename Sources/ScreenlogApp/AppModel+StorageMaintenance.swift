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
        guard let store, !storageMaintenanceState.isRunning,
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
        guard let store, !storageMaintenanceState.isRunning,
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
        statusMessage = "Cleaning library..."
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
                        self.statusMessage = "Some storage items were kept"
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
