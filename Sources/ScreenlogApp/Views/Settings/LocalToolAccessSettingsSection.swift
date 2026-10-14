import AppKit
import ScreenlogCore
import SwiftUI

/// Presents command access in decision order: overall state, the common setup
/// actions, then optional implementation details.
struct LocalToolAccessSettingsSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var model: AppModel
    @State private var showingDetails = false
    @State private var showingVerifiedDetails = false
    @State private var pathSetupCopied = false

    let refresh: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.cardSpacing) {
            readinessOverview
            if isReady {
                verifiedCommandDetails
            } else {
                setupActions
                technicalDetails
            }
        }
        .onChange(of: model.cliCommandAvailability) { _, _ in
            pathSetupCopied = false
        }
    }

    private var readinessOverview: some View {
        SettingsCard {
            HStack(alignment: .top, spacing: SLDesign.space16) {
                Image(
                    systemName:
                        isReady
                        ? "checkmark.circle"
                        : "point.3.connected.trianglepath.dotted"
                )
                .font(SLDesign.bodyFont)
                .foregroundStyle(.secondary)
                .frame(width: SettingsChrome.iconSize)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: SLDesign.space4) {
                    Text(title)
                        .font(SLDesign.bodyFont.weight(.medium))
                    Text(detail)
                        .font(SLDesign.metadataFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !isReady {
                        readinessLabels
                            .padding(.top, SLDesign.space4)
                    }
                }

                Spacer(minLength: 8)

                Button(action: refresh) {
                    if model.integrationRefreshIsActive {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .controlSize(.small)
                .disabled(model.integrationRefreshIsActive)
                .accessibilityLabel(
                    model.integrationRefreshIsActive
                        ? "Refreshing integration status"
                        : "Refresh integration status"
                )
                .accessibilityIdentifier("settings.integrations.refresh")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.integrations.readiness")
        }
    }

    private var setupActions: some View {
        SettingsCard(padding: 0) {
            VStack(spacing: 0) {
                connectionRow.padding(SLDesign.space16)

                Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                commandRow.padding(SLDesign.space16)

                Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                verificationRow.padding(SLDesign.space16)

                Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                mutationAccessRow.padding(SLDesign.space16)
            }
        }
    }

    private var verificationRow: some View {
        SettingsCardRow(
            icon: verificationIcon,
            iconColor: verificationColor,
            title: "Command verification",
            subtitle: verificationDescription
        ) {
            if model.assistantLiveVerificationIsRunning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Verifying the Terminal command")
            } else if verificationPrerequisitesAreReady {
                Button(verificationActionTitle) {
                    model.checkAssistantLiveVerification()
                }
                .controlSize(.small)
                .accessibilityHint(
                    "Runs the managed screenlog command against this app without sending history off this Mac"
                )
                .accessibilityIdentifier("settings.integrations.verify")
            }
        }
    }

    private var connectionRow: some View {
        SettingsCardRow(
            icon: "terminal",
            iconColor: connectionStatusColor,
            title: "Command Access",
            subtitle: connectionDescription
        ) {
            HStack(spacing: 8) {
                if model.cliEnabled,
                    case .unavailable = model.cliBridgeState
                {
                    Button("Retry") { model.retryCLIBridge() }
                        .controlSize(.small)
                        .accessibilityHint("Retries Command Access")
                        .accessibilityIdentifier("settings.integrations.cli.retry")
                }
                Toggle("Enable Command Access", isOn: $model.cliEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Enable Command Access")
                    .accessibilityValue(SettingsAccessibilityValue.onOff(model.cliEnabled))
                    .accessibilityHint(
                        "Allow Terminal and configured assistants to query Screenlogger while it is running"
                    )
                    .accessibilityIdentifier("settings.integrations.connection.toggle")
            }
        }
    }

    private var commandRow: some View {
        SettingsCardRow(
            icon: "shippingbox",
            title: "Terminal command",
            subtitle: commandDescription
        ) {
            if model.cliInstallState.recoveryDirectory != nil {
                Button("Show Recovery Files") {
                    model.revealCLIRecoveryDirectory()
                }
                .controlSize(.small)
                .accessibilityHint(
                    "Reveals the command files Screenlogger preserved for manual recovery"
                )
                .accessibilityIdentifier("settings.integrations.cli.show-recovery")
            } else if model.cliInstallState.conflict != nil {
                Button("Show Files") {
                    model.revealCLIInstallConflict()
                }
                .controlSize(.small)
                .accessibilityHint("Reveals the files Screenlogger preserved")
                .accessibilityIdentifier("settings.integrations.cli.showFiles")
            } else {
                HStack(spacing: 8) {
                    if model.cliInstallState.isReady,
                        !model.cliCommandAvailability.isAvailable
                    {
                        Button {
                            model.checkCLICommandAvailability()
                        } label: {
                            if model.cliCommandAvailability.isChecking {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(pathCheckActionTitle)
                            }
                        }
                        .controlSize(.small)
                        .disabled(model.cliCommandAvailability.isChecking)
                        .accessibilityHint(
                            "Runs your login shell without changing its files to check whether it can find screenlog"
                        )
                        .accessibilityIdentifier("settings.integrations.cli.check-path")
                    }

                    if let setup = pathSetup,
                        model.cliInstallState.isReady,
                        pathNeedsSetup
                    {
                        Button {
                            copyPathSetup(setup)
                        } label: {
                            Label(
                                pathSetupCopied ? "Copied" : "Copy PATH Setup",
                                systemImage: pathSetupCopied ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .controlSize(.small)
                        .accessibilityHint(
                            "Copies a command you can paste into Terminal to make screenlog available in \(setup.shellName)"
                        )
                        .accessibilityIdentifier("settings.integrations.cli.copy-path-setup")
                    }

                    if !commandVerificationIsUnavailable, !model.cliInstallState.isReady {
                        Button {
                            model.installCLIToLocalBin()
                        } label: {
                            if model.cliInstallState.isBusy {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(minWidth: 58)
                            } else {
                                Text(commandActionTitle)
                            }
                        }
                        .controlSize(.small)
                        .disabled(model.cliInstallState.isBusy)
                        .accessibilityLabel(commandActionAccessibilityLabel)
                        .accessibilityIdentifier("settings.integrations.cli.install")
                    }

                    if model.cliInstallState.canRemove {
                        Button("Remove...", action: onRemove)
                            .controlSize(.small)
                            .disabled(model.cliInstallState.isBusy)
                            .accessibilityHint(
                                "Removes Screenlogger's managed Terminal command after confirmation"
                            )
                            .accessibilityIdentifier("settings.integrations.cli.remove")
                    }
                }
            }
        }
    }

    private var mutationAccessRow: some View {
        SettingsCardRow(
            icon: model.localToolCaptureControlAndMaintenanceEnabled ? "lock.open" : "lock",
            iconColor:
                model.localToolCaptureControlAndMaintenanceEnabled
                ? SLDesign.warning
                : .secondary,
            title: "Allow capture control and maintenance",
            subtitle: mutationAccessDescription
        ) {
            Toggle(
                "Allow capture control and maintenance",
                isOn: $model.localToolCaptureControlAndMaintenanceEnabled
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel("Allow capture control and maintenance")
            .accessibilityValue(
                SettingsAccessibilityValue.onOff(
                    model.localToolCaptureControlAndMaintenanceEnabled
                )
            )
            .accessibilityHint(mutationAccessDescription)
            .accessibilityIdentifier("settings.integrations.mutation-access.toggle")
        }
    }

    private var technicalDetails: some View {
        DisclosureGroup(isExpanded: $showingDetails) {
            commandTechnicalDetails
                .padding(.top, 6)
        } label: {
            Label("How Command Access works", systemImage: "info.circle")
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 4)
        .accessibilityHint(
            "Show technical details about Command Access and the screenlog command"
        )
        .accessibilityIdentifier("settings.integrations.local-access.details")
    }

    private var verifiedCommandDetails: some View {
        DisclosureGroup(isExpanded: $showingVerifiedDetails) {
            VStack(alignment: .leading, spacing: SettingsChrome.cardSpacing) {
                testSearchCard
                setupActions
                commandTechnicalDetails
            }
            .padding(.top, 8)
        } label: {
            Label("Command Access details", systemImage: "terminal")
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 4)
        .accessibilityHint(
            showingVerifiedDetails
                ? "Hide Terminal command and Command Access controls"
                : "Show Terminal command and Command Access controls"
        )
        .accessibilityIdentifier("settings.integrations.verified-command-details")
    }

    private var testSearchCard: some View {
        SettingsCard(padding: 0) {
            SettingsCardRow(
                icon: testSearchIcon,
                iconColor: testSearchColor,
                title: "Test Library Search",
                subtitle: testSearchDescription
            ) {
                if model.assistantTestSearchIsRunning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Testing a read-only Library search")
                } else {
                    Button(testSearchActionTitle) {
                        model.runAssistantTestSearch()
                    }
                    .controlSize(.small)
                    .accessibilityHint(
                        "Runs one read-only search and reports only its result count and timing"
                    )
                    .accessibilityIdentifier("settings.integrations.test-search")
                }
            }.padding(SLDesign.space16)
        }
        .accessibilityIdentifier("settings.integrations.test-search-card")
    }

    private var commandTechnicalDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "Screenlogger handles searches inside the app. Terminal and assistants connect privately only while Screenlogger is running."
            )
            Text(commandTechnicalDetail)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var testSearchDescription: String {
        if model.assistantTestSearchIsRunning {
            return "Running one read-only search against this Screenlogger Library..."
        }
        guard let outcome = model.assistantTestSearchOutcome else {
            return
                "Run the same local search path connected assistants use. Screenlogger reports only the count and timing, then discards the result."
        }
        switch outcome {
        case .succeeded(let result):
            let noun = result.resultCount == 1 ? "result" : "results"
            return
                "Search completed with \(result.resultCount) \(noun) in \(result.latencyMilliseconds) ms. Screenlogger discarded the result content."
        case .failed(.commandUnavailable):
            return "The managed command is unavailable. Refresh Command Setup. Then test again."
        case .failed(.commandFailed):
            return "The command could not search this Library. Retry Command Access. Then test again."
        case .failed(.timedOut):
            return "The search did not finish within 10 seconds. Keep Screenlogger open. Test again."
        case .failed(.invalidResponse):
            return "The command returned an unexpected response. Reinstall the managed command. Then test again."
        }
    }

    private var testSearchActionTitle: String {
        model.assistantTestSearchOutcome == nil ? "Test Search" : "Test Again"
    }

    private var testSearchIcon: String {
        if model.assistantTestSearchIsRunning { return "clock" }
        switch model.assistantTestSearchOutcome {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case nil: return "magnifyingglass"
        }
    }

    private var testSearchColor: Color {
        if model.assistantTestSearchIsRunning { return .secondary }
        switch model.assistantTestSearchOutcome {
        case .succeeded: return SLDesign.success
        case .failed: return SLDesign.warning
        case nil: return .secondary
        }
    }

    private func readinessLabel(
        readyTitle: String,
        setupTitle: String,
        ready: Bool
    ) -> some View {
        Label(
            ready ? readyTitle : setupTitle,
            systemImage: ready ? "checkmark.circle.fill" : "circle"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(ready ? SLDesign.success : .secondary)
    }

    @ViewBuilder
    private var readinessLabels: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                readinessLabelItems
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    readinessLabelItems
                }
                VStack(alignment: .leading, spacing: 4) {
                    readinessLabelItems
                }
            }
        }
    }

    @ViewBuilder
    private var readinessLabelItems: some View {
        readinessLabel(
            readyTitle: "Command Access ready",
            setupTitle: "Turn on Command Access",
            ready: model.cliBridgeState.isAvailable
        )
        readinessLabel(
            readyTitle: "Command installed",
            setupTitle: "Install Terminal command",
            ready: model.cliInstallState.isReady
        )
        terminalReadinessLabel
        verificationReadinessLabel
    }

    private var terminalReadinessLabel: some View {
        let label: String
        let icon: String
        switch model.cliCommandAvailability {
        case .available:
            label = "Terminal ready"
            icon = "checkmark.circle.fill"
        case .checking:
            label = "Terminal checking"
            icon = "clock"
        case .notChecked, .unknown:
            label = "Terminal not checked"
            icon = "questionmark.circle"
        case .unavailable, .shadowed, .checkFailed:
            label = "Terminal needs setup"
            icon = "circle"
        }
        return Label(label, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(
                model.cliCommandAvailability.isAvailable ? SLDesign.success : .secondary
            )
    }

    private var verificationReadinessLabel: some View {
        let label: String
        let icon: String
        let ready = model.assistantLiveVerificationState == .succeeded
        if model.assistantLiveVerificationIsRunning {
            label = "Verification running"
            icon = "clock"
        } else if ready {
            label = "Verification passed"
            icon = "checkmark.circle.fill"
        } else {
            label = "Verification needed"
            icon = "circle"
        }
        return Label(label, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(ready ? SLDesign.success : .secondary)
    }

    private var isReady: Bool {
        model.cliBridgeState.isAvailable && model.cliInstallState.isReady
            && model.cliCommandAvailability.isAvailable
            && model.assistantLiveVerificationState == .succeeded
    }

    private var title: String {
        if isReady { return "Command Setup complete" }
        if !model.cliBridgeState.isAvailable, !model.cliInstallState.isReady {
            return "Set Up Command Access"
        }
        return "Finish Command Setup"
    }

    private var detail: String {
        if isReady {
            return
                "The Terminal command can reach this Screenlogger Library. Test each assistant separately before relying on its connection."
        }
        if !model.cliBridgeState.isAvailable, !model.cliInstallState.isReady {
            return "Turn on Command Access. \(commandSetupInstruction)"
        }
        if !model.cliBridgeState.isAvailable {
            return "The Terminal command is installed. Turn on Command Access so it can reach Screenlogger."
        }
        if model.cliInstallState.isReady, !model.cliCommandAvailability.isAvailable {
            switch model.cliCommandAvailability {
            case .checking:
                return "The command is installed. Checking whether Terminal can find it..."
            case .notChecked:
                return "The command is installed. Choose Check PATH to verify it in your login shell."
            case .unknown:
                return "The command is installed. Choose Check PATH to verify Terminal availability."
            case .unavailable, .shadowed:
                return pathSetup == nil
                    ? "The command is installed, but Terminal's PATH needs attention. Review the details below."
                    : "The command is installed, but Terminal cannot use this copy yet. Copy the PATH setup command below."
            case .checkFailed:
                return pathSetup == nil
                    ? "The command is installed, but Screenlogger could not verify Terminal's PATH. Review the details below."
                    : "The command is installed, but PATH verification did not complete. You can copy the PATH setup command below."
            case .available:
                break
            }
        }
        if verificationPrerequisitesAreReady {
            return verificationDescription
        }
        return "Command Access is ready. \(commandSetupInstruction)"
    }

    private var verificationPrerequisitesAreReady: Bool {
        model.cliBridgeState.isAvailable && model.cliInstallState.isReady
            && model.cliCommandAvailability.isAvailable
    }

    private var verificationDescription: String {
        if model.assistantLiveVerificationIsRunning {
            return "Checking the managed command against this Screenlogger Library..."
        }
        switch model.assistantLiveVerificationState {
        case .notRun:
            return
                "Test whether the Terminal command can reach this Screenlogger Library. This does not launch or test an assistant."
        case .succeeded:
            return
                "The Terminal command reached this Library through Command Access. This does not confirm that an assistant loaded its integration."
        case .failed(.appUnavailable):
            return "The Terminal command could not reach Screenlogger. Retry Command Access. Then verify again."
        case .failed(.protocolMismatch):
            return "The app and managed command use different connection protocols. Update or reinstall the command."
        case .failed(.versionMismatch):
            return "The managed command does not match this Screenlogger build. Update or reinstall it."
        case .failed(.invalidResponse):
            return "The managed command returned an unexpected response. Update it. Then verify again."
        case .failed(.commandFailed):
            return "The managed command could not complete the Library check. Review the connection status. Then try again."
        }
    }

    private var verificationActionTitle: String {
        model.assistantLiveVerificationState == .notRun ? "Test Command" : "Test Again"
    }

    private var verificationIcon: String {
        if model.assistantLiveVerificationIsRunning { return "clock" }
        switch model.assistantLiveVerificationState {
        case .succeeded: return "checkmark.shield.fill"
        case .failed: return "exclamationmark.shield.fill"
        case .notRun: return "checkmark.shield"
        }
    }

    private var verificationColor: Color {
        if model.assistantLiveVerificationIsRunning { return .secondary }
        switch model.assistantLiveVerificationState {
        case .succeeded: return SLDesign.success
        case .failed: return SLDesign.warning
        case .notRun: return .secondary
        }
    }

    private var connectionDescription: String {
        switch model.cliBridgeState {
        case .disabled:
            return "Allow Terminal and connected assistants to search Screenlogger while the app is running."
        case .starting:
            return "Starting Command Access for the screenlog command..."
        case .available:
            return "Terminal and connected assistants can reach Screenlogger while it is running."
        case .unavailable(let failure):
            return "Command Access is unavailable: \(failure.localizedDescription)"
        }
    }

    private var connectionStatusColor: Color {
        switch model.cliBridgeState {
        case .available: return SLDesign.success
        case .unavailable: return SLDesign.warning
        case .disabled, .starting: return .secondary
        }
    }

    private var commandDescription: String {
        switch model.cliInstallState {
        case .notInstalled:
            return "Install the screenlog command for Terminal and supported assistants."
        case .installing:
            return "Checking and installing the command..."
        case .removing:
            return "Removing the Screenlogger-managed command..."
        case .ready:
            switch model.cliCommandAvailability {
            case .available:
                return "Installed, verified, and available in Terminal."
            case .checking:
                return "Installed and verified. Checking whether Terminal can find it..."
            case .notChecked:
                return "Installed and verified. Choose Check PATH to verify it in Terminal."
            case .shadowed(_, let resolvedPath, _):
                return "Installed, but Terminal finds another screenlog command first at \(resolvedPath)."
            case .unavailable:
                return "Installed, but Terminal cannot find it on PATH yet."
            case .checkFailed:
                return "Installed, but Screenlogger could not verify Terminal's PATH."
            case .unknown:
                return "Installed and verified. Choose Check PATH to verify it in Terminal."
            }
        case .updateAvailable:
            return "A verified Screenlogger command is installed, but an update is available."
        case .verificationUnavailable:
            return
                "The installed command is intact, but this copy of Screenlogger cannot verify its version. Reinstall the app to restore its bundled command."
        case .conflict(let conflict):
            return conflict.localizedDescription
        case .failed(let failure):
            return failure.localizedDescription
        }
    }

    private var commandActionTitle: String {
        switch model.cliInstallState {
        case .failed: return "Try Again"
        case .updateAvailable: return "Update"
        case .notInstalled, .installing, .removing, .ready, .verificationUnavailable,
            .conflict:
            return "Install"
        }
    }

    private var commandActionAccessibilityLabel: String {
        switch model.cliInstallState {
        case .failed: return "Try installing the screenlog command again"
        case .updateAvailable: return "Update the screenlog command"
        case .verificationUnavailable:
            return "The screenlog command version cannot be verified"
        case .installing: return "Installing the screenlog command"
        case .removing: return "Removing the screenlog command"
        case .notInstalled, .ready, .conflict: return "Install the screenlog command"
        }
    }

    private var commandTechnicalDetail: String {
        switch model.cliInstallState {
        case .notInstalled:
            return
                "Screenlogger did not find its Terminal command in the expected user-level location. Installation does not require administrator access."
        case .installing:
            return
                "Screenlogger is checking its command files and installing them only for your macOS user account."
        case .removing:
            return
                "Screenlogger is removing only the authenticated command files it manages for your macOS user account."
        case .ready(let path):
            return readyCommandTechnicalDetail(path: path)
        case .updateAvailable(let path):
            return "Verified command location: \(path). Update it before relying on Terminal or an assistant."
        case .verificationUnavailable(let path):
            return
                "Authenticated command location: \(path). Screenlogger preserved it because the app's bundled comparison files are unavailable."
        case .conflict:
            return "Screenlogger found existing files and preserved them. Use Show Files to review the location before making changes."
        case .failed(let failure):
            return "The command is not ready. \(failure.localizedDescription)"
        }
    }

    private var commandVerificationIsUnavailable: Bool {
        if case .verificationUnavailable = model.cliInstallState { return true }
        return false
    }

    private var commandSetupInstruction: String {
        switch model.cliInstallState {
        case .notInstalled:
            return "Install the Terminal command before relying on an assistant integration."
        case .installing:
            return "Wait for the Terminal command installation to finish."
        case .removing:
            return "Wait for the Terminal command removal to finish."
        case .ready:
            if model.cliCommandAvailability.isAvailable {
                return "The Terminal command is ready."
            }
            if case .notChecked = model.cliCommandAvailability {
                return "Check whether Terminal can find the installed command."
            }
            return "Finish PATH setup so Terminal and assistants can find the installed command."
        case .updateAvailable:
            return "Update the Terminal command before relying on an assistant integration."
        case .verificationUnavailable:
            return "Reinstall Screenlogger to restore the bundled Terminal command used for verification."
        case .conflict:
            return "Review the preserved command files before continuing setup."
        case .failed:
            return "Try the Terminal command setup again."
        }
    }

    private var mutationAccessDescription: String {
        model.localToolCaptureControlAndMaintenanceEnabled
            ? "Terminal and configured assistants can start capture, stop capture, or capture once. They can compact the Library and run retention cleanup. History search remains available."
            : "History search is read-only. Terminal and configured assistants cannot control capture or run Library maintenance."
    }

    private var pathSetup: CLIPathSetup? {
        model.cliCommandAvailability.setup
    }

    private var pathNeedsSetup: Bool {
        switch model.cliCommandAvailability {
        case .unavailable, .shadowed, .checkFailed: return true
        case .unknown, .notChecked, .checking, .available: return false
        }
    }

    private var pathCheckActionTitle: String {
        switch model.cliCommandAvailability {
        case .unavailable, .shadowed, .checkFailed: return "Check Again"
        case .unknown, .notChecked, .checking, .available: return "Check PATH"
        }
    }

    private func readyCommandTechnicalDetail(path: String) -> String {
        switch model.cliCommandAvailability {
        case .available:
            return "Verified command location: \(path). The user's login shell resolves this managed command."
        case .notChecked:
            return
                "Verified command location: \(path). Choose Check PATH to ask the user's login shell which screenlog command it resolves."
        case .shadowed(_, let resolvedPath, let setup):
            return pathSetupTechnicalDetail(
                base: "Verified command location: \(path). Terminal currently resolves \(resolvedPath) first.",
                setup: setup
            )
        case .unavailable(_, let setup):
            return pathSetupTechnicalDetail(
                base: "Verified command location: \(path). Terminal does not currently resolve screenlog.",
                setup: setup
            )
        case .checkFailed(_, let setup):
            return pathSetupTechnicalDetail(
                base: "Verified command location: \(path). Login-shell PATH verification did not complete.",
                setup: setup
            )
        case .unknown, .checking:
            return "Verified command location: \(path). Screenlogger is checking the user's login-shell PATH."
        }
    }

    private func pathSetupTechnicalDetail(base: String, setup: CLIPathSetup?) -> String {
        guard let setup else {
            return "\(base) Add ~/.local/bin to your shell's PATH. Then choose Check Again."
        }
        return
            "\(base) Copy the \(setup.shellName) setup command. Paste it into Terminal. Open a new Terminal window. Choose Check Again."
    }

    private func copyPathSetup(_ setup: CLIPathSetup) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setup.command, forType: .string)
        pathSetupCopied = true
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "PATH setup command copied.",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
