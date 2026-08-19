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
            subtitle: "Reveal the files Screenlogger manages on this Mac."
        ) {
            Button("Show in Finder") { model.openDataFolder() }
                .controlSize(.small)
                .accessibilityHint("Reveal Screenlogger's Library folder")
                .accessibilityIdentifier("settings.storage.reveal")
        }
        .padding(14)
    }

    private var backupAndRestoreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            StorageSectionHeading(
                title: "Backup & Restore",
                detail:
                    "Create a verified backup, or review one before it replaces your captured history. Settings and exclusions are not replaced."
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
        }
        .padding(14)
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

            Text("Space savings depend on the captured images, so Screenlogger measures the result after compression.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                model.automaticMaintenanceDeferredForPower
                    ? "Automatic compression is waiting for power. Compress Now runs immediately."
                    : "Automatic compression waits while this Mac is running on battery.",
                systemImage: model.automaticMaintenanceDeferredForPower
                    ? "battery.25percent" : "bolt.fill"
            )
            .font(.caption)
            .foregroundStyle(model.automaticMaintenanceDeferredForPower ? .orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings.storage.maintenance-power")

            StorageMaintenanceStatusView()
        }
        .padding(14)
    }

    private var advancedActions: some View {
        DisclosureGroup(isExpanded: $showingAdvancedActions) {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "These actions remove capture media or complete moments. Screenlogger shows a confirmation or detailed review before anything is deleted."
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
        }
        .padding(14)
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
        .help("Delete today, a time range, or all captured history after reviewing the impact")
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
        .help("Verify a Screenlogger Library backup, review it, then replace this Library")
        .accessibilityHint("Choose and verify a Library backup before reviewing a restore")
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
