import ScreenlogCore
import SwiftUI

struct AssistantHandoffSheetRequest: Identifiable {
    let id = UUID()
    let prompt: LibraryAssistantHandoffPrompt
    let destinations: [AssistantHandoffDestination]
    let decision: LibraryAssistantRoutingDecision
}

/// Chooses where the scoped Library context should continue. The sheet never
/// receives Library results, OCR, screenshots, or hidden metadata.
struct AssistantHandoffSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let request: AssistantHandoffSheetRequest
    @State private var selectedTarget: AssistantIntegrationTarget?
    @State private var launchError: AssistantHandoffLaunchError?
    @State private var isLaunching = false

    init(request: AssistantHandoffSheetRequest) {
        self.request = request
        _selectedTarget = State(initialValue: Self.initialTarget(for: request.decision))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, SLDesign.space24)
                .padding(.top, SLDesign.space24)
                .padding(.bottom, SLDesign.space16)

            Divider()

            sheetContent
                .frame(maxWidth: .infinity)
                .frame(height: preferredContentHeight)

            Divider()

            footer
                .padding(.horizontal, SLDesign.space24)
                .padding(.vertical, SLDesign.space16)
        }
        .frame(minWidth: 560, idealWidth: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(model.accentSwiftUIColor)
        .onChange(of: model.libraryAssistantRoutingPreference) { _, preference in
            if case .preferred(let target) = preference,
                request.destinations.contains(where: { $0.target == target })
            {
                selectedTarget = target
            }
        }
        .onExitCommand {
            guard !isLaunching else { return }
            dismiss()
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        if request.destinations.isEmpty {
            unavailableContent
                .padding(SLDesign.space24)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: SLDesign.space24) {
                    if case .preferredUnavailable(let preferred, _) = request.decision {
                        preferredUnavailableNotice(preferred)
                    }

                    destinationChooser
                    privacyDisclosure

                    if let launchError {
                        Label(
                            launchError.localizedDescription,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(SLDesign.metadataFont)
                        .foregroundStyle(SLDesign.warning)
                        .accessibilityIdentifier("library.assistant.launch-error")
                    }

                    routingPreference
                }
                .padding(SLDesign.space24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("library.assistant.details")
        }
    }

    /// Keep ordinary routing decisions compact while retaining a bounded
    /// scrolling region for larger destination sets and recovery detail.
    private var preferredContentHeight: CGFloat {
        if request.destinations.isEmpty {
            return dynamicTypeSize.isAccessibilitySize ? 320 : 250
        }

        let rowHeight: CGFloat = dynamicTypeSize.isAccessibilitySize ? 74 : 58
        var height: CGFloat = dynamicTypeSize.isAccessibilitySize ? 196 : 154
        height += CGFloat(request.destinations.count) * rowHeight

        if case .preferredUnavailable = request.decision {
            height += dynamicTypeSize.isAccessibilitySize ? 72 : 48
        }
        if launchError != nil {
            height += dynamicTypeSize.isAccessibilitySize ? 52 : 34
        }
        return min(height, dynamicTypeSize.isAccessibilitySize ? 620 : 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SLDesign.space8) {
            Text("Ask an Assistant")
                .font(SLDesign.titleFont)
                .accessibilityAddTraits(.isHeader)
            Text("Choose where to continue your search.")
                .font(SLDesign.bodyFont)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.assistant.sheet")
    }

    private var unavailableContent: some View {
        VStack(alignment: .leading, spacing: SLDesign.space16) {
            Text("No Assistant Connection Available")
                .font(SLDesign.sectionFont)
                .accessibilityIdentifier("library.assistant.unavailable")
            Text(
                "Install an assistant connection on this Mac. Complete Command Setup before you use "
                    + model.keyboardShortcutAccessibilityLabel(for: .askAssistant)
                    + "."
            )
            .font(SLDesign.bodyFont)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button("Open Assistant Settings") {
                openAssistantSettings()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("library.assistant.open-settings")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func preferredUnavailableNotice(
        _ preferred: AssistantIntegrationTarget
    ) -> some View {
        let message =
            "Your preferred assistant connection, \(preferred.label), is unavailable. Choose another connection for this handoff or review its setup."

        return Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(SLDesign.warning)
        }
        .font(SLDesign.bodyFont)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preferred assistant unavailable")
        .accessibilityValue(message)
    }

    @ViewBuilder
    private var destinationChooser: some View {
        VStack(alignment: .leading, spacing: SLDesign.space8) {
            Text(shouldChooseDestination ? "Choose an assistant" : "Assistant")
                .font(SLDesign.sectionFont)
                .accessibilityAddTraits(.isHeader)

            ForEach(request.destinations) { destination in
                Button {
                    selectedTarget = destination.target
                    launchError = nil
                } label: {
                    HStack(spacing: SLDesign.space8) {
                        AssistantIntegrationIcon(
                            target: destination.target,
                            applicationURL: destination.applicationURL
                        )
                        VStack(alignment: .leading, spacing: SLDesign.space4) {
                            Text(destination.target.label)
                                .font(SLDesign.bodyFont.weight(.medium))
                            Text(deliveryLabel(destination.delivery))
                                .font(SLDesign.metadataFont)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: SLDesign.space8)
                        Image(
                            systemName: selectedTarget == destination.target
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .foregroundStyle(
                            selectedTarget == destination.target ? Color.accentColor : .secondary
                        )
                        .accessibilityHidden(true)
                    }
                    .padding(SLDesign.space8)
                    .contentShape(Rectangle())
                    .background(
                        selectedTarget == destination.target
                            ? Color.accentColor.opacity(0.10)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: SLDesign.thumbRadius)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(destination.target.label)
                .accessibilityValue(deliveryLabel(destination.delivery))
                .accessibilityAddTraits(
                    selectedTarget == destination.target ? .isSelected : []
                )
                .accessibilityIdentifier(
                    "library.assistant.target.\(destination.target.rawValue)"
                )
            }
        }
    }

    private var privacyDisclosure: some View {
        let message =
            "Screenlogger shares only your search words and visible filters with the assistant you choose. Screenlogger never includes results, captured text, or screenshots."

        return Label(message, systemImage: "lock")
            .font(SLDesign.metadataFont)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Handoff privacy")
            .accessibilityValue(message)
    }

    private var routingPreference: some View {
        Picker(
            "Next time",
            selection: $model.libraryAssistantRoutingPreference
        ) {
            Text("Choose automatically").tag(LibraryAssistantRoutingPreference.automatic)
            Text("Ask every time").tag(LibraryAssistantRoutingPreference.askEveryTime)
            Divider()
            ForEach(request.destinations) { destination in
                Text("Use \(destination.target.label)")
                    .tag(LibraryAssistantRoutingPreference.preferred(destination.target))
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("Next time")
        .accessibilityValue(routingPreferenceAccessibilityValue)
        .accessibilityHint("Controls how Screenlogger selects an assistant for future handoffs")
        .accessibilityIdentifier("library.assistant.routing-preference")
    }

    private var routingPreferenceAccessibilityValue: String {
        switch model.libraryAssistantRoutingPreference {
        case .automatic:
            return "Choose automatically"
        case .askEveryTime:
            return "Ask every time"
        case .preferred(let target):
            return "Use \(target.label)"
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                settingsButton
                Spacer()
                decisionButtons
            }

            VStack(alignment: .trailing, spacing: SLDesign.space8) {
                decisionButtons
                settingsButton
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var settingsButton: some View {
        if !request.destinations.isEmpty {
            Button("Assistant Settings") {
                openAssistantSettings()
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("library.assistant.settings")
        }
    }

    private var decisionButtons: some View {
        HStack(spacing: SLDesign.space8) {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isLaunching)
            .accessibilityIdentifier("library.assistant.cancel")

            if let selectedDestination {
                Button {
                    Task { @MainActor in
                        await launch(selectedDestination)
                    }
                } label: {
                    Label(
                        selectedDestination.actionTitle,
                        systemImage: selectedDestination.actionSystemImage
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLaunching)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("library.assistant.continue")
            }
        }
    }

    private var selectedDestination: AssistantHandoffDestination? {
        guard let selectedTarget else { return nil }
        return request.destinations.first { $0.target == selectedTarget }
    }

    private var shouldChooseDestination: Bool {
        switch request.decision {
        case .choose, .preferredUnavailable: return true
        case .unavailable, .route: return false
        }
    }

    private static func initialTarget(
        for decision: LibraryAssistantRoutingDecision
    ) -> AssistantIntegrationTarget? {
        guard case .route(let target) = decision else { return nil }
        return target
    }

    private func deliveryLabel(
        _ delivery: AssistantHandoffDestination.Delivery
    ) -> String {
        switch delivery {
        case .terminalCommand(.claude):
            return "Opens in Terminal. Claude can ask you to trust the handoff workspace once."
        case .terminalCommand(.openClaw): return "Runs one turn in Terminal"
        case .terminalCommand: return "Opens in Terminal"
        case .claudeCodePrefill: return "Opens with the prompt ready"
        case .openClawApproval: return "Opens an approval before starting"
        }
    }

    @MainActor
    private func launch(_ destination: AssistantHandoffDestination) async {
        guard !isLaunching else { return }
        launchError = nil
        isLaunching = true
        defer { isLaunching = false }

        do {
            _ = try await AssistantHandoffLaunchService.launch(
                destination,
                prompt: request.prompt.text
            )
            dismiss()
        } catch let issue as AssistantHandoffLaunchError {
            launchError = issue
        } catch {
            launchError = .couldNotOpenAssistant
        }
    }

    private func openAssistantSettings() {
        let focusedIdentifier = assistantRecoveryTarget.map {
            "settings.integration.\($0.rawValue)"
        }
        dismiss()
        DispatchQueue.main.async {
            model.requestSettingsNavigation(
                to: .integrationsAssistantConnections,
                focusedElementIdentifier: focusedIdentifier
            )
            model.openProductSettings()
        }
    }

    private var assistantRecoveryTarget: AssistantIntegrationTarget? {
        if case .preferredUnavailable(let preferred, _) = request.decision {
            return preferred
        }
        return model.assistantSettingsRecoveryTarget()
    }
}
