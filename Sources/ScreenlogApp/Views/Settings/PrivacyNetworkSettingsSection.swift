import SwiftUI

struct PrivacyNetworkSettingsSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PrivacySettingsGroup("Network", systemImage: "network") {
            PrivacySettingsRow(
                icon: model.airgapMode ? "network.slash" : "network",
                iconColor: model.airgapMode ? SLDesign.success : .secondary,
                title: "Keep Screenlogger Offline",
                detail: model.airgapMode
                    ? "On. Screenlogger blocks optional network requests. Capture, text recognition, and search continue."
                    : "Off. Optional network access is available. Screenlogger gets website icons only if you enable them below."
            ) {
                Toggle("Keep Screenlogger Offline", isOn: $model.airgapMode)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Keep Screenlogger Offline")
                    .accessibilityValue(SettingsAccessibilityValue.onOff(model.airgapMode))
                    .accessibilityHint("When on, Screenlogger does not make optional network requests")
                    .accessibilityIdentifier("privacy.network.offline.toggle")
            }.padding(SLDesign.space16)

            PrivacySettingsDivider()

            PrivacySettingsRow(
                icon: "photo.badge.arrow.down",
                title: "Fetch Website Icons",
                detail: websiteIconDetail
            ) {
                Toggle("Fetch Website Icons", isOn: $model.remoteFaviconsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(model.airgapMode)
                    .accessibilityLabel("Fetch Website Icons")
                    .accessibilityValue(
                        SettingsAccessibilityValue.onOff(model.remoteFaviconsEnabled)
                    )
                    .accessibilityHint(websiteIconToggleHint)
                    .accessibilityIdentifier("privacy.network.website-icons.toggle")
            }.padding(SLDesign.space16)
        }
        .accessibilityIdentifier("privacy.network")
    }

    private var websiteIconDetail: String {
        if model.airgapMode {
            return "Offline mode blocks icon requests. Screenlogger does not send website domain names for icons."
        }
        if model.remoteFaviconsEnabled {
            return
                "On. Screenlogger sends displayed domains to the DuckDuckGo public icon service. Screenlogger does not send captures, recognized text, or full page addresses."
        }
        return "Off by default. Screenlogger uses only icons already cached on this Mac."
    }

    private var websiteIconToggleHint: String {
        if model.airgapMode {
            return "Unavailable while Keep Screenlogger Offline is on"
        }
        return "When on, Screenlogger sends website domain names to the DuckDuckGo public icon service"
    }
}
