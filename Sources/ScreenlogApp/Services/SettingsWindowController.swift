import AppKit
import SwiftUI

/// Dedicated app-owned Settings window (in addition to SwiftUI's Settings scene).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private static let frameAutosaveName = "ScreenloggerSettingsWindow"

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    var isVisible: Bool {
        window?.isVisible == true && window?.isMiniaturized == false
    }

    func show(model: AppModel, destination: SettingsDestination? = nil) {
        if let destination {
            model.requestSettingsNavigation(to: destination)
        }

        // Match shell: allow key windows under accessory policy.
        if model.showDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }

        if let window {
            window.title = "Settings"
            enforceWindowSizeContract(on: window)
            NSApp.activate(ignoringOtherApps: true)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = SettingsView()
            .environmentObject(model)

        let hosting = NSHostingController(rootView: root)
        // AppKit owns the Settings size contract. SwiftUI still adapts to the
        // actual bounds, but cannot replace the native minimum or maximum with
        // a transient fitting size from whichever pane is currently visible.
        hosting.sizingOptions = []
        let win = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: SettingsWindowLayout.defaultContentSize
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Settings"
        // Let AppKit own the titlebar while the split-view sidebar extends
        // underneath it, matching native macOS preference windows.
        win.titleVisibility = .visible
        win.titlebarAppearsTransparent = true
        win.titlebarSeparatorStyle = .automatic
        win.toolbarStyle = .unified
        // The controller retains this window so close/reopen routes reuse the
        // same native Settings workspace and its selected pane.
        win.isReleasedWhenClosed = false
        win.contentViewController = hosting
        // These describe the content area, not the complete frame. Apply them
        // after attaching the host so they remain authoritative.
        win.contentMinSize = SettingsWindowLayout.minimumContentSize
        win.contentMaxSize = NSSize(
            width: SettingsWindowLayout.maximumContentWidth,
            height: .greatestFiniteMagnitude
        )
        // A saved user frame can still replace this first-open size below.
        win.setContentSize(SettingsWindowLayout.defaultContentSize)
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.level = .normal
        win.backgroundColor = NSColor.windowBackgroundColor
        #if DEBUG
            let allowsLegacyFrameMigration = !AppUITestFixture.isAuthenticatedRoutedTest
        #else
            let allowsLegacyFrameMigration = true
        #endif
        let restoredFrame = ProductWindowFrameStore.restore(
            win,
            name: Self.frameAutosaveName,
            allowsLegacyAppKitMigration: allowsLegacyFrameMigration
        )
        let constrainedRestoredFrame = enforceWindowSizeContract(on: win)
        if restoredFrame, constrainedRestoredFrame {
            ProductWindowFrameStore.save(win, name: Self.frameAutosaveName)
        }

        // Float near the main shell on first use; later openings restore the
        // frame selected by the user.
        if !restoredFrame, let shell = MainShellController.shared.windowFrame {
            var origin = NSPoint(
                x: shell.midX - win.frame.width / 2,
                y: shell.midY - win.frame.height / 2
            )
            if let screen = NSScreen.main {
                let vis = screen.visibleFrame
                origin.x = min(max(vis.minX + 24, origin.x), vis.maxX - win.frame.width - 24)
                origin.y = min(max(vis.minY + 24, origin.y), vis.maxY - win.frame.height - 24)
            }
            win.setFrameOrigin(origin)
        } else if !restoredFrame {
            win.center()
        }

        win.delegate = self

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }

    func hide() {
        window?.orderOut(nil)
    }

    func toggle(model: AppModel, destination: SettingsDestination? = nil) {
        if isVisible, destination == nil {
            hide()
        } else {
            show(model: model, destination: destination)
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let window else { return }
        ProductWindowFrameStore.save(window, name: Self.frameAutosaveName)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window else { return }
        enforceWindowSizeContract(on: window)
        ProductWindowFrameStore.save(window, name: Self.frameAutosaveName)
    }

    /// Clamps stale or inherited wide frames while keeping the window centered
    /// around the position the user chose. AppKit continues to own normal
    /// resizing within this compact Settings contract.
    @discardableResult
    private func enforceWindowSizeContract(on window: NSWindow) -> Bool {
        window.contentMinSize = SettingsWindowLayout.minimumContentSize
        window.contentMaxSize = NSSize(
            width: SettingsWindowLayout.maximumContentWidth,
            height: .greatestFiniteMagnitude
        )

        let originalFrame = window.frame
        let proposedContentSize = window.contentRect(forFrameRect: originalFrame).size
        let constrainedContentSize = SettingsWindowLayout.constrainedContentSize(
            proposedContentSize
        )
        guard proposedContentSize != constrainedContentSize else { return false }

        window.setContentSize(constrainedContentSize)
        var constrainedFrame = window.frame
        constrainedFrame.origin.x = SettingsWindowLayout.centeredOriginX(
            originalFrame: originalFrame,
            constrainedFrameWidth: constrainedFrame.width
        )
        constrainedFrame.origin.y = originalFrame.maxY - constrainedFrame.height
        let screen = window.screen ?? NSScreen.main
        constrainedFrame = window.constrainFrameRect(constrainedFrame, to: screen)
        window.setFrame(constrainedFrame, display: false)
        return true
    }

}
