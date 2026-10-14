import ScreenlogCore
import SwiftUI

/// Progress and recovery for a user-created Library backup.
struct LibraryExportStatusView: View {
    @EnvironmentObject private var model: AppModel

    @ViewBuilder
    var body: some View {
        switch model.libraryExportState {
        case .idle:
            EmptyView()
        case .exporting:
            StorageProgressStatus(
                message: "Creating and verifying your Library backup...",
                identifier: "storage.library-export.progress"
            )
        case .completed(let destination):
            StorageResultStatus(
                message: "Screenlogger created and verified your Library backup.",
                systemImage: "checkmark.circle.fill",
                identifier: "storage.library-export.completed"
            ) {
                Button("Show in Finder") { model.revealLibraryExport(destination) }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .accessibilityHint("Show the verified Library backup in Finder")
                    .accessibilityIdentifier("storage.library-export.reveal")
                Button("Done") { model.dismissLibraryExportStatus() }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .accessibilityIdentifier("storage.library-export.done")
            }
        case .failed(let error):
            StorageResultStatus(
                message: error.localizedDescription,
                systemImage: "exclamationmark.triangle.fill",
                color: SLDesign.error,
                identifier: "storage.library-export.failed"
            ) {
                Button("Try Again...") { model.chooseLibraryExportDestination() }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .accessibilityHint("Choose another destination for the Library backup")
                    .accessibilityIdentifier("storage.library-export.retry")
                Button("Dismiss") { model.dismissLibraryExportStatus() }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .accessibilityIdentifier("storage.library-export.dismiss")
            }
        }
    }
}

/// Progress and recovery for a reviewed Library restore.
struct LibraryRestoreStatusView: View {
    @EnvironmentObject private var model: AppModel

    @ViewBuilder
    var body: some View {
        switch model.libraryRestoreState {
        case .idle, .ready:
            EmptyView()
        case .validating:
            StorageProgressStatus(
                message: "Verifying the selected Library backup...",
                identifier: "storage.library-restore.validating"
            )
        case .restoring:
            StorageProgressStatus(
                message: "Replacing and checking your Library...",
                identifier: "storage.library-restore.progress"
            )
        case .completed:
            StorageResultStatus(
                message: "Screenlogger restored and verified your Library.",
                systemImage: "checkmark.circle.fill",
                identifier: "storage.library-restore.completed"
            ) {
                Button("Done") { model.dismissLibraryRestoreResult() }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .accessibilityIdentifier("storage.library-restore.done")
            }
        case .failed(let error):
            StorageResultStatus(
                message: error.localizedDescription,
                systemImage: "exclamationmark.triangle.fill",
                color: SLDesign.error,
                identifier: "storage.library-restore.failed"
            ) {
                Button("Choose Another Backup...") { model.chooseLibraryRestoreSource() }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .accessibilityHint("Choose another Screenlogger Library backup for verification")
                    .accessibilityIdentifier("storage.library-restore.choose-another")
                Button("Dismiss") { model.dismissLibraryRestoreResult() }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .accessibilityIdentifier("storage.library-restore.dismiss")
            }
        }
    }
}

/// Progress and recovery for manual compression and storage-limit enforcement.
struct StorageMaintenanceStatusView: View {
    @EnvironmentObject private var model: AppModel

    @ViewBuilder
    var body: some View {
        switch model.storageMaintenanceState {
        case .idle:
            EmptyView()
        case .running(let operation):
            StorageProgressStatus(
                message: runningMessage(operation),
                identifier: "settings.storage.maintenance.status"
            )
        case .success(let success):
            StorageResultStatus(
                message: successMessage(success),
                systemImage: "checkmark.circle.fill",
                identifier: "settings.storage.maintenance.status"
            ) {
                Button("Done") { model.dismissStorageMaintenanceStatus() }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .accessibilityIdentifier("settings.storage.maintenance.done")
            }
        case .failure(let failure):
            StorageResultStatus(
                message: failure.userMessage,
                systemImage: "exclamationmark.triangle.fill",
                color: SLDesign.error,
                identifier: "settings.storage.maintenance.status"
            ) {
                if failure.retryOperation != nil {
                    Button("Retry") { model.retryStorageMaintenance() }
                        .buttonStyle(.borderless)
                        .tint(.primary)
                        .accessibilityIdentifier("settings.storage.maintenance.retry")
                }
                Button("Dismiss") { model.dismissStorageMaintenanceStatus() }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .accessibilityIdentifier("settings.storage.maintenance.dismiss")
            }
        }
    }

    private func runningMessage(_ operation: StorageMaintenanceOperation) -> String {
        switch operation {
        case .compaction: return "Compressing older capture images..."
        case .retention: return "Applying your storage limits..."
        }
    }

    private func successMessage(_ success: StorageMaintenanceSuccess) -> String {
        switch success {
        case .compacted(let imageCount):
            return "Compressed \(imageCount) older capture images."
        case .nothingToCompact:
            return "Nothing is ready to compress yet."
        case .retentionApplied(_, let freedBytes):
            return
                "Removed older capture media and freed \(AppModel.formatByteSize(freedBytes)). "
                + "Searchable history remains available."
        case .alreadyWithinLimits:
            return "Your Library is already within its limits."
        }
    }
}

/// Progress and recovery for reviewed, permanent history deletion.
struct StorageDeletionStatusView: View {
    @EnvironmentObject private var model: AppModel

    @ViewBuilder
    var body: some View {
        if let issue = storageDeletionIssue {
            StorageResultStatus(
                message: issue.message,
                systemImage: "exclamationmark.triangle.fill",
                color: SLDesign.error,
                identifier: "library.deletion.issue.storage"
            ) {
                if issue.canRetry {
                    Button("Retry") {
                        Task { await model.retryLibraryDeletionIssue() }
                    }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .accessibilityIdentifier("library.deletion.issue.storage.retry")
                }
                Button("Dismiss") { model.dismissLibraryDeletionIssue() }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .accessibilityIdentifier("library.deletion.issue.storage.dismiss")
            }
        } else if model.libraryDeletionInProgress, model.libraryDeletionReview == nil {
            StorageProgressStatus(
                message: "Reviewing the selected history...",
                identifier: "settings.storage.deletion.progress"
            )
        } else if let success = model.libraryDeletionSuccess {
            StorageResultStatus(
                message: successMessage(success),
                systemImage: "checkmark.circle.fill",
                identifier: "settings.storage.deletion.success"
            ) {
                Button("Done") { model.dismissLibraryDeletionSuccess() }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .accessibilityIdentifier("settings.storage.deletion.done")
            }
        }
    }

    private var storageDeletionIssue: LibraryDeletionIssue? {
        guard let issue = model.libraryDeletionIssue,
            issue.origin == .storage,
            model.libraryDeletionReview == nil
        else { return nil }
        return issue
    }

    private func successMessage(_ success: LibraryDeletionSuccess) -> String {
        let momentLabel = success.deletedMomentCount == 1 ? "moment" : "moments"
        let result =
            "Deleted \(success.deletedMomentCount) \(momentLabel) and freed \(AppModel.formatByteSize(success.freedBytes))."
        return success.cleanupPending
            ? "\(result) Screenlogger is finishing file cleanup."
            : result
    }
}

private struct StorageProgressStatus: View {
    let message: String
    let identifier: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityIdentifier(identifier)
    }
}

private struct StorageResultStatus<Actions: View>: View {
    let message: String
    let systemImage: String
    var color: Color = .secondary
    let identifier: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(message, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                actions()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
