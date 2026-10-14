import ScreenlogCore
import SwiftUI

/// User-initiated Library actions, ordered from reversible to destructive.
struct StorageLibraryToolsCard: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showingAdvancedActions: Bool

    let reviewTodayDeletion: () -> Void
    let chooseDeletionRange: () -> Void
    let reviewEntireLibraryDeletion: () -> Void

    var body: some View {
        SettingsCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                libraryLocationRow
                Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
                backupAndRestoreSection
                Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
                compressionSection
                Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
                advancedActions
            }
        }
    }

    private var libraryLocationRow: some View {
        SettingsCardRow(
            icon: "folder",
            title: "Library Folder",
            subtitle: "Show the files that Screenlogger manages on this Mac."
        ) {
            Button("Show in Finder") { model.openDataFolder() }
                .controlSize(.small)
                .accessibilityHint("Show the Screenlogger Library folder")
                .accessibilityIdentifier("settings.storage.reveal")
        }.padding(SLDesign.space16)
    }

    private var backupAndRestoreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            StorageSectionHeading(
                title: "Backup & Restore",
                detail:
                    "Create a verified backup. Review a backup before it replaces your capture history. Screenlogger keeps your settings and exclusions."
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    backupButton
                    restoreButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    backupButton
                    restoreButton
                }
            }

            LibraryExportStatusView()
            LibraryRestoreStatusView()
        }.padding(SLDesign.space16)
    }

    private var compressionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            StorageSectionHeading(
                title: "Reclaim Space",
                detail: "Compress eligible older images into video without removing moments or searchable text."
            )

            Button {
                model.compactNow()
            } label: {
                Label("Compress Older Captures Now", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.bordered)
            .disabled(exclusiveOperationActive)
            .help("Compress eligible older capture images without deleting searchable history")
            .accessibilityHint("Compress eligible older capture images without deleting searchable history")
            .accessibilityIdentifier("settings.storage.compress-now")

            if let status = model.databaseMigrationStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.storage.database-migration")
            }
            Text(
                "Screenlogger updates older database storage automatically. Screenlogger does not remove history. Space reclamation waits until capture stops."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Text("Space savings depend on the captured images, so Screenlogger measures the result after compression.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                model.automaticMaintenanceDeferredForPower
                    ? "Automatic compression is paused while this Mac conserves energy. Compress Now runs immediately."
                    : "Automatic compression waits on battery by default.",
                systemImage: model.automaticMaintenanceDeferredForPower
                    ? "leaf.fill" : "bolt.fill"
            )
            .font(.caption)
            .foregroundStyle(model.automaticMaintenanceDeferredForPower ? .orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings.storage.maintenance-power")

            StorageMaintenanceStatusView()
        }.padding(SLDesign.space16)
    }

    private var advancedActions: some View {
        DisclosureGroup(isExpanded: $showingAdvancedActions) {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "These actions remove capture media or complete moments. Screenlogger asks for confirmation before it deletes history."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        advancedActionButtons
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        advancedActionButtons
                    }
                }

                StorageDeletionStatusView()
            }
            .padding(.top, 10)
        } label: {
            Label("Advanced storage actions", systemImage: "gearshape.2")
                .font(.callout.weight(.medium))
        }.padding(SLDesign.space16)
            .accessibilityHint("Show deletion, limit enforcement, and the Library location")
            .accessibilityIdentifier("settings.storage.advanced-actions")
    }

    @ViewBuilder
    private var advancedActionButtons: some View {
        Menu {
            Button(action: reviewTodayDeletion) {
                Label("Today...", systemImage: "calendar")
            }
            Button(action: chooseDeletionRange) {
                Label("Time Range...", systemImage: "clock.arrow.2.circlepath")
            }
            Divider()
            Button(role: .destructive, action: reviewEntireLibraryDeletion) {
                Label("All History...", systemImage: "trash")
            }
        } label: {
            Label("Delete History...", systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .disabled(exclusiveOperationActive)
        .help("Review history before you delete it")
        .accessibilityIdentifier("settings.storage.delete-history")
    }

    private var backupButton: some View {
        Button {
            model.chooseLibraryExportDestination()
        } label: {
            Label("Back Up Library...", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.bordered)
        .disabled(exclusiveOperationActive)
        .help("Save a verified copy without moving or changing your current Library")
        .accessibilityHint("Choose where to save a verified copy of your Screenlogger Library")
        .accessibilityIdentifier("settings.storage.export")
    }

    private var restoreButton: some View {
        Button {
            model.chooseLibraryRestoreSource()
        } label: {
            Label("Restore from Backup...", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.bordered)
        .disabled(exclusiveOperationActive)
        .help("Review a verified Library backup before it replaces this Library")
        .accessibilityHint("Choose a Library backup for verification")
        .accessibilityIdentifier("settings.storage.restore")
    }

    private var exclusiveOperationActive: Bool {
        model.libraryExportState.isExporting
            || model.libraryRestoreState.isBusy
            || model.libraryRestoreReview != nil
            || model.storageMaintenanceInProgress
            || model.libraryDeletionInProgress
            || model.libraryDeletionReview != nil
    }
}

private struct StorageSectionHeading: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.callout.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
