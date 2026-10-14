import AppKit
import Foundation
import ScreenlogCore
import UniformTypeIdentifiers

@MainActor
extension AppModel {
    func chooseLibraryExportDestination() {
        guard store != nil, !libraryExportState.isExporting,
            !libraryRestoreState.isBusy, libraryRestoreReview == nil
        else { return }
        let panel = NSSavePanel()
        panel.title = "Save a Library Copy"
        panel.message = "Choose a folder for your Library copy. Screenlogger verifies the copy and leaves your current Library unchanged."
        panel.prompt = "Save Copy"
        panel.nameFieldLabel = "Save Copy As:"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: LibraryExportService.preferredExtension)
                ?? UTType(exportedAs: "dev.screenlog.library-backup")
        ]
        panel.nameFieldStringValue =
            "Screenlogger Library \(Self.libraryExportDateFormatter.string(from: Date())).\(LibraryExportService.preferredExtension)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exportLibrary(to: destination)
    }

    func exportLibrary(to destination: URL) {
        guard let store, !libraryExportState.isExporting,
            !libraryRestoreState.isBusy, libraryRestoreReview == nil
        else { return }
        libraryExportState = .exporting
        statusMessage = "Exporting Library..."
        libraryExportTask?.cancel()
        libraryExportTask = Task { @MainActor [weak self] in
            do {
                let result = try await Task.detached(priority: .utility) {
                    try LibraryExportService().export(store: store, to: destination)
                }.value
                guard !Task.isCancelled else { return }
                self?.libraryExportState = .completed(result.destination)
                self?.statusMessage = "Library exported and verified"
            } catch {
                guard !Task.isCancelled else { return }
                let exportError =
                    error as? LibraryExportError
                    ?? .snapshotFailed(error.localizedDescription)
                self?.libraryExportState = .failed(exportError)
                self?.statusMessage = "Library export did not finish"
            }
        }
    }

    func revealLibraryExport(_ destination: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    func dismissLibraryExportStatus() {
        guard !libraryExportState.isExporting else { return }
        libraryExportState = .idle
        updateStatusMessage()
    }

    func chooseLibraryRestoreSource() {
        guard store != nil,
            !libraryRestoreState.isBusy,
            !libraryExportState.isExporting,
            !storageMaintenanceInProgress,
            !libraryDeletionInProgress,
            libraryDeletionReview == nil
        else { return }

        let panel = NSOpenPanel()
        panel.title = "Restore a Library Copy"
        panel.message = "Choose a Screenlogger Library copy. You can review it before replacing any captured history."
        panel.prompt = "Review Copy"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: LibraryExportService.preferredExtension)
                ?? UTType(exportedAs: "dev.screenlog.library-backup")
        ]
        guard panel.runModal() == .OK, let archive = panel.url else { return }
        validateLibraryRestore(archive)
    }

    func validateLibraryRestore(_ archive: URL) {
        guard !libraryRestoreState.isBusy else { return }
        libraryRestoreReview = nil
        libraryRestoreState = .validating
        statusMessage = "Verifying Library copy..."
        libraryRestoreTask?.cancel()
        libraryRestoreTask = Task { @MainActor [weak self] in
            let preflight = await Task.detached(priority: .utility) {
                LibraryExportService().preflightRestore(at: archive)
            }.value
            guard let self, !Task.isCancelled else { return }
            switch preflight {
            case .ready(let manifest):
                self.libraryRestoreReview = LibraryRestoreReview(archive: archive, manifest: manifest)
                self.libraryRestoreState = .ready
                self.statusMessage = "Library copy verified"
            case .newerSchema(let found, let supported, _):
                self.libraryRestoreState = .failed(.newerSchema(found: found, supported: supported))
                self.statusMessage = "Library copy needs a newer Screenlogger"
            case .invalid(let issue):
                self.libraryRestoreState = .failed(.invalidBackup(issue))
                self.statusMessage = "Could not verify Library copy"
            }
        }
    }

    func cancelLibraryRestoreReview() {
        guard libraryRestoreState == .ready else { return }
        libraryRestoreReview = nil
        libraryRestoreState = .idle
        updateStatusMessage()
    }

    func dismissLibraryRestoreResult() {
        guard !libraryRestoreState.isBusy, libraryRestoreReview == nil else { return }
        libraryRestoreState = .idle
        updateStatusMessage()
    }

    func confirmLibraryRestore() {
        guard let review = libraryRestoreReview,
            libraryRestoreState == .ready,
            store != nil
        else { return }
        libraryRestoreState = .restoring
        statusMessage = "Replacing Library..."
        libraryRestoreTask?.cancel()
        libraryRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.quiesceForLibraryRestore()
                let liveRoot = self.root
                _ = try await Task.detached(priority: .userInitiated) {
                    try LibraryRestoreService().restore(from: review.archive, replacing: liveRoot)
                }.value
                await self.clearLibraryPresentationAfterRestore()
                await self.previewImagePipeline.resume()
                self.libraryRestoreReview = nil
                self.bootstrap()
                self.libraryRestoreState = .completed
                self.statusMessage = "Library restored"
            } catch is CancellationError {
                // App termination can cancel the UI owner while the durable
                // restore journal remains authoritative for next-launch recovery.
                await self.previewImagePipeline.resume()
                return
            } catch {
                let restoreError = error as? LibraryRestoreError ?? .activationFailed
                // A failed activation has either left the live Library untouched
                // or rolled it back. Reopen it before returning control to the UI.
                await self.previewImagePipeline.resume()
                self.bootstrap()
                self.libraryRestoreReview = nil
                self.libraryRestoreState = .failed(restoreError)
                self.statusMessage = "Library restore did not finish"
            }
            self.libraryRestoreTask = nil
        }
    }

    private func clearLibraryPresentationAfterRestore() async {
        clearSearch()
        timeline = []
        selectedTimelineID = nil
        selectedFrameImage = nil
        selectedFrameOCRBoxes = []
        recent = []
        sessions = []
        selectedSessionIndex = nil
        searchSessionScoped = false
        previewCache.removeAllObjects()
        await previewImagePipeline.removeAll()
        previewMediaGeneration &+= 1
    }

    private static let libraryExportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
