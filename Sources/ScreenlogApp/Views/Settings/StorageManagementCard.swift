import ScreenlogCore
import SwiftUI

/// Automatic storage behavior and the limits that feed the capture engine.
struct StorageManagementCard: View {
    @EnvironmentObject private var model: AppModel
    let applyLimits: () -> Void

    var body: some View {
        SettingsCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsCardRow(
                    icon: "gauge.with.dots.needle.50percent",
                    title: "Automatic Storage",
                    subtitle: "Choose what Screenlogger should do as your Library grows."
                ) {
                    EmptyView()
                }.padding(SLDesign.space16)

                Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                VStack(alignment: .leading, spacing: 12) {
                    Picker("Automatic storage", selection: $model.storageMode) {
                        Text("Keep all history").tag(StorageManagementMode.off)
                        Text("Compress older captures").tag(StorageManagementMode.compress)
                        Text("Limit storage use").tag(StorageManagementMode.limit)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .accessibilityHint("Choose how Screenlogger manages the Library over time")
                    .accessibilityIdentifier("settings.storage.strategy")

                    Text(storageModeHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(SLDesign.space16)

                if model.storageMode == .limit {
                    Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Remove capture media after") {
                            HStack(spacing: 6) {
                                TextField("Days", value: retentionDays, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 72)
                                    .multilineTextAlignment(.trailing)
                                    .accessibilityLabel("Days to keep capture media")
                                Text("days")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        LabeledContent("Library size limit") {
                            HStack(spacing: 6) {
                                TextField(
                                    "Gigabytes",
                                    value: storageCapGB,
                                    format: .number.precision(.fractionLength(0...1))
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                                .accessibilityLabel("Library size limit in gigabytes")
                                Text("GB")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Label(storageCapHelp, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Label(limitConsequenceSummary, systemImage: limitConsequenceSystemImage)
                            .font(.caption)
                            .foregroundStyle(
                                limitConsequenceIsWarning ? SLDesign.warning : .secondary
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.storage.limit-consequence")

                        Button("Apply Limits Now", action: applyLimits)
                            .buttonStyle(.bordered)
                            .disabled(exclusiveOperationActive)
                            .accessibilityHint(
                                "Review permanent removal of capture media beyond the current limits"
                            )
                            .accessibilityIdentifier("settings.storage.apply-limits")
                    }.padding(SLDesign.space16)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("settings.storage.limits")
                }
            }
        }
    }

    private var retentionDays: Binding<Int> {
        Binding(
            get: { model.retentionDays },
            set: { model.retentionDays = max(1, $0) }
        )
    }

    private var storageCapGB: Binding<Double> {
        Binding(
            get: { Double(model.storageCapMB) / 1_000 },
            set: { value in
                if let megabytes = StorageSizeInput.megabytes(fromGigabytes: value) {
                    model.storageCapMB = megabytes
                }
            }
        )
    }

    private var storageCapHelp: String {
        if model.storageCapMB <= 0 {
            return "A 0 GB size limit uses the age limit only. Screenlogger removes the oldest media first. Searchable history remains."
        }
        return "Screenlogger applies the first limit it reaches. Screenlogger removes the oldest media first. Searchable history remains."
    }

    private var storageModeHelp: String {
        switch model.storageMode {
        case .off:
            return "Keeps all history until you remove it."
        case .compress:
            return "Turns eligible older capture images into video while preserving the moments in your Library."
        case .limit:
            return "Screenlogger removes capture media at its age or size limit. Text, app names, and timestamps remain searchable."
        }
    }

    private var policyFingerprint: StoragePolicyFingerprint {
        StoragePolicyFingerprint(
            retentionDays: model.retentionDays,
            storageCapMB: model.storageCapMB
        )
    }

    private var exclusiveOperationActive: Bool {
        model.libraryExportState.isExporting
            || model.libraryRestoreState.isBusy
            || model.libraryRestoreReview != nil
            || model.storageMaintenanceInProgress
            || model.libraryDeletionInProgress
            || model.libraryDeletionReview != nil
    }

    private var currentPreflight: RetentionPreflightReport? {
        model.storageCleanupPreflightState.currentReport(for: policyFingerprint)
    }

    private var limitConsequenceSummary: String {
        if let report = currentPreflight {
            if report.selectedMediaCount == 0 {
                return "The current Library is within these limits. Applying them now would remove no capture media."
            }
            let measuredCount = max(0, report.selectedMediaCount - report.unavailableMediaCount)
            let itemLabel = measuredCount == 1 ? "item" : "items"
            var summary =
                "Based on the current Library, applying these limits would remove about \(measuredCount) media \(itemLabel)"
            if report.estimatedReclaimableBytes > 0 {
                summary += " and reclaim about \(AppModel.formatByteSize(report.estimatedReclaimableBytes))"
            }
            summary += ". Searchable text, app names, and timestamps remain."
            if report.unavailableMediaCount > 0 {
                summary += " \(report.unavailableMediaCount) additional media item(s) could not be measured and may be kept."
            }
            if report.capSatisfiedAfterEstimate == false {
                summary += " Removing managed capture media may not be enough to reach the size limit."
            }
            if model.storageCleanupPreflightState.isLoading {
                summary += " Refreshing this estimate..."
            } else if model.storageCleanupPreflightState.refreshFailed {
                summary += " This is the last available estimate. The latest refresh failed."
            }
            return summary
        }
        switch model.storageCleanupPreflightState {
        case .loading:
            return "Calculating what the current limits would remove..."
        case .failed:
            return "A cleanup estimate is unavailable. Screenlogger will show the exact result after it applies the limits."
        case .idle, .available:
            return "Screenlogger will calculate the current cleanup scope before you apply these limits."
        }
    }

    private var limitConsequenceIsWarning: Bool {
        if model.storageCleanupPreflightState.refreshFailed { return true }
        return currentPreflight?.capSatisfiedAfterEstimate == false
            || (currentPreflight?.unavailableMediaCount ?? 0) > 0
    }

    private var limitConsequenceSystemImage: String {
        if model.storageCleanupPreflightState.isLoading, currentPreflight == nil {
            return "hourglass"
        }
        return limitConsequenceIsWarning ? "exclamationmark.triangle" : "checkmark.circle"
    }
}

/// Keeps editable size values inside the range the rest of the app can safely
/// convert to bytes for display and retention calculations.
enum StorageSizeInput {
    private static let maximumMegabytes = Int64.max / 1_000_000

    static func megabytes(fromGigabytes value: Double) -> Int64? {
        guard value.isFinite else { return nil }
        let maximumGigabytes = Double(maximumMegabytes) / 1_000
        let gigabytes = min(max(0, value), maximumGigabytes)
        return Int64((gigabytes * 1_000).rounded(.towardZero))
    }

    @MainActor
    static func formattedCap(_ megabytes: Int64) -> String {
        let nonnegativeMegabytes = max(0, megabytes)
        let bytes = nonnegativeMegabytes.multipliedReportingOverflow(by: 1_000_000)
        return AppModel.formatByteSize(bytes.overflow ? Int64.max : bytes.partialValue)
    }
}
