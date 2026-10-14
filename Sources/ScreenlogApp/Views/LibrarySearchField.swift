import AppKit
import SwiftUI

/// Native Library search field with Screenlogger's structured-search keyboard contract.
///
/// AppKit owns editing, the cancel button, and the accessibility search-field
/// role. The surrounding SwiftUI control owns the shared matching-menu bezel.
/// The coordinator preserves structured-search keyboard commands.
struct LibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    let placeholder: String
    let isEnabled: Bool
    let onKeyEquivalent: (NSEvent) -> Bool
    let onSubmit: () -> Void
    let onMoveSelection: (Int) -> Bool
    let onTab: (Bool) -> Bool
    let onDeleteWhenEmpty: () -> Bool
    let onEscape: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ScreenloggerSearchField {
        let field = ScreenloggerSearchField()
        field.placeholderString = placeholder
        field.controlSize = .large
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submitFromSearchField(_:))
        field.keyEquivalentHandler = { [weak coordinator = context.coordinator] event in
            coordinator?.parent.onKeyEquivalent(event) == true
        }
        field.setAccessibilityLabel("Search screen history")
        field.setAccessibilityHelp(
            "Type words from the screen. Use the arrow keys or Tab to browse suggestions."
        )
        field.setAccessibilityIdentifier("library.search.field")
        return field
    }

    func updateNSView(_ field: ScreenloggerSearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.isEnabled = isEnabled
        if field.stringValue != text {
            field.stringValue = text
        }

        guard isFocused, field.currentEditor() == nil else { return }
        DispatchQueue.main.async { [weak field] in
            guard let field, field.window != nil else { return }
            field.window?.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: LibrarySearchField

        init(parent: LibrarySearchField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
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
                synchronizeText(from: control)
                parent.onSubmit()
                return true
            case #selector(NSResponder.moveDown(_:)):
                synchronizeText(from: control)
                return parent.onMoveSelection(1)
            case #selector(NSResponder.moveUp(_:)):
                synchronizeText(from: control)
                return parent.onMoveSelection(-1)
            case #selector(NSResponder.insertTab(_:)):
                synchronizeText(from: control)
                return parent.onTab(false)
            case #selector(NSResponder.insertBacktab(_:)):
                synchronizeText(from: control)
                return parent.onTab(true)
            case #selector(NSResponder.deleteBackward(_:)):
                synchronizeText(from: control)
                return control.stringValue.isEmpty && parent.onDeleteWhenEmpty()
            case #selector(NSResponder.cancelOperation(_:)):
                synchronizeText(from: control)
                return parent.onEscape()
            default:
                return false
            }
        }

        @objc func submitFromSearchField(_ sender: NSSearchField) {
            synchronizeText(from: sender)
            parent.onSubmit()
        }

        private func synchronizeText(from control: NSControl) {
            guard parent.text != control.stringValue else { return }
            parent.text = control.stringValue
        }
    }
}

final class ScreenloggerSearchField: NSSearchField {
    var keyEquivalentHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Shift-modified printable characters (notably the colon in `app:`)
        // must reach the field editor as normal text. Restrict custom key
        // equivalent handling to actual command shortcuts.
        if event.modifierFlags.intersection([.command, .control]).isEmpty {
            return false
        }
        if keyEquivalentHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
