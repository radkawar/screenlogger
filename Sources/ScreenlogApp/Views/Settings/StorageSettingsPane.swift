import ScreenlogCore
import SwiftUI

/// Coordinates Screenlogger's local Library storage journey.
///
/// The cards own their presentation while this view owns modal navigation, so
/// backup, restore, and deletion cannot accidentally present competing sheets.
struct StorageSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingRangePicker = false
    @State private var showingLimitConfirmation = false
    @State private var showingAdvancedActions = false
    @State private var pendingDeletionReview: PendingDeletionReview?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.cardSpacing) {
            StorageOverviewCard()
                .settingsDestinationAnchor(.storageOverview)
            StorageManagementCard(
                applyLimits: {
                    model.refreshStorageCleanupPreflight()
                    showingLimitConfirmation = true
                }
            )
            .settingsDestinationAnchor(.storageManagement)
            StorageLibraryToolsCard(
                showingAdvancedActions: $showingAdvancedActions,
                reviewTodayDeletion: reviewTodayDeletion,
                chooseDeletionRange: { showingRangePicker = true },
                reviewEntireLibraryDeletion: reviewEntireLibraryDeletion
            )
            .settingsDestinationAnchor(.storageLibraryTools)
        }
        .onAppear { model.refreshLibrarySize() }
        .task(id: storagePreflightRefreshID) {
            guard model.storageMode == .limit else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            model.refreshStorageCleanupPreflight()
        }
        .confirmationDialog(
            "Apply Storage Limits Now?",
            isPresented: $showingLimitConfirmation,
            titleVisibility: .visible
        ) {
            Button("Apply Limits", role: .destructive) {
                model.retentionNow()
            }
            .disabled(currentPreflight == nil && isPreflightLoading)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(applyLimitsConfirmationMessage)
        }
        .sheet(
            isPresented: $showingRangePicker,
            onDismiss: beginPendingDeletionReview
        ) {
            LibraryDeletionRangeSheet { selection, title, detail in
                pendingDeletionReview = PendingDeletionReview(
                    selection: selection,
                    title: title,
                    detail: detail
                )
            }
        }
        .sheet(
            item: storageDeletionReview,
            onDismiss: {
                model.cancelLibraryDeletionReview()
            }
        ) { review in
            LibraryDeletionReviewSheet(
                review: review,
                isDeleting: model.libraryDeletionInProgress,
                issue: reviewDeletionIssue,
                onDelete: { Task { await model.confirmLibraryDeletion() } },
                onCancel: { model.cancelLibraryDeletionReview() }
            )
        }
        .sheet(
            item: $model.libraryRestoreReview,
            onDismiss: {
                model.cancelLibraryRestoreReview()
            }
        ) { review in
            LibraryRestoreReviewSheet(review: review)
                .environmentObject(model)
        }
    }

    private var applyLimitsConfirmationMessage: String {
        let policyDescription =
            model.storageCapMB > 0
            ? "older than \(model.retentionDays) days or beyond the \(StorageSizeInput.formattedCap(model.storageCapMB)) size limit"
            : "older than \(model.retentionDays) days"
        var impact: String
        if let report = currentPreflight {
            let measuredCount = max(0, report.selectedMediaCount - report.unavailableMediaCount)
            if report.selectedMediaCount == 0 {
                impact = "The current estimate finds no capture media beyond these limits."
            } else {
                let noun = measuredCount == 1 ? "item" : "items"
                let reclaimed =
                    report.estimatedReclaimableBytes > 0
                    ? ", reclaiming about \(AppModel.formatByteSize(report.estimatedReclaimableBytes))"
                    : ""
                impact = "The current estimate covers about \(measuredCount) media \(noun)\(reclaimed)."
            }
            if model.storageCleanupPreflightState.isLoading {
                impact += " Screenlogger is updating this estimate."
            } else if model.storageCleanupPreflightState.refreshFailed {
                impact += " This is the last available estimate because the latest refresh failed."
            }
        } else if isPreflightLoading {
            impact = "Screenlogger is still calculating the current scope."
        } else {
            impact = "A current cleanup estimate is unavailable."
        }
        return
            "\(impact) Applying limits permanently removes capture media \(policyDescription). "
            + "Searchable text, app names, and timestamps remain. The estimate can change if capture continues."
    }

    private var policyFingerprint: StoragePolicyFingerprint {
        StoragePolicyFingerprint(
            retentionDays: model.retentionDays,
            storageCapMB: model.storageCapMB
        )
    }

    private var currentPreflight: RetentionPreflightReport? {
        model.storageCleanupPreflightState.currentReport(for: policyFingerprint)
    }

    private var isPreflightLoading: Bool {
        model.storageCleanupPreflightState.isLoading
    }

    private var storagePreflightRefreshID: String {
        "\(model.storageMode.rawValue):\(model.retentionDays):\(model.storageCapMB)"
    }

    private var reviewDeletionIssue: LibraryDeletionIssue? {
        guard let issue = model.libraryDeletionIssue,
            issue.origin == .storage,
            case .deletionFailed = issue
        else { return nil }
        return issue
    }

    private var storageDeletionReview: Binding<LibraryDeletionReview?> {
        Binding(
            get: {
                guard model.libraryDeletionReview?.origin == .storage else { return nil }
                return model.libraryDeletionReview
            },
            set: { review in
                if review == nil { model.cancelLibraryDeletionReview() }
            }
        )
    }

    private func beginPendingDeletionReview() {
        guard let pendingDeletionReview else { return }
        self.pendingDeletionReview = nil
        Task {
            await model.prepareLibraryDeletion(
                pendingDeletionReview.selection,
                origin: .storage,
                title: pendingDeletionReview.title,
                detail: pendingDeletionReview.detail
            )
        }
    }

    private func reviewTodayDeletion() {
        let now = Date()
        Task {
            await model.prepareLibraryDeletion(
                .today(containing: now),
                origin: .storage,
                title: "Delete Today's History?",
                detail: "All moments captured on \(Self.dayFormatter.string(from: now))."
            )
        }
    }

    private func reviewEntireLibraryDeletion() {
        Task {
            await model.prepareLibraryDeletion(
                .entireLibrary,
                origin: .storage,
                title: "Delete All History?",
                detail: "Every captured moment in your Screenlogger Library. Your settings and exclusions will remain."
            )
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()
}

private struct PendingDeletionReview {
    let selection: LibraryDeletionSelection
    let title: String
    let detail: String
}
