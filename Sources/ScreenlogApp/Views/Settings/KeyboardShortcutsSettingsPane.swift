import AppKit
import ScreenlogCore
import SwiftUI

/// A first-class editor for every product command in the shared shortcut registry.
/// Native control behavior such as a dialog's Return and Escape actions remains
/// owned by that control and is intentionally absent from this pane.
struct KeyboardShortcutsSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var recordingActionID: KeyboardShortcutActionID?
    @State private var feedback: ShortcutEditingFeedback?
    @State private var isConfirmingResetAll = false

    var body: some View {
        SettingsSectionStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(
                        "Select a shortcut, then press the keys you want to use. "
                            + "Changes apply immediately."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 12)

                    Button("Reset All") {
                        cancelRecording()
                        isConfirmingResetAll = true
                    }
                    .disabled(!hasCustomShortcuts)
                    .accessibilityHint("Restore every Screenlogger shortcut to its default")
                    .accessibilityIdentifier("settings.shortcuts.reset-all")
                }

                if let feedback, feedback.actionID == nil {
                    Label(feedback.message, systemImage: feedback.tone.systemImage)
                        .font(.caption)
                        .foregroundStyle(feedback.tone.color)
                        .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 4)

            ForEach(KeyboardShortcutCategory.allCases, id: \.self) { category in
                let definitions = definitions(in: category)
                if !definitions.isEmpty {
                    shortcutGroup(category, definitions: definitions)
                }
            }
        }
        .background(
            ShortcutRecordingMonitor(
                isActive: recordingActionID != nil,
                onKeyDown: record,
                onCancel: cancelRecording
            )
        )
        .confirmationDialog(
            "Reset all keyboard shortcuts?",
            isPresented: $isConfirmingResetAll
        ) {
            Button("Reset All") {
                model.resetAllKeyboardShortcuts()
                feedback = ShortcutEditingFeedback(
                    actionID: nil,
                    message: "All shortcuts were restored to their defaults.",
                    tone: .success
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This restores every custom or disabled shortcut to its default key combination.")
        }
        .accessibilityIdentifier("settings.shortcuts")
    }

    private func shortcutGroup(
        _ category: KeyboardShortcutCategory,
        definitions: [KeyboardShortcutDefinition]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(category.title, systemImage: category.systemImage)
                    .font(.headline)
                Text(category.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            SettingsCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(definitions.enumerated()), id: \.element.id) { index, definition in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 14)
                        }
                        shortcutRow(definition)
                    }
                }
            }
        }
        .accessibilityIdentifier("settings.shortcuts.group.\(category.rawValue)")
    }

    private func shortcutRow(_ definition: KeyboardShortcutDefinition) -> some View {
        let binding = model.keyboardShortcutBinding(for: definition.id)
        let isRecording = recordingActionID == definition.id
        let isCustomized = binding != definition.defaultBinding
        let rowFeedback = feedback?.actionID == definition.id ? feedback : nil

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(definition.title)
                        .font(.system(size: 13, weight: .medium))
                    Text(definition.subtitle ?? definition.scope.settingsDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                shortcutRecorderButton(
                    definition: definition,
                    binding: binding,
                    isRecording: isRecording
                )

                Button {
                    reset(definition)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .opacity(isCustomized ? 1 : 0)
                .disabled(!isCustomized)
                .accessibilityHidden(!isCustomized)
                .help("Reset \(definition.title) to \(definition.defaultBinding.displayLabel)")
                .accessibilityLabel("Reset \(definition.title)")
                .accessibilityHint(
                    "Restore the default shortcut, \(definition.defaultBinding.accessibilityLabel)"
                )
                .accessibilityIdentifier("settings.shortcuts.\(definition.id.rawValue).reset")

                Menu {
                    Button("Disable Shortcut") {
                        disable(definition)
                    }
                    .disabled(binding == nil)

                    Divider()

                    Button("Reset to Default") {
                        reset(definition)
                    }
                    .disabled(!isCustomized)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More options for \(definition.title)")
                .accessibilityLabel("More options for \(definition.title)")
                .accessibilityIdentifier("settings.shortcuts.\(definition.id.rawValue).menu")
            }

            if let rowFeedback {
                Label(rowFeedback.message, systemImage: rowFeedback.tone.systemImage)
                    .font(.caption)
                    .foregroundStyle(rowFeedback.tone.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.shortcuts.\(definition.id.rawValue).feedback")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.shortcuts.\(definition.id.rawValue)")
    }

    private func shortcutRecorderButton(
        definition: KeyboardShortcutDefinition,
        binding: KeyboardShortcutBinding?,
        isRecording: Bool
    ) -> some View {
        Button {
            if isRecording {
                cancelRecording()
            } else {
                feedback = nil
                recordingActionID = definition.id
            }
        } label: {
            Text(isRecording ? "Press shortcut..." : binding?.displayLabel ?? "Not Set")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .frame(width: 108)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isRecording
                                ? Color.accentColor.opacity(0.11)
                                : Color.primary.opacity(0.055)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isRecording
                                ? Color.accentColor.opacity(0.8)
                                : Color.primary.opacity(0.1),
                            lineWidth: isRecording ? 1.5 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Press a new shortcut, or Escape to cancel" : "Change this shortcut")
        .accessibilityLabel("Shortcut for \(definition.title)")
        .accessibilityValue(
            isRecording
                ? "Recording"
                : binding?.accessibilityLabel ?? "No shortcut assigned"
        )
        .accessibilityHint(
            isRecording
                ? "Press a new shortcut. Press Escape to cancel recording."
                : "Start recording a new shortcut"
        )
        .accessibilityIdentifier("settings.shortcuts.\(definition.id.rawValue).recorder")
    }

    private var hasCustomShortcuts: Bool {
        model.keyboardShortcutDefinitions.contains { definition in
            model.keyboardShortcutBinding(for: definition.id) != definition.defaultBinding
        }
    }

    private func definitions(
        in category: KeyboardShortcutCategory
    ) -> [KeyboardShortcutDefinition] {
        model.keyboardShortcutDefinitions.filter { $0.category == category }
    }

    private func record(_ event: NSEvent) {
        guard let actionID = recordingActionID,
            let definition = model.keyboardShortcutDefinitions.first(where: { $0.id == actionID })
        else {
            cancelRecording()
            return
        }

        guard let binding = KeyboardShortcutEventAdapter.binding(from: event) else {
            feedback = ShortcutEditingFeedback(
                actionID: actionID,
                message: "That key can't be used as a shortcut. Try a letter, number, symbol, arrow, or navigation key.",
                tone: .error
            )
            return
        }

        if case .invalid(let issue) = model.keyboardShortcutValidationResult(
            for: binding,
            assignedTo: actionID
        ) {
            feedback = ShortcutEditingFeedback(
                actionID: actionID,
                message: validationMessage(for: issue),
                tone: .error
            )
            return
        }

        let conflicts = model.keyboardShortcutConflicts(for: binding, assignedTo: actionID)
        guard conflicts.isEmpty else {
            let titles = Set(
                conflicts.compactMap { conflict in
                    model.keyboardShortcutDefinitions.first(where: {
                        $0.id == conflict.conflictingActionID
                    })?.title
                }
            ).sorted()
            feedback = ShortcutEditingFeedback(
                actionID: actionID,
                message: conflictMessage(binding: binding, titles: titles),
                tone: .error
            )
            return
        }

        do {
            try model.setKeyboardShortcut(binding, for: definition.id)
            recordingActionID = nil
            feedback = ShortcutEditingFeedback(
                actionID: definition.id,
                message: "Changed to \(binding.accessibilityLabel).",
                tone: .success
            )
        } catch let KeyboardShortcutStoreError.invalidBinding(_, issue) {
            feedback = ShortcutEditingFeedback(
                actionID: definition.id,
                message: validationMessage(for: issue),
                tone: .error
            )
        } catch {
            feedback = ShortcutEditingFeedback(
                actionID: definition.id,
                message: "Screenlogger couldn't save that shortcut. Try another combination.",
                tone: .error
            )
        }
    }

    private func conflictMessage(
        binding: KeyboardShortcutBinding,
        titles: [String]
    ) -> String {
        guard !titles.isEmpty else {
            return "\(binding.accessibilityLabel) is already assigned to another command."
        }
        return "\(binding.accessibilityLabel) is already assigned to \(titles.joined(separator: ", "))."
    }

    private func validationMessage(for issue: KeyboardShortcutValidationIssue) -> String {
        switch issue {
        case .requiresCommandOptionOrControl:
            return "Add Command, Option, or Control so this shortcut doesn't interrupt typing."
        case .reservedMacOSShortcut(.editing):
            return "That shortcut is reserved for standard text editing."
        case .reservedMacOSShortcut(.windowManagement):
            return "That shortcut is reserved for macOS window management."
        case .reservedMacOSShortcut(.system):
            return "That shortcut is reserved by macOS or a standard app command."
        case .unsupportedKey:
            return "That key isn't supported. Try a letter, number, symbol, arrow, or navigation key."
        case .unregisteredAction:
            return "That Screenlogger command is no longer available. Reopen Settings and try again."
        }
    }

    private func disable(_ definition: KeyboardShortcutDefinition) {
        cancelRecording()
        do {
            try model.setKeyboardShortcut(nil, for: definition.id)
            feedback = ShortcutEditingFeedback(
                actionID: definition.id,
                message: "Shortcut disabled.",
                tone: .success
            )
        } catch {
            feedback = ShortcutEditingFeedback(
                actionID: definition.id,
                message: "Screenlogger couldn't disable that shortcut.",
                tone: .error
            )
        }
    }

    private func reset(_ definition: KeyboardShortcutDefinition) {
        cancelRecording()
        do {
            try model.resetKeyboardShortcut(for: definition.id)
            feedback = ShortcutEditingFeedback(
                actionID: definition.id,
                message: "Restored \(definition.defaultBinding.accessibilityLabel).",
                tone: .success
            )
        } catch let KeyboardShortcutStoreError.conflicts(conflicts) {
            let titles = Set(
                conflicts.compactMap { conflict in
                    model.keyboardShortcutDefinitions.first(where: {
                        $0.id == conflict.conflictingActionID
                    })?.title
                }
            ).sorted()
            feedback = ShortcutEditingFeedback(
                actionID: definition.id,
                message: conflictMessage(binding: definition.defaultBinding, titles: titles),
                tone: .error
            )
        } catch {
            feedback = ShortcutEditingFeedback(
                actionID: definition.id,
                message: "Screenlogger couldn't restore that shortcut.",
                tone: .error
            )
        }
    }

    private func cancelRecording() {
        recordingActionID = nil
        if feedback?.tone == .error {
            feedback = nil
        }
    }
}

private struct ShortcutEditingFeedback {
    let actionID: KeyboardShortcutActionID?
    let message: String
    let tone: Tone

    enum Tone: Equatable {
        case success
        case error

        var color: Color {
            switch self {
            case .success: return SLDesign.success
            case .error: return Color(nsColor: .systemRed)
            }
        }

        var systemImage: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .error: return "exclamationmark.triangle.fill"
            }
        }
    }
}

extension KeyboardShortcutCategory {
    fileprivate var title: String {
        switch self {
        case .navigation: return "Navigation"
        case .library: return "Library"
        case .capture: return "Capture"
        case .timeline: return "Timeline"
        case .application: return "Application"
        }
    }

    fileprivate var detail: String {
        switch self {
        case .navigation: return "Move between Screenlogger windows."
        case .library: return "Find history and ask an assistant."
        case .capture: return "Control recording from any Screenlogger window."
        case .timeline: return "Browse and inspect captured moments."
        case .application: return "Control the Screenlogger app."
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .navigation: return "rectangle.3.group"
        case .library: return "books.vertical"
        case .capture: return "record.circle"
        case .timeline: return "clock"
        case .application: return "app"
        }
    }
}

extension KeyboardShortcutScope {
    fileprivate var settingsDetail: String {
        switch self {
        case .application: return "Works throughout Screenlogger"
        case .library: return "Works while Library is active"
        case .timeline: return "Works while Timeline is active"
        }
    }
}

/// Installs a window-scoped key monitor only while a recorder is active. Local
/// monitoring happens before menu key-equivalent dispatch, so Command shortcuts
/// can be recorded without accidentally invoking the existing command.
private struct ShortcutRecordingMonitor: NSViewRepresentable {
    let isActive: Bool
    let onKeyDown: (NSEvent) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.update(parent: self, view: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(parent: self, view: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        private var parent: ShortcutRecordingMonitor
        private weak var view: NSView?
        private var monitor: Any?

        init(parent: ShortcutRecordingMonitor) {
            self.parent = parent
        }

        func update(parent: ShortcutRecordingMonitor, view: NSView) {
            self.parent = parent
            self.view = view
            if parent.isActive {
                installMonitorIfNeeded()
            } else {
                removeMonitor()
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                    self.parent.isActive,
                    let monitoredWindow = self.view?.window,
                    event.window === monitoredWindow
                else {
                    return event
                }

                if event.keyCode == 53 {
                    self.parent.onCancel()
                } else {
                    self.parent.onKeyDown(event)
                }
                return nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}
