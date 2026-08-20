import AppKit
import ScreenlogCore
import SwiftUI

/// Window-scoped keyboard routing for Timeline navigation and playback.
/// Events remain untouched unless the Timeline is visible, key, and owns the
/// event, so normal editing and other Screenlogger windows keep native behavior.
struct TimelineKeyMonitor: NSViewRepresentable {
    let shortcuts: [KeyboardShortcutActionID: KeyboardShortcutBinding]
    let onSlash: () -> Void
    var onEscape: (() -> Void)?
    var onCommandK: (() -> Void)?
    var onStepBack: (() -> Void)?
    var onStepForward: (() -> Void)?
    var onPreviousSegment: (() -> Void)?
    var onNextSegment: (() -> Void)?
    var onToggleReplay: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onResetZoom: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = KeyCatcherView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? KeyCatcherView else { return }
        update(view)
    }

    private func update(_ view: KeyCatcherView) {
        view.shortcuts = shortcuts
        view.onSlash = onSlash
        view.onEscape = onEscape
        view.onCommandK = onCommandK
        view.onStepBack = onStepBack
        view.onStepForward = onStepForward
        view.onPreviousSegment = onPreviousSegment
        view.onNextSegment = onNextSegment
        view.onToggleReplay = onToggleReplay
        view.onZoomIn = onZoomIn
        view.onZoomOut = onZoomOut
        view.onResetZoom = onResetZoom
    }

    final class KeyCatcherView: NSView {
        var shortcuts: [KeyboardShortcutActionID: KeyboardShortcutBinding] = [:]
        var onSlash: (() -> Void)?
        var onEscape: (() -> Void)?
        var onCommandK: (() -> Void)?
        var onStepBack: (() -> Void)?
        var onStepForward: (() -> Void)?
        var onPreviousSegment: (() -> Void)?
        var onNextSegment: (() -> Void)?
        var onToggleReplay: (() -> Void)?
        var onZoomIn: (() -> Void)?
        var onZoomOut: (() -> Void)?
        var onResetZoom: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tearDown()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                    let window = self.window,
                    window.isVisible,
                    window.isKeyWindow,
                    event.windowNumber == window.windowNumber
                else { return event }

                if event.keyCode == 53,
                    !event.isARepeat,
                    event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                    window.attachedSheet == nil,
                    !self.isEditingTextField
                {
                    DispatchQueue.main.async { self.onEscape?() }
                    return nil
                }

                if self.matches(.searchLibrary, event) {
                    DispatchQueue.main.async { self.onCommandK?() }
                    return nil
                }
                if self.matches(.timelineZoomIn, event) {
                    DispatchQueue.main.async { self.onZoomIn?() }
                    return nil
                }
                if self.matches(.timelineZoomOut, event) {
                    DispatchQueue.main.async { self.onZoomOut?() }
                    return nil
                }
                if self.matches(.timelineResetZoom, event) {
                    DispatchQueue.main.async { self.onResetZoom?() }
                    return nil
                }
                if self.matches(.timelinePreviousActivity, event) {
                    guard !self.isEditingTextField else { return event }
                    DispatchQueue.main.async { self.onPreviousSegment?() }
                    return nil
                }
                if self.matches(.timelineNextActivity, event) {
                    guard !self.isEditingTextField else { return event }
                    DispatchQueue.main.async { self.onNextSegment?() }
                    return nil
                }
                if self.matches(.timelinePreviousMoment, event) {
                    guard self.timelineContentOwnsBareKeyboardShortcuts else { return event }
                    DispatchQueue.main.async { self.onStepBack?() }
                    return nil
                }
                if self.matches(.timelineNextMoment, event) {
                    guard self.timelineContentOwnsBareKeyboardShortcuts else { return event }
                    DispatchQueue.main.async { self.onStepForward?() }
                    return nil
                }
                if self.matches(.timelineToggleReplay, event), !event.isARepeat {
                    guard self.timelineContentOwnsBareKeyboardShortcuts else { return event }
                    DispatchQueue.main.async { self.onToggleReplay?() }
                    return nil
                }
                if self.matches(.timelineFilter, event), !event.isARepeat {
                    guard !self.isEditingTextField else { return event }
                    DispatchQueue.main.async {
                        self.onSlash?()
                    }
                    return nil
                }
                return event
            }
        }

        override func removeFromSuperview() {
            tearDown()
            super.removeFromSuperview()
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func tearDown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func matches(
            _ actionID: KeyboardShortcutActionID,
            _ event: NSEvent
        ) -> Bool {
            shortcuts[actionID]?.matches(event) == true
        }

        private var isEditingTextField: Bool {
            guard let firstResponder = window?.firstResponder else { return false }
            return firstResponder is NSTextView || firstResponder is NSTextField
        }

        /// Bare navigation keys are also native activation and traversal keys
        /// under Full Keyboard Access. Route them to Timeline only while focus
        /// remains on non-interactive content such as the captured moment or
        /// the window background; focused controls receive the original event.
        private var timelineContentOwnsBareKeyboardShortcuts: Bool {
            guard !isEditingTextField else { return false }

            // Popovers are temporary control surfaces. Even before one of
            // their controls becomes first responder, native activation keys
            // belong to the popover rather than Timeline playback.
            if window?.childWindows?.contains(where: { $0.isVisible }) == true {
                return false
            }

            if let firstResponder = window?.firstResponder,
                Self.isInteractiveResponder(firstResponder)
            {
                return false
            }

            let roles = focusedAccessibilityRoles
            if roles.contains(where: Self.interactiveAccessibilityRoles.contains) {
                return false
            }
            guard let role = roles.first else { return true }
            return Self.timelineContentRoles.contains(role)
        }

        private var focusedAccessibilityRoles: [NSAccessibility.Role] {
            var roles: [NSAccessibility.Role] = []
            var candidate: Any? = NSApp.accessibilityFocusedUIElement
            for _ in 0..<8 {
                if let element = candidate as? NSAccessibilityElement {
                    if let role = element.accessibilityRole() { roles.append(role) }
                    candidate = element.accessibilityParent()
                } else if let view = candidate as? NSView {
                    if let role = view.accessibilityRole() { roles.append(role) }
                    candidate = view.accessibilityParent()
                } else {
                    break
                }
            }
            return roles
        }

        private static func isInteractiveResponder(_ responder: NSResponder) -> Bool {
            responder is NSControl
                || responder is NSTextView
                || responder is NSTableView
                || responder is NSCollectionView
                || responder is NSBrowser
        }

        private static let timelineContentRoles: Set<NSAccessibility.Role> = [
            .application,
            .group,
            .image,
            .staticText,
            .window,
        ]

        private static let interactiveAccessibilityRoles: Set<NSAccessibility.Role> = [
            .button,
            .checkBox,
            .comboBox,
            .menu,
            .menuButton,
            .menuItem,
            .popUpButton,
            .radioButton,
            .slider,
            .textField,
        ]
    }
}
