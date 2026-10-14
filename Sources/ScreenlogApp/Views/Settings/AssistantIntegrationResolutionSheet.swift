import AppKit
import ScreenlogCore
import SwiftUI

struct AssistantIntegrationResolutionRequest: Identifiable {
    let target: AssistantIntegrationTarget
    let inspection: AssistantIntegrationInspection

    var id: String { target.rawValue }
}

/// Recovery stays deliberately separate from the one-click installer.
/// Screenlogger-owned content can be repaired in-app; unrelated destinations
/// only receive an explicit Terminal command after the user reviews the path.
struct AssistantIntegrationResolutionSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let target: AssistantIntegrationTarget
    @State private var inspection: AssistantIntegrationInspection
    @State private var showingTechnicalDetails: Bool
    @State private var confirmedForcedReplacement = false
    @State private var commandCopied = false
    @State private var actionNotice: AssistantIntegrationActionNotice?

    init(
        target: AssistantIntegrationTarget,
        initialInspection: AssistantIntegrationInspection
    ) {
        self.target = target
        _inspection = State(initialValue: initialInspection)
        _showingTechnicalDetails = State(initialValue: initialInspection.state.requiresForce)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(SLDesign.space24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: SLDesign.space24) {
                    recoveryCard

                    if let actionNotice {
                        AssistantIntegrationActionNoticeView(notice: actionNotice)
                            .accessibilityIdentifier("settings.integration.resolve.status")
                    }

                    technicalDetails
                }
                .padding(SLDesign.space24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
                .padding(SLDesign.space24)
        }
        .frame(
            minWidth: 540,
            idealWidth: 620,
            maxWidth: 700,
            minHeight: 460,
            idealHeight: 540,
            maxHeight: 720
        )
        .interactiveDismissDisabled(assistantWork != nil)
        .accessibilityIdentifier("settings.integration.resolve.sheet")
        .onAppear {
            actionNotice = model.assistantIntegrationActionNotice(for: target)
        }
        .onChange(of: model.agentSkillSnapshotState(target)) { _, loadState in
            guard case .loaded(let snapshot) = loadState,
                let refreshed = snapshot.inspection
            else { return }
            applyRefreshedInspection(refreshed)
        }
        .onChange(of: model.assistantIntegrationActionNotice(for: target)) { _, notice in
            actionNotice = notice
        }
        .onExitCommand {
            guard assistantWork == nil else { return }
            dismiss()
        }
    }

    private var header: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stackedHeader
            } else {
                ViewThatFits(in: .horizontal) {
                    horizontalHeader
                    stackedHeader
                }
            }
        }
    }

    private var horizontalHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            headerIdentity
            Spacer(minLength: 0)
            statusLabel
        }
        .accessibilityElement(children: .contain)
    }

    private var stackedHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerIdentity
            statusLabel
        }
        .accessibilityElement(children: .contain)
    }

    private var headerIdentity: some View {
        HStack(alignment: .top, spacing: 12) {
            AssistantIntegrationIcon(
                target: target,
                applicationURL: model.agentSkillSnapshotState(target).snapshot?.presence.appURL
            )

            VStack(alignment: .leading, spacing: SLDesign.space4) {
                Text(presentation.title)
                    .font(SLDesign.titleFont)
                Text(presentation.detail)
                    .font(SLDesign.bodyFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusLabel: some View {
        Label(presentation.statusLabel, systemImage: presentation.statusIcon)
            .font(.caption.weight(.medium))
            .foregroundStyle(statusColor)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Integration status")
            .accessibilityValue(presentation.statusLabel)
    }

    private var statusColor: Color {
        if inspection.isCurrent { return SLDesign.success }
        return inspection.state.requiresForce ? SLDesign.warning : .secondary
    }

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: SLDesign.space8) {
            Text(presentation.recoveryTitle)
                .font(SLDesign.sectionFont)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: SLDesign.space16) {
                if inspection.isCurrent {
                    Label(
                        "The managed integration files are current. This does not yet confirm that \(target.label) can search Screenlogger.",
                        systemImage: "checkmark.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else if inspection.state.requiresForce {
                    Label(
                        "Screenlogger cannot verify that it created this item, so the app will not replace it.",
                        systemImage: "exclamationmark.shield"
                    )
                    .font(.callout)
                    .foregroundStyle(SLDesign.warning)
                    .fixedSize(horizontal: false, vertical: true)

                    Toggle(
                        "I reviewed the integration location and intend to replace its existing item",
                        isOn: $confirmedForcedReplacement
                    )
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("settings.integration.resolve.confirm-force")

                    if !confirmedForcedReplacement {
                        Text(
                            "Review Integration details below. Confirm before you copy the force-replacement command."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        copyRecoveryCommand()
                    } label: {
                        Label(
                            commandCopied ? "Command Copied" : "Copy Force-Replace Command",
                            systemImage: commandCopied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!confirmedForcedReplacement)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(
                        "Copies a Terminal command that replaces the reviewed item. Does not run the command."
                    )
                    .accessibilityIdentifier("settings.integration.resolve.copy-force-command")

                    if commandCopied {
                        Text(
                            "Paste the command into Terminal. Review it before you press Return. Then return here. Choose Check Again."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(
                        "Screenlogger manages this integration. Screenlogger can update it without replacing unrelated content."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if !inspection.isCurrent {
                        Button {
                            performSafeRecovery()
                        } label: {
                            HStack(spacing: 7) {
                                if assistantWork == .installation {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityHidden(true)
                                }
                                Text(
                                    assistantWork == .installation
                                        ? presentation.progressTitle
                                        : presentation.safeActionTitle
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(assistantWork != nil)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel(
                            assistantWork == .installation
                                ? "\(presentation.progressTitle) \(target.label) integration"
                                : "\(presentation.safeActionTitle) for \(target.label)"
                        )
                        .accessibilityHint("Updates only Screenlogger-owned integration files")
                        .accessibilityIdentifier("settings.integration.resolve.safe-action")
                    }
                }
            }
            .padding(.vertical, SLDesign.space4)
        }
    }

    private var technicalDetails: some View {
        DisclosureGroup(isExpanded: $showingTechnicalDetails) {
            VStack(alignment: .leading, spacing: 14) {
                destinationDetails
                Divider()
                commandDetails
            }
            .padding(.top, 10)
        } label: {
            Label("Integration details", systemImage: "info.circle")
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 4)
        .accessibilityHint("Show the integration location and Terminal recovery command")
    }

    private var destinationDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Integration location")
                .font(.caption.weight(.semibold))

            Text(inspection.destination.path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Integration destination")
                .accessibilityValue(inspection.destination.path)
                .accessibilityIdentifier("settings.integration.resolve.destination")

            Button {
                revealDestinationInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .controlSize(.small)
            .disabled(!canRevealDestination)
            .accessibilityHint("Shows the integration location without changing it")
            .accessibilityIdentifier("settings.integration.resolve.reveal")

            if !canRevealDestination {
                Text("The containing folder is not available yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var commandDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Terminal command")
                .font(.caption.weight(.semibold))
            Text(recoveryCommand)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .accessibilityLabel("Recovery command")
                .accessibilityValue(recoveryCommand)
                .accessibilityIdentifier("settings.integration.resolve.command")

            if !inspection.state.requiresForce {
                Button {
                    copyRecoveryCommand()
                } label: {
                    Label(
                        commandCopied ? "Copied" : "Copy Command",
                        systemImage: commandCopied ? "checkmark" : "doc.on.doc"
                    )
                }
                .controlSize(.small)
                .accessibilityHint("Copies the exact command for this integration to the clipboard")
                .accessibilityIdentifier("settings.integration.resolve.copy-command")
            }
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                reinspectButton
                Spacer()
                closeButton
            }

            VStack(alignment: .leading, spacing: 10) {
                reinspectButton
                closeButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var reinspectButton: some View {
        Button {
            reinspect()
        } label: {
            HStack(spacing: 7) {
                if assistantWork == .inspection {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(assistantWork == .inspection ? "Checking..." : "Check Again")
            }
        }
        .disabled(assistantWork != nil)
        .accessibilityLabel(
            assistantWork == .inspection
                ? "Checking \(target.label) integration"
                : "Check \(target.label) integration again"
        )
        .accessibilityHint("Re-inspects the integration without changing files")
        .accessibilityIdentifier("settings.integration.resolve.reinspect")
    }

    @ViewBuilder
    private var closeButton: some View {
        if inspection.isCurrent {
            Button("Done") {
                dismiss()
            }
            .disabled(assistantWork != nil)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("settings.integration.resolve.close")
        } else {
            Button("Cancel") {
                dismiss()
            }
            .disabled(assistantWork != nil)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("settings.integration.resolve.close")
        }
    }

    private var presentation: AssistantIntegrationResolutionPresentation {
        AssistantIntegrationResolutionPresentation(
            target: target,
            inspection: inspection,
            handoffShortcutLabel: model.keyboardShortcutAccessibilityLabel(for: .askAssistant)
        )
    }

    private var recoveryCommand: String {
        let operation =
            inspection.state == .missing || inspection.state.requiresForce
            ? "install"
            : "upgrade"
        let force = inspection.state.requiresForce ? " --force" : ""
        return "~/.local/bin/screenlog skill \(operation) \(target.rawValue)\(force)"
    }

    private var assistantWork: AssistantIntegrationWorkKind? {
        model.assistantIntegrationWork(for: target)
    }

    private var canRevealDestination: Bool {
        model.agentSkillSnapshotState(target).snapshot?.destinationParentExists == true
    }

    private func revealDestinationInFinder() {
        guard canRevealDestination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([inspection.destination])
    }

    private func copyRecoveryCommand() {
        guard !inspection.state.requiresForce || confirmedForcedReplacement else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recoveryCommand, forType: .string)
        commandCopied = true
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "\(target.label) recovery command copied.",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func performSafeRecovery() {
        guard !inspection.state.requiresForce else { return }
        model.installAgentSkill(target, reinstall: inspection.state.isCurrent)
    }

    private func reinspect() {
        model.reinspectAgentSkill(target)
    }

    private func applyRefreshedInspection(_ refreshed: AssistantIntegrationInspection) {
        let previouslyRequiredForce = inspection.state.requiresForce
        inspection = refreshed
        if refreshed.state.requiresForce {
            showingTechnicalDetails = true
        } else if previouslyRequiredForce {
            showingTechnicalDetails = false
        }
        confirmedForcedReplacement = false
        commandCopied = false
    }
}

private struct AssistantIntegrationResolutionPresentation {
    let target: AssistantIntegrationTarget
    let inspection: AssistantIntegrationInspection
    let handoffShortcutLabel: String

    var title: String {
        if inspection.isCurrent { return "\(target.label) Integration" }
        switch inspection.state {
        case .staleLink, .staleCopy: return "Update \(target.label) Integration"
        case .brokenLink, .conflict: return "Review \(target.label) Integration"
        case .missing: return "Install \(target.label) Integration"
        case .currentLink, .currentCopy: return "Finish \(target.label) Setup"
        }
    }

    var detail: String {
        switch inspection.state {
        case .staleLink:
            return "Screenlogger owns this integration, but its managed link points to an older Screenlogger installation."
        case .staleCopy:
            return "Screenlogger owns this integration, but its installed files need an update."
        case .brokenLink:
            return
                "The integration link source is unavailable. Screenlogger cannot verify who created the link. Screenlogger will keep it."
        case .conflict:
            return
                "An existing file or folder occupies the integration location. Screenlogger cannot verify that it owns the item. Screenlogger will keep it."
        case .missing:
            return "No integration is installed at this location. Screenlogger can install its managed files safely."
        case .currentLink, .currentCopy:
            return inspection.isCurrent
                ? "Restart \(target.label) if it was open. Close this sheet. Use \(handoffShortcutLabel) with a Library search to try the connection."
                : "The integration files are current, but \(target.label) still needs its remaining setup step."
        }
    }

    var statusLabel: String {
        if inspection.isCurrent { return "Files current" }
        switch inspection.state {
        case .missing: return "Not installed"
        case .currentLink, .currentCopy: return "Setup incomplete"
        case .staleLink, .staleCopy: return "Update available"
        case .brokenLink: return "Broken link"
        case .conflict: return "Path in use"
        }
    }

    var statusIcon: String {
        if inspection.isCurrent { return "checkmark.circle.fill" }
        return inspection.state.requiresForce ? "exclamationmark.circle.fill" : "info.circle"
    }

    var safeActionTitle: String {
        switch inspection.state {
        case .missing: return "Install Integration"
        case .currentLink, .currentCopy: return "Finish Setup"
        default: return "Update Integration"
        }
    }

    var recoveryTitle: String {
        if inspection.isCurrent { return "Next step" }
        return inspection.state.requiresForce ? "Review before replacing" : "Safe recovery"
    }

    var progressTitle: String {
        switch inspection.state {
        case .missing: return "Installing..."
        case .currentLink, .currentCopy: return "Finishing Setup..."
        default: return "Updating..."
        }
    }
}
