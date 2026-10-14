import ScreenlogCore
import SwiftUI

/// A plain-language snapshot of what is stored and what automatic policy is active.
struct StorageOverviewCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsCardRow(
                    icon: "internaldrive",
                    title: "Library",
                    subtitle: "Current size, disk headroom, and growth at a glance."
                ) {
                    if model.storageMeasurementState.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Refreshing storage information")
                    } else {
                        Button {
                            model.refreshLibrarySize()
                        } label: {
                            Label("Refresh storage information", systemImage: "arrow.clockwise")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .slCompactControlTarget()
                        .help("Refresh storage information")
                        .accessibilityIdentifier("settings.storage.refresh-size")
                        .accessibilityHint("Recalculate Library size and available disk space")
                    }
                }.padding(SLDesign.space16)

                Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                VStack(spacing: 0) {
                    ForEach(Array(metrics.enumerated()), id: \.element.label) { index, metric in
                        LabeledContent(metric.label) {
                            Text(metric.value)
                                .font(.body.weight(.semibold).monospacedDigit())
                        }.padding(.horizontal, SLDesign.space16)
                            .padding(.vertical, 9)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(metric.label), \(metric.value)")

                        if index < metrics.count - 1 {
                            Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
                        }
                    }
                }

                Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                VStack(alignment: .leading, spacing: 7) {
                    if forecastIsActionable {
                        Label(forecastSummary, systemImage: forecastSystemImage)
                    }
                    Label(lastRefreshSummary, systemImage: "clock")
                    if case .failed = model.storageMeasurementState {
                        Label(
                            "Storage information could not be refreshed. The previous measurement is still shown.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(SLDesign.warning)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(SLDesign.space16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.storage.summary")
    }

    private var metrics: [(value: String, label: String)] {
        [
            (
                measurement.map { AppModel.formatByteSize($0.libraryBytes) } ?? "-",
                "Space used"
            ),
            (
                measurement.flatMap(\.availableBytes).map { AppModel.formatByteSize($0) } ?? "-",
                "Available on Mac"
            ),
            (savedMomentsValue, "Saved moments"),
        ]
    }

    private var savedMomentsValue: String {
        guard let stats = model.stats else { return "-" }
        return stats.momentCount.formatted()
    }

    private var measurement: StorageMeasurement? {
        model.storageMeasurementState.measurement
    }

    private var lastRefreshSummary: String {
        guard let measuredAt = measurement?.measuredAt else {
            return model.storageMeasurementState.isLoading
                ? "Measuring storage..."
                : "Storage has not been measured yet"
        }
        return "Last refreshed " + measuredAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var forecast: StorageLimitForecast {
        StorageLimitForecast.make(
            mode: model.storageMode,
            storageCapMB: model.storageCapMB,
            measurement: measurement
        )
    }

    private var forecastSummary: String {
        switch forecast {
        case .automaticCleanupOff:
            return "No automatic storage limit is active"
        case .compressionOnly:
            return "Compression reduces growth without a fixed size target"
        case .ageLimitOnly:
            return "The age limit is active. No Library size limit is set."
        case .needsGrowthHistory:
            return "Size forecast needs measurements at least 15 minutes apart"
        case .stableOrShrinking:
            return "No approach to the size limit is forecast from recent change"
        case .atOrAboveLimit(let bytes):
            if bytes == 0 { return "The Library is at its current size limit" }
            return "The Library is " + AppModel.formatByteSize(bytes) + " over its current size limit"
        case .estimatedTimeToLimit(let interval):
            return "Estimated " + Self.forecastDuration(interval) + " until the current size limit"
        }
    }

    private var forecastSystemImage: String {
        switch forecast {
        case .atOrAboveLimit: return "exclamationmark.circle"
        case .estimatedTimeToLimit: return "chart.line.uptrend.xyaxis"
        case .stableOrShrinking: return "checkmark.circle"
        default: return "gauge.with.dots.needle.50percent"
        }
    }

    private var forecastIsActionable: Bool {
        switch forecast {
        case .atOrAboveLimit, .estimatedTimeToLimit: return true
        default: return false
        }
    }

    private static func forecastDuration(_ interval: TimeInterval) -> String {
        let rawDays = interval / 86_400
        guard rawDays < Double(Int.max) else { return "many years" }
        let days = max(0, Int(rawDays))
        if days < 1 { return "less than a day" }
        if days < 14 { return "about \(days) days" }
        if days < 60 { return "about \(max(2, days / 7)) weeks" }
        return "about \(max(2, days / 30)) months"
    }

}
