import AppKit
import SwiftUI

/// A native sidebar search field with an explicit keyboard contract.
///
/// SwiftUI's sidebar `.searchable` placement does not consistently forward
/// Return and Escape through `onSubmit`/`onExitCommand` on macOS. Owning the
/// `NSSearchField` delegate keeps familiar AppKit behavior deterministic while
/// retaining the standard search appearance, cancel button, and accessibility
/// role.
struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onMoveSelection: (Int) -> Void
    let onEscape: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search Settings"
        field.controlSize = .regular
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.focusRingType = .default
        // The binding is kept current by `controlTextDidChange`. The field's
        // action is reserved for an explicit Return/Enter or search-button
        // activation; sending it for every keystroke would open a result while
        // the user is still typing.
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submitFromSearchField(_:))
        field.setAccessibilityIdentifier("settings.search.field")
        field.setAccessibilityHelp(
            "Type to find a setting. Use the arrow keys to select a result. Press Return to open it. Press Escape to clear the search."
        )
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SettingsSearchField

        init(parent: SettingsSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            synchronizeText(from: field)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                #selector(NSResponder.insertLineBreak(_:)),
                #selector(NSResponder.insertParagraphSeparator(_:)):
                submit(from: control)
                return true
            case #selector(NSResponder.moveDown(_:)):
                synchronizeText(from: control)
                parent.onMoveSelection(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                synchronizeText(from: control)
                parent.onMoveSelection(-1)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                let handledByParent = parent.onEscape()
                guard handledByParent || !control.stringValue.isEmpty else { return false }
                control.stringValue = ""
                parent.text = ""
                return true
            default:
                return false
            }
        }

        @objc func submitFromSearchField(_ sender: NSSearchField) {
            submit(from: sender)
        }

        private func submit(from control: NSControl) {
            synchronizeText(from: control)

            // SwiftUI may not have rebuilt the representable between the last
            // text-change callback and the Return event. Deferring activation
            // by one run-loop turn guarantees the search state and result list
            // observe the field's complete value.
            DispatchQueue.main.async { [weak self] in
                self?.parent.onSubmit()
            }
        }

        private func synchronizeText(from control: NSControl) {
            guard parent.text != control.stringValue else { return }
            parent.text = control.stringValue
        }
    }
}

/// Stock AppKit search field for in-page filtering. Keeping this separate from
/// ordinary text entry makes "add" and "find" actions visually unmistakable.
struct NativeFilterSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityIdentifier: String
    var accessibilityHelp: String? = nil
    var focusRequested: Binding<Bool>? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.controlSize = .regular
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.focusRingType = .default
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        if let accessibilityHelp {
            field.setAccessibilityHelp(accessibilityHelp)
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if focusRequested?.wrappedValue == true,
            field.window?.firstResponder !== field.currentEditor()
        {
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.selectText(nil)
                focusRequested?.wrappedValue = false
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeFilterSearchField

        init(parent: NativeFilterSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField,
                parent.text != field.stringValue
            else { return }
            parent.text = field.stringValue
        }
    }
}
