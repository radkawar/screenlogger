import AppKit
import ScreenlogCore
import SwiftUI

/// Keeps assistant setup scannable: explain readiness once, then give every
/// assistant a single state and primary action in a native settings row.
struct AssistantIntegrationsSettingsSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var model: AppModel
    @State private var showsOtherAssistants = false
    @State private var showsConnectionPrivacy = false

    let onRemove: (AssistantIntegrationTarget) -> Void
    let onResolve: (AssistantIntegrationTarget, AssistantIntegrationInspection) -> Void

    var body: some View {
        let connectedTargets = prominentTargets
        let otherTargets = AssistantIntegrationTarget.allCases.filter {
            !connectedTargets.contains($0)
        }

        SettingsCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader
                    .padding(14)

                Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                privacyDisclosure
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                if !localAccessIsReady {
                    Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                    readinessSummary
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }

                Divider().padding(.leading, SettingsChrome.rowSeparatorInset)

                handoffRouting
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                if !connectedTargets.isEmpty {
                    Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
                    assistantRows(connectedTargets)
                }

                if !otherTargets.isEmpty {
                    Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
                    otherAssistantsDisclosure(otherTargets)
                }
            }
        }
    }

    @ViewBuilder
    private func assistantRows(_ targets: [AssistantIntegrationTarget]) -> some View {
        ForEach(Array(targets.enumerated()), id: \.element) { index, target in
            AssistantIntegrationRow(
                target: target,
                emphasizesPrimaryAction: false,
                onRemove: { onRemove(target) },
                onResolve: { inspection in onResolve(target, inspection) }
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            if index < targets.count - 1 {
                Divider().padding(.leading, SettingsChrome.rowSeparatorInset)
            }
        }
    }

    private func otherAssistantsDisclosure(
        _ targets: [AssistantIntegrationTarget]
    ) -> some View {
        DisclosureGroup(isExpanded: $showsOtherAssistants) {
            VStack(alignment: .leading, spacing: 0) {
                Divider().padding(.leading, 40)
                assistantRows(targets)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Other Supported Assistants")
                        .font(.callout.weight(.medium))
                    Text(otherAssistantsDescription(targets))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .accessibilityHint(
            showsOtherAssistants
                ? "Hide supported assistants that were not detected on this Mac"
                : "Show supported assistants that were not detected on this Mac"
        )
        .accessibilityIdentifier("settings.integrations.other-assistants")
    }

    private var privacyDisclosure: some View {
        DisclosureGroup(isExpanded: $showsConnectionPrivacy) {
            Text(
                "A connection adds files on this Mac. An assistant may send your request and retrieved content to its configured AI provider when you ask it to search Screenlogger. Review that assistant's privacy settings before use."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
        } label: {
            Label("How assistant connections work", systemImage: "lock.shield")
                .font(.callout.weight(.medium))
        }
        .accessibilityIdentifier("settings.integrations.assistant-privacy")
    }

    private var sectionHeader: some View {
        SettingsCardRow(
            icon: "puzzlepiece.extension",
            title: "Assistant Connections",
            subtitle:
                "Connect supported assistants to search your Screenlogger Library. Restart an assistant after installing its connection."
        ) {
            EmptyView()
        }
    }

    private var readinessSummary: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stackedReadinessSummary
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        readinessLabel
                        Spacer(minLength: 8)
                        commandSetupAction
                    }
                    stackedReadinessSummary
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.integrations.assistant-readiness")
    }

    private var stackedReadinessSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            readinessLabel
            commandSetupAction
        }
    }

    private var readinessLabel: some View {
        Label(readinessDescription, systemImage: readinessIcon)
            .font(.caption)
            .foregroundStyle(localAccessIsReady ? SLDesign.success : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var commandSetupAction: some View {
        if !localAccessIsReady {
            Button("Review Command Setup") {
                model.requestSettingsNavigation(to: .integrationsLocalTools)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Review the first Command Setup step that needs attention")
            .accessibilityIdentifier("settings.integrations.open-local-tools")
        }
    }

    private var localAccessIsReady: Bool {
        model.cliBridgeState.isAvailable && model.cliInstallState.isReady
            && model.cliCommandAvailability.isAvailable
            && model.assistantLiveVerificationState == .succeeded
    }

    private var readinessDescription: String {
        localAccessIsReady
            ? "Command Setup is complete. Connect only the assistants you use on this Mac."
            : "Complete Command Setup before an assistant can search Screenlogger. You may install connection files now."
    }

    private var readinessIcon: String {
        localAccessIsReady ? "checkmark.circle.fill" : "info.circle"
    }

    private var handoffRouting: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                handoffRoutingIdentity
                Spacer(minLength: 12)
                handoffRoutingPicker
            }
            VStack(alignment: .leading, spacing: 8) {
                handoffRoutingIdentity
                handoffRoutingPicker
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.integrations.handoff-routing")
    }

    private var handoffRoutingIdentity: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "command")
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    model.keyboardShortcutAccessibilityLabel(for: .askAssistant)
                        + " Handoff"
                )
                .font(.callout.weight(.medium))
                Text(
                    "Automatic preselects the only available connection. When several are available, Screenlogger asks you to choose. Every handoff is reviewed before it opens."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var handoffRoutingPicker: some View {
        Picker("Assistant routing", selection: $model.libraryAssistantRoutingPreference) {
            Text("Automatic").tag(LibraryAssistantRoutingPreference.automatic)
            Text("Ask Every Time").tag(LibraryAssistantRoutingPreference.askEveryTime)
            if !availableHandoffTargets.isEmpty {
                Divider()
                ForEach(availableHandoffTargets) { target in
                    Text(target.label)
                        .tag(LibraryAssistantRoutingPreference.preferred(target))
                }
            }
            if case .preferred(let target) = model.libraryAssistantRoutingPreference,
                !availableHandoffTargets.contains(target)
            {
                Text("\(target.label) - Unavailable")
                    .tag(LibraryAssistantRoutingPreference.preferred(target))
                    .disabled(true)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityHint(
            "Chooses how Library "
                + model.keyboardShortcutAccessibilityLabel(for: .askAssistant)
                + " selects an assistant"
        )
        .accessibilityIdentifier("settings.integrations.handoff-routing.picker")
    }

    private var availableHandoffTargets: [AssistantIntegrationTarget] {
        model.assistantHandoffDestinations().map(\.target)
    }

    private var prominentTargets: [AssistantIntegrationTarget] {
        AssistantIntegrationTarget.allCases.filter { target in
            if model.assistantIntegrationWork(for: target) != nil
                || model.assistantIntegrationActionNotice(for: target) != nil
            {
                return true
            }
            guard let snapshot = model.agentSkillSnapshotState(target).snapshot else {
                return false
            }
            if snapshot.presence.isPresent || snapshot.inspectionIssue != nil {
                return true
            }
            guard let inspection = snapshot.inspection else { return false }
            return inspection.isOwned || inspection.state.requiresForce
                || inspection.isRegistered == false
        }
    }

    private func otherAssistantsDescription(
        _ targets: [AssistantIntegrationTarget]
    ) -> String {
        let isChecking = targets.contains {
            let state = model.agentSkillSnapshotState($0)
            return state == .idle || state.isLoading
        }
        if isChecking { return "Checking this Mac..." }
        return "\(targets.count) \(targets.count == 1 ? "assistant" : "assistants") not detected on this Mac"
    }
}

private struct AssistantIntegrationRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.settingsDestinationFocusRequest) private var focusRequest
    @EnvironmentObject private var model: AppModel
    @FocusState private var keyboardFocused: Bool
    @AccessibilityFocusState private var accessibilityFocused: Bool

    let target: AssistantIntegrationTarget
    let emphasizesPrimaryAction: Bool
    let onRemove: () -> Void
    let onResolve: (AssistantIntegrationInspection) -> Void

    var body: some View {
        let snapshot = rowSnapshot()
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        appIcon(snapshot)
                            .padding(.top, 1)
                        identity(snapshot)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    actionControls(snapshot)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    horizontalRow(snapshot)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            appIcon(snapshot)
                                .padding(.top, 1)
                            identity(snapshot)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        actionControls(snapshot)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        .padding(4)
        .background(
            rowHasFocus ? model.accentSwiftUIColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            if rowHasFocus {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(model.accentSwiftUIColor.opacity(0.85), lineWidth: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .focusable()
        .focused($keyboardFocused)
        .accessibilityFocused($accessibilityFocused)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(rowIdentifier)
        .onAppear { focusIfRequested() }
        .onChange(of: focusRequest) { _, _ in focusIfRequested() }
    }

    private func horizontalRow(_ snapshot: RowSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            appIcon(snapshot)
                .padding(.top, 1)

            identity(snapshot)
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            actionControls(snapshot)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.top, 1)
        }
    }

    private var rowIdentifier: String {
        "settings.integration.\(target.rawValue)"
    }

    private var focusIsRequested: Bool {
        focusRequest?.focusedElementIdentifier == rowIdentifier
    }

    private var rowHasFocus: Bool {
        keyboardFocused || accessibilityFocused
    }

    private func focusIfRequested() {
        guard focusIsRequested else { return }
        Task { @MainActor in
            // The row may enter the hierarchy in the same update that changes
            // the pane. Let AppKit register the focus destination first.
            await Task.yield()
            await Task.yield()
            keyboardFocused = true
            accessibilityFocused = true
        }
    }

    private func appIcon(_ snapshot: RowSnapshot) -> some View {
        AssistantIntegrationIcon(target: target, applicationURL: snapshot.appURL)
    }

    private func identity(_ snapshot: RowSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    assistantName
                    stateBadge(snapshot)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    assistantName
                    stateBadge(snapshot)
                }
            }

            Text(explanation(snapshot))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(explanationIdentifier(snapshot))
        }
    }

    private var assistantName: some View {
        Text(target.label)
            .font(.body.weight(.medium))
            .fixedSize(horizontal: true, vertical: false)
    }

    private func stateBadge(_ snapshot: RowSnapshot) -> some View {
        Group {
            if let work = snapshot.work {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(work.progressLabel)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(work.progressLabel) \(target.label) integration")
                .foregroundStyle(.secondary)
            } else if snapshot.isPending {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Checking")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Checking \(target.label) integration")
                .foregroundStyle(.secondary)
            } else if snapshot.actionNotice?.severity == .failure {
                Label("Action failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(SLDesign.error)
            } else if snapshot.inspection == nil {
                Label("Unavailable", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(SLDesign.warning)
            } else {
                Label(
                    badgeLabel(snapshot),
                    systemImage: badgeIcon(snapshot.presentation.tone)
                )
                .foregroundStyle(badgeColor(snapshot.presentation.tone))
            }
        }
        .font(.caption.weight(.medium))
    }

    private func actionControls(_ snapshot: RowSnapshot) -> some View {
        HStack(spacing: 8) {
            if snapshot.work == nil, !snapshot.isPending,
                let actionTitle = actionTitle(snapshot)
            {
                primaryActionButton(actionTitle, snapshot: snapshot)
            }

            if snapshot.work == nil, !snapshot.isPending, snapshot.hasSecondaryActions {
                secondaryActions(snapshot)
            }
        }
    }

    @ViewBuilder
    private func primaryActionButton(
        _ title: String,
        snapshot: RowSnapshot
    ) -> some View {
        if emphasizesPrimaryAction {
            actionButton(title, snapshot: snapshot)
                .buttonStyle(.borderedProminent)
        } else {
            actionButton(title, snapshot: snapshot)
                .buttonStyle(.bordered)
        }
    }

    private func actionButton(
        _ title: String,
        snapshot: RowSnapshot
    ) -> some View {
        Button(title) {
            performPrimaryAction(snapshot)
        }
        .controlSize(.small)
        .help(actionHelp(snapshot))
        .accessibilityLabel(actionAccessibilityLabel(snapshot))
        .accessibilityIdentifier(
            "settings.integration.\(target.rawValue).action"
        )
    }

    private func secondaryActions(_ snapshot: RowSnapshot) -> some View {
        Menu {
            if snapshot.agentIsPresent {
                Button("Check Again") {
                    model.reinspectAgentSkill(target)
                }
                .accessibilityIdentifier(
                    "settings.integration.\(target.rawValue).check-again"
                )
            }

            if snapshot.canReviewDetails, let inspection = snapshot.inspection {
                Button("Integration Details...") {
                    onResolve(inspection)
                }
                .accessibilityIdentifier(
                    "settings.integration.\(target.rawValue).details"
                )
            }

            if snapshot.canRemoveSafely {
                if snapshot.agentIsPresent || snapshot.canReviewDetails {
                    Divider()
                }
                Button("Remove Integration...", role: .destructive, action: onRemove)
                    .accessibilityIdentifier(
                        "settings.integration.\(target.rawValue).remove"
                    )
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .slCompactControlTarget()
        .help("More actions for \(target.label)")
        .accessibilityLabel("More actions for \(target.label)")
        .accessibilityIdentifier("settings.integration.\(target.rawValue).more")
    }

    private func rowSnapshot() -> RowSnapshot {
        let loadState = model.agentSkillSnapshotState(target)
        let presentation = AssistantOperationalReadinessPresentation.make(
            readiness: model.assistantOperationalReadiness(for: target),
            target: target
        )
        let canOpenDirectly =
            loadState.snapshot.flatMap { snapshot in
                AssistantHandoffLaunchService.destination(
                    for: target,
                    presence: snapshot.presence
                )
            } != nil
        return RowSnapshot(
            loadState: loadState,
            work: model.assistantIntegrationWork(for: target),
            presenceDetail: model.agentPresenceDetail(target),
            actionNotice: model.assistantIntegrationActionNotice(for: target),
            presentation: presentation,
            directHandoffDetail: presentation.tone == .success && !canOpenDirectly
                ? "The connection is verified. Install \(target.label)'s assistant command to use \(model.keyboardShortcutAccessibilityLabel(for: .askAssistant))."
                : nil
        )
    }

    private func actionTitle(_ snapshot: RowSnapshot) -> String? {
        if snapshot.inspection == nil { return "Check Again" }
        guard snapshot.presentation.primaryAction != .openLocalTools else { return nil }
        return snapshot.presentation.actionTitle
    }

    private func actionHelp(_ snapshot: RowSnapshot) -> String {
        if snapshot.inspection == nil {
            return "Re-inspect this integration without changing any files."
        }
        return snapshot.presentation.detail
    }

    private func actionAccessibilityLabel(_ snapshot: RowSnapshot) -> String {
        if snapshot.inspection == nil { return "Check \(target.label) integration again" }
        return "\(snapshot.presentation.actionTitle ?? "Review") \(target.label) connection"
    }

    private func explanationIdentifier(_ snapshot: RowSnapshot) -> String {
        let suffix = snapshot.actionNotice == nil ? "explanation" : "action-notice"
        return "settings.integration.\(target.rawValue).\(suffix)"
    }

    private func badgeLabel(_ snapshot: RowSnapshot) -> String {
        snapshot.presentation.primaryAction == .openLocalTools
            ? "Needs Command Setup"
            : snapshot.presentation.badge
    }

    private func explanation(_ snapshot: RowSnapshot) -> String {
        if snapshot.presentation.primaryAction == .openLocalTools {
            return "Finish Command Setup above before \(target.label) can search Screenlogger."
        }
        return snapshot.explanation
    }

    private func performPrimaryAction(_ snapshot: RowSnapshot) {
        guard let inspection = snapshot.inspection else {
            reinspectUnavailableIntegration()
            return
        }
        switch snapshot.presentation.primaryAction {
        case .installIntegration:
            model.installAgentSkill(target)
        case .resolveIntegration:
            onResolve(inspection)
        case .openLocalTools:
            model.requestSettingsNavigation(to: .integrationsLocalTools)
        case .none:
            break
        }
    }

    private func badgeIcon(
        _ tone: AssistantOperationalReadinessPresentation.Tone
    ) -> String {
        switch tone {
        case .neutral: return "circle"
        case .attention: return "exclamationmark.circle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private func badgeColor(
        _ tone: AssistantOperationalReadinessPresentation.Tone
    ) -> Color {
        switch tone {
        case .neutral: return .secondary
        case .attention: return SLDesign.warning
        case .success: return SLDesign.success
        }
    }

    private func reinspectUnavailableIntegration() {
        model.reinspectUnavailableAgentSkill(target)
    }

    private struct RowSnapshot {
        let loadState: AgentSkillSnapshotLoadState
        let work: AssistantIntegrationWorkKind?
        let presenceDetail: String
        let actionNotice: AssistantIntegrationActionNotice?
        let presentation: AssistantOperationalReadinessPresentation
        let directHandoffDetail: String?

        var explanation: String {
            if let work { return work.explanation }
            if isPending { return "Checking this Mac and its integration files..." }
            if let actionNotice { return actionNotice.message }
            if let directHandoffDetail { return directHandoffDetail }
            return inspection == nil ? presenceDetail : presentation.detail
        }

        var inspection: AssistantIntegrationInspection? {
            loadState.snapshot?.inspection
        }

        var agentIsPresent: Bool {
            loadState.snapshot?.presence.isPresent == true
        }

        var appURL: URL? {
            loadState.snapshot?.presence.appURL
        }

        var isPending: Bool {
            loadState == .idle || loadState.isLoading
        }

        var canRemoveSafely: Bool {
            guard let inspection else { return false }
            return !inspection.state.requiresForce && inspection.isOwned
        }

        var canReviewDetails: Bool {
            guard let inspection else { return false }
            return inspection.state != .missing
                && presentation.primaryAction != .resolveIntegration
        }

        var hasSecondaryActions: Bool {
            agentIsPresent || canReviewDetails || canRemoveSafely
        }
    }
}

extension AssistantIntegrationWorkKind {
    fileprivate var progressLabel: String {
        switch self {
        case .inspection: return "Checking"
        case .installation: return "Installing"
        case .removal: return "Removing"
        }
    }

    fileprivate var explanation: String {
        switch self {
        case .inspection:
            return "Checking this Mac and its integration files..."
        case .installation:
            return "Adding Screenlogger's connection files..."
        case .removal:
            return "Removing Screenlogger's connection files..."
        }
    }
}
