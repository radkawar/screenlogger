import Combine
import Foundation
import ScreenlogCore

@MainActor
extension AppModel {
    func observeSemanticSearchAvailability() {
        semanticAvailabilitySubscription = nil
        guard let controller = semanticSearchController else {
            updateRelatedSearchAvailability(false)
            return
        }
        semanticAvailabilitySubscription = controller.$featureStatus
            .sink { [weak self, weak controller] status in
                guard let self, let controller, self.semanticSearchController === controller else { return }
                self.updateRelatedSearchAvailability(
                    SemanticSearchPresentation.canSearch(status: status), mode: status.mode
                )
            }
    }

    private func updateRelatedSearchAvailability(_ available: Bool, mode: SemanticSearchMode? = nil) {
        let searchChanged = librarySearchEngineSelection.updateAvailability(available, mode: mode)
        var contentChanged = false
        if librarySearchEngine == .related, let mode {
            let supported = SemanticSearchPresentation.supportedContent(searchContent, mode: mode)
            contentChanged = supported != searchContent
            searchContent = supported
        }
        guard searchChanged || contentChanged else { return }
        semanticSearchHits.removeAll()
        semanticSearchMessage = nil
        // Keep query, filters, and selection while the current engine replaces
        // the results. Invalidation rejects replies from the prior source mode.
        startLibrarySearch()
    }

    func configureSemanticSearch(for store: Store) {
        let controller = SemanticSearchController(
            store: store,
            preferences: preferences,
            airgap: { [weak self] in self?.airgapMode ?? true }
        )
        semanticSearchController = controller
        semanticStartupTask = Task {
            guard !Task.isCancelled else { return }
            await controller.start()
        }
    }

    /// Close semantic admission and stop native work before a Library barrier.
    func suspendSemanticSearch() async {
        semanticStartupTask?.cancel()
        semanticInvalidationTask?.cancel()
        semanticPolicyTask?.cancel()
        await semanticSearchController?.suspendAndDrain()
        await semanticStartupTask?.value
        await semanticInvalidationTask?.value
        await semanticPolicyTask?.value
        semanticStartupTask = nil
        semanticInvalidationTask = nil
        semanticPolicyTask = nil
    }

    func resumeSemanticSearch() async {
        guard store != nil, !isPreparingForShutdown,
            !libraryRestoreState.isBusy, !isDatabaseReclamationRunning
        else { return }
        await semanticSearchController?.resume()
    }

    func scheduleSemanticNetworkPolicyChange() {
        semanticPolicyTask?.cancel()
        guard let controller = semanticSearchController else { return }
        semanticPolicyTask = Task {
            guard !Task.isCancelled else { return }
            await controller.networkPolicyDidChange()
        }
    }

    func scheduleSemanticInvalidation() {
        semanticInvalidationTask?.cancel()
        guard let controller = semanticSearchController, !isPreparingForShutdown,
            !libraryRestoreState.isBusy, !isDatabaseReclamationRunning
        else { return }
        if librarySearchEngine != .exact {
            invalidateCurrentLibrarySearch()
            semanticSearchHits.removeAll()
            semanticSearchMessage = nil
            searchResults.removeAll()
            searchFacetResults.removeAll()
            librarySearchState = .idle
        }
        semanticInvalidationTask = Task { [weak self] in
            await controller.invalidate()
            guard let self, !Task.isCancelled,
                self.semanticSearchController === controller,
                self.librarySearchEngine != .exact,
                self.hasRunnableLibrarySearchCriteria
            else { return }
            await self.runSearch()
        }
    }
}
