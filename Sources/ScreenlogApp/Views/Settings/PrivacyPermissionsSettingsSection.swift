import ScreenlogCore
import SwiftUI

struct PrivacyPermissionsSettingsSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PrivacySettingsGroup("Permissions", systemImage: "checkmark.shield") {
            PrivacySettingsRow(
                icon: model.permissions.screenRecording ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                iconColor: model.permissions.screenRecording ? SLDesign.success : SLDesign.warning,
                title: "Screen Recording",
                detail: model.permissions.screenRecording
                    ? "Allowed. Screenlogger can capture the visible contents of one display."
                    : "Required before Screenlogger can save any screen captures."
            ) {
                if model.permissions.screenRecording {
                    PrivacyStatusLabel(text: "Allowed", systemImage: "checkmark")
                } else {
                    Button("Review Setup...") {
                        model.showPermissions(
                            origin: .settings,
                            preferredPermission: .screenRecording
                        )
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Review Screen Recording setup")
                    .accessibilityHint("Shows permission steps and a link to System Settings")
                }
            }.padding(SLDesign.space16)
                .accessibilityIdentifier("privacy.permission.screen-recording")

            PrivacySettingsDivider()

            PrivacySettingsRow(
                icon: model.permissions.accessibility
                    ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                iconColor: model.permissions.accessibility ? SLDesign.success : SLDesign.warning,
                title: "Accessibility",
                detail: accessibilityDetail
            ) {
                if model.permissions.accessibility {
                    PrivacyStatusLabel(text: "Allowed", systemImage: "checkmark")
                } else {
                    Button("Review Setup...") {
                        model.showPermissions(
                            origin: .settings,
                            preferredPermission: .accessibility
                        )
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Review Accessibility setup")
                    .accessibilityHint("Shows permission steps and a link to System Settings")
                }
            }.padding(SLDesign.space16)
                .accessibilityIdentifier("privacy.permission.accessibility")

        }
        .accessibilityIdentifier("privacy.permissions")
    }

    private var accessibilityDetail: String {
        if model.permissions.accessibility {
            return "Allowed for window titles, browser addresses, and focused-control text."
        }
        return "Required before capture starts so Screenlogger can apply exclusions and capture app context completely."
    }
}
