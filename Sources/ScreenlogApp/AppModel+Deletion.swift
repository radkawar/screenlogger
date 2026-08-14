import Foundation
import ScreenlogCore

/// User-reviewed library deletion and capture lifecycle coordination.
///
/// A deletion always pauses capture before its review is prepared. This keeps the
/// exact reviewed frame set stable until the user confirms or cancels, and capture
/// is restored to its previous state when the flow ends.
@MainActor
extension AppModel {
    func prepareLibraryDeletion(
        _ selection: LibraryDeletionSelection,
        origin: LibraryDeletionOrigin,
        title: String,
        detail: String
    ) async {
        guard let store, !libraryDeletionInProgress, libraryDeletionReview == nil,
            !libraryRestoreState.isBusy, libraryRestoreReview == nil
        else { return }
        let request = LibraryDeletionRequest(
            selection: selection,
            origin: origin,
            title: title,
            detail: detail
        )

        stopReplay()
        libraryDeletionSuccess = nil
        libraryDeletionIssue = nil
        libraryDeletionInProgress = true
        guard pauseCaptureForLibraryDeletion(request: request) else {
            libraryDeletionInProgress = false
            return
        }

        do {
            let plan = try await store.readAsync { store in
                try LibraryDeletionService().prepare(selection: selection, store: store)
            }
            libraryDeletionReview = LibraryDeletionReview(
                origin: origin,
                title: title,
                detail: detail,
                plan: plan,
                captureWasPaused: resumeCaptureAfterLibraryDeletion
            )
        } catch {
            libraryDeletionIssue = preparationIssue(for: error, request: request)
            resumeCaptureAfterLibraryDeletionIfNeeded()
        }
        libraryDeletionInProgress = false
    }

    func cancelLibraryDeletionReview() {
        guard !libraryDeletionInProgress else { return }
        libraryDeletionReview = nil
        libraryDeletionIssue = nil
        resumeCaptureAfterLibraryDeletionIfNeeded()
    }

    func confirmLibraryDeletion() async {
        guard let store, let review = libraryDeletionReview, !libraryDeletionInProgress else { return }
        libraryDeletionInProgress = true
        libraryDeletionIssue = nil

        do {
            let report = try await store.readAsync { store in
                try LibraryDeletionService().delete(
                    review.plan,
                    confirmation: .userConfirmed(reviewID: review.plan.reviewID),
                    store: store
                )
            }

            await clearDeletedLibraryPresentationState()
            libraryDeletionReview = nil
            await refreshData(light: false)
            await loadSessions()
            if hasRunnableLibrarySearchCriteria {
                await runSearch()
            }
            refreshLibrarySize()

            let momentLabel = report.deletedMomentCount == 1 ? "moment" : "moments"
            if review.origin == .timeline {
                publishTimelineNotice(
                    .momentsDeleted(
                        count: report.deletedMomentCount,
                        cleanupPending: report.cleanupPending
                    )
                )
                updateStatusMessage()
            } else {
                libraryDeletionSuccess = LibraryDeletionSuccess(
                    deletedMomentCount: report.deletedMomentCount,
                    freedBytes: report.freedBytes,
                    cleanupPending: report.cleanupPending
                )
                statusMessage =
                    report.cleanupPending
                    ? "Deleted history - finishing file cleanup"
                    : "Deleted \(report.deletedMomentCount) \(momentLabel)"
            }
        } catch {
            let request = LibraryDeletionRequest(
                selection: review.plan.selection,
                origin: review.origin,
                title: review.title,
                detail: review.detail
            )
            if isExpiredDeletionReview(error) {
                libraryDeletionReview = nil
                libraryDeletionIssue = .reviewExpired(request)
                libraryDeletionInProgress = false
                resumeCaptureAfterLibraryDeletionIfNeeded()
                return
            }
            libraryDeletionIssue = .deletionFailed(review)
            libraryDeletionInProgress = false
            // Keep both the reviewed plan and capture pause in place. Retrying
            // cannot silently broaden the deletion, while Cancel resumes capture.
            return
        }

        libraryDeletionInProgress = false
        resumeCaptureAfterLibraryDeletionIfNeeded()
    }

    func retryLibraryDeletionIssue() async {
        guard let issue = libraryDeletionIssue, issue.canRetry else { return }
        libraryDeletionIssue = nil
        switch issue {
        case .preparationFailed(let request),
            .reviewExpired(let request),
            .captureCouldNotPause(let request):
            await prepareLibraryDeletion(
                request.selection,
                origin: request.origin,
                title: request.title,
                detail: request.detail
            )
        case .deletionFailed(let review):
            if libraryDeletionReview == nil {
                libraryDeletionReview = review
            }
            await confirmLibraryDeletion()
        case .nothingToDelete:
            break
        }
    }

    func dismissLibraryDeletionIssue() {
        libraryDeletionIssue = nil
    }

    func dismissLibraryDeletionSuccess() {
        libraryDeletionSuccess = nil
        updateStatusMessage()
    }

    private func preparationIssue(
        for error: Error,
        request: LibraryDeletionRequest
    ) -> LibraryDeletionIssue {
        if let deletionError = error as? LibraryDeletionError,
            deletionError == .nothingToDelete
        {
            return .nothingToDelete(request)
        }
        return .preparationFailed(request)
    }

    private func isExpiredDeletionReview(_ error: Error) -> Bool {
        guard let deletionError = error as? LibraryDeletionError else { return false }
        switch deletionError {
        case .reviewExpired, .confirmationRequired, .confirmationDoesNotMatchReview,
            .nothingToDelete:
            return true
        case .invalidRange, .unsafeManagedPath, .recoveryFailed:
            return false
        }
    }

    private func pauseCaptureForLibraryDeletion(request: LibraryDeletionRequest) -> Bool {
        resumeCaptureAfterLibraryDeletion = engine.isRecording
        guard engine.isRecording else { return true }
        let stopped = engine.stop()
        isRecording = engine.isRecording
        guard stopped else {
            resumeCaptureAfterLibraryDeletion = false
            libraryDeletionIssue = .captureCouldNotPause(request)
            return false
        }
        statusMessage = "Capture paused while you review deletion"
        return true
    }

    private func resumeCaptureAfterLibraryDeletionIfNeeded() {
        guard resumeCaptureAfterLibraryDeletion else { return }
        resumeCaptureAfterLibraryDeletion = false
        guard permissions.isCaptureReady, !engine.isRecording else { return }
        applySettingsToEngine()
        let started = engine.start()
        isRecording = engine.isRecording
        captureIssue = started ? nil : .resumeFailed
        if !started {
            statusMessage = "Couldn't resume capture"
        }
    }

    private func clearDeletedLibraryPresentationState() async {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        invalidateCurrentLibrarySearch()
        extractTask?.cancel()
        prefetchTask?.cancel()
        timeline = []
        selectedTimelineID = nil
        selectedFrameImage = nil
        selectedFrameOCRBoxes = []
        previewCache.removeAllObjects()
        previewMediaGeneration &+= 1
        recent = []
        searchResults = []
        searchFacetResults = []
        librarySearchState = .idle
        await previewImagePipeline.removeAll()
    }
}
