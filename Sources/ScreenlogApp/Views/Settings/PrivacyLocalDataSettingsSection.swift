import ScreenlogCore
import SwiftUI

struct PrivacyLocalDataSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var showsLibraryLocation = false

    let openStorage: () -> Void

    var body: some View {
        PrivacySettingsGroup("Library Data", systemImage: "internaldrive") {
            PrivacySettingsRow(
                icon: "folder",
                title: "Screenlogger Library",
                detail: "Screenlogger stores captures, recognized text, and search data in this folder."
            ) {
                Button("Show in Finder") { model.openDataFolder() }
                    .controlSize(.small)
                    .accessibilityHint("Opens the Screenlogger Library folder in Finder")
                    .accessibilityIdentifier("privacy.library.reveal")
            }.padding(SLDesign.space16)

            DisclosureGroup("Show Library location", isExpanded: $showsLibraryLocation) {
                Text(model.libraryRootPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityLabel("Library location, \(model.libraryRootPath)")
            }
            .font(.caption).padding(.horizontal, SLDesign.space16)
            .padding(.bottom, 12)
            .accessibilityIdentifier("privacy.library.location")

            PrivacySettingsDivider()

            PrivacySettingsRow(
                icon: "externaldrive.badge.timemachine",
                title: "Retention and Disk Use",
                detail: storageSummary
            ) {
                Button("Storage Settings...", action: openStorage)
                    .controlSize(.small)
                    .accessibilityHint("Shows Library size and retention settings")
                    .accessibilityIdentifier("privacy.storage.open")
            }.padding(SLDesign.space16)
        }
        .accessibilityIdentifier("privacy.local-data")
    }

    private var storageSummary: String {
        let usage =
            model.storageMeasurementState.measurement.map {
                "Using about \(AppModel.formatByteSize($0.libraryBytes)). "
            } ?? ""
        switch model.storageMode {
        case .off:
            return "\(usage)History is kept until you remove it."
        case .compress:
            return "\(usage)Older captures are compressed automatically."
        case .limit:
            let sizeLimit =
                model.storageCapMB > 0
                ? " or when the Library approaches \(AppModel.formatByteSize(model.storageCapMB * 1_000_000))"
                : ""
            return
                "\(usage)Screenlogger removes capture media after \(model.retentionDays) days\(sizeLimit). Searchable text remains."
        }
    }
}
