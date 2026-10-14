import ScreenlogCore
import SwiftUI

// MARK: - General

struct GeneralSettingsPane: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.cardSpacing) {
            SettingsCard(padding: 0) {
                VStack(spacing: 0) {
                    SettingsCardRow(
                        icon: "power.circle",
                        title: "Open at Login",
                        subtitle: launchSubtitle
                    ) {
                        HStack(spacing: 8) {
                            if model.launchAtLoginState.isBusy {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityHidden(true)
                            }
                            Toggle(
                                "Open at Login",
                                isOn: Binding(
                                    get: { model.launchAtLoginState.isEnabled },
                                    set: { model.setLaunchAtLogin($0) }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .disabled(model.launchAtLoginState.isBusy)
                            .accessibilityLabel("Open at Login")
                            .accessibilityValue(
                                SettingsAccessibilityValue.onOff(
                                    model.launchAtLoginState.isEnabled
                                )
                            )
                            .accessibilityHint(launchAccessibilityHint)
                            .accessibilityIdentifier("settings.general.open-at-login.toggle")
                        }
                    }.padding(SLDesign.space16)

                    Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                    SettingsCardRow(
                        icon: "dock.rectangle",
                        title: "Show Dock Icon",
                        subtitle: dockSubtitle
                    ) {
                        Toggle("Show Dock Icon", isOn: $model.showDockIcon)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Show Dock Icon")
                            .accessibilityValue(
                                SettingsAccessibilityValue.onOff(model.showDockIcon)
                            )
                            .accessibilityHint(
                                model.showDockIcon
                                    ? "Hide Screenlogger from the Dock and keep it in the menu bar"
                                    : "Show Screenlogger in the Dock as well as the menu bar"
                            )
                            .accessibilityIdentifier("settings.general.dock-icon.toggle")
                    }.padding(SLDesign.space16)
                }
            }
            .accessibilityIdentifier("settings.general.startup")

            launchAtLoginRecovery
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            model.refreshLaunchAtLoginState()
        }
    }

    private var dockSubtitle: String {
        model.showDockIcon
            ? "Screenlogger appears in both the Dock and menu bar."
            : "Screenlogger stays in the menu bar. Library, Timeline, and Settings still open normally."
    }

    private var launchSubtitle: String {
        switch model.launchAtLoginState {
        case .ready(let isEnabled):
            return isEnabled
                ? "Screenlogger will open automatically when you log in to this Mac."
                : "Start Screenlogger automatically when you log in to this Mac."
        case .enabling:
            return "Asking macOS to turn on Open at Login..."
        case .disabling:
            return "Asking macOS to turn off Open at Login..."
        case .approvalRequired:
            return "Off until you approve Screenlogger in Login Items."
        case .failed(_, let isEnabled, let issue):
            switch issue {
            case .registrationFailed:
                return "Still off because macOS could not turn it on."
            case .removalFailed where isEnabled:
                return "Still on because macOS could not turn it off."
            case .removalFailed:
                return "Off, but the Login Items entry still needs attention."
            case .serviceUnavailable:
                return "Off because the login item service is unavailable."
            }
        }
    }

    private var launchAccessibilityHint: String {
        if model.launchAtLoginState.isBusy {
            return "Wait while macOS updates Screenlogger's login item"
        }
        return model.launchAtLoginState.isEnabled
            ? "Turn off automatic launch after login"
            : "Ask macOS to start Screenlogger automatically after login"
    }

    @ViewBuilder
    private var launchAtLoginRecovery: some View {
        switch model.launchAtLoginState {
        case .approvalRequired:
            launchRecoveryCard(
                title: "Approval Needed",
                message: "Open Login Items in System Settings. Allow Screenlogger. The switch stays off until macOS reports approval.",
                layout: .approvalRequired
            )
        case .failed(_, let isEnabled, let issue):
            launchRecoveryCard(
                title: launchFailureTitle(issue: issue),
                message: launchFailureMessage(issue: issue, isEnabled: isEnabled),
                layout: .operationFailed(retryTitle: "Try Again")
            )
        case .ready, .enabling, .disabling:
            EmptyView()
        }
    }

    private func launchRecoveryCard(
        title: String,
        message: String,
        layout: LaunchAtLoginRecoveryLayout
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SLDesign.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        launchRecoveryButtons(
                            layout: layout
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        launchRecoveryButtons(
                            layout: layout
                        )
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            SLDesign.warning.opacity(0.08),
            in: RoundedRectangle(cornerRadius: SettingsChrome.cardRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsChrome.cardRadius)
                .strokeBorder(SLDesign.warning.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.general.open-at-login.issue")
    }

    @ViewBuilder
    private func launchRecoveryButtons(
        layout: LaunchAtLoginRecoveryLayout
    ) -> some View {
        ForEach(Array(layout.actions.enumerated()), id: \.offset) { index, action in
            launchRecoveryButton(action, isPrimary: index == 0)
        }
    }

    @ViewBuilder
    private func launchRecoveryButton(
        _ action: LaunchAtLoginRecoveryAction,
        isPrimary: Bool
    ) -> some View {
        switch action {
        case .openLoginItems:
            openLoginItemsButton(isPrimary: isPrimary)
        case .retry(let title):
            retryLaunchAtLoginButton(title: title, isPrimary: isPrimary)
        case .keepOff:
            Button("Keep Off") { model.setLaunchAtLogin(false) }
                .controlSize(.small)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityHint("Remove the pending login item request")
                .accessibilityIdentifier("settings.general.open-at-login.keep-off")
        }
    }

    @ViewBuilder
    private func retryLaunchAtLoginButton(title: String, isPrimary: Bool) -> some View {
        if isPrimary {
            Button(title) { model.retryLaunchAtLogin() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("settings.general.open-at-login.retry")
        } else {
            Button(title) { model.retryLaunchAtLogin() }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings.general.open-at-login.retry")
        }
    }

    @ViewBuilder
    private func openLoginItemsButton(isPrimary: Bool) -> some View {
        if isPrimary {
            Button("Open Login Items...") { model.openLoginItemsSettings() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Open Login Items in macOS System Settings")
                .accessibilityIdentifier("settings.general.open-at-login.system-settings")
        } else {
            Button("Open Login Items...") { model.openLoginItemsSettings() }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .accessibilityHint("Open Login Items in macOS System Settings")
                .accessibilityIdentifier("settings.general.open-at-login.system-settings")
        }
    }

    private func launchFailureTitle(issue: LaunchAtLoginIssue) -> String {
        switch issue {
        case .registrationFailed: return "Could Not Turn On Open at Login"
        case .removalFailed: return "Could Not Turn Off Open at Login"
        case .serviceUnavailable: return "Open at Login Is Unavailable"
        }
    }

    private func launchFailureMessage(issue: LaunchAtLoginIssue, isEnabled: Bool) -> String {
        switch issue {
        case .registrationFailed:
            return "macOS did not enable Screenlogger. The switch remains off. Try again or review Login Items in System Settings."
        case .removalFailed where isEnabled:
            return "macOS did not disable Screenlogger. The switch remains on. Try again or turn it off in Login Items."
        case .removalFailed:
            return
                "Screenlogger is off, but macOS could not remove its Login Items entry. Try again or review it in System Settings."
        case .serviceUnavailable:
            return
                "macOS could not find the Screenlogger login item service. Keep Screenlogger in Applications. Open it again. Then try again."
        }
    }
}
