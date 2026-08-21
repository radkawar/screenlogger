import AppKit
import SwiftUI

/// First-class Timeline window; search remains a separate Library window.
@MainActor
final class MainShellController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = MainShellController()
    private static let frameAutosaveName = "ScreenloggerTimelineWindow"
    private static let toolbarIdentifier = NSToolbar.Identifier("ScreenloggerTimelineToolbar")
    private static let contextItemIdentifier = NSToolbarItem.Identifier("ScreenloggerTimelineContext")
    private static let captureItemIdentifier = NSToolbarItem.Identifier("ScreenloggerTimelineCapture")
    private static let libraryItemIdentifier = NSToolbarItem.Identifier("ScreenloggerTimelineLibrary")
    private static let settingsItemIdentifier = NSToolbarItem.Identifier("ScreenloggerTimelineSettings")

    private var window: NSWindow?
    private weak var model: AppModel?
    private weak var libraryButton: NSButton?

    private override init() {
        super.init()
    }

    var isVisible: Bool {
        window?.isVisible == true && window?.isMiniaturized == false
    }

    var isMiniaturized: Bool {
        window?.isMiniaturized == true
    }

    /// Frame of the floating shell (for positioning Settings nearby).
    var windowFrame: NSRect? {
        window?.frame
    }

    func show(model: AppModel, focusSearch: Bool = false) {
        #if DEBUG
            AppUITestFixture.installIfRequested(on: model)
        #endif
        self.model = model
        updateLibraryButton()
        model.shellVisible = true
        // Ensure windows can become key under LSUIElement / accessory policy.
        if model.showDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
        if let window {
            enforceWorkspaceMinimum(on: window)
            NSApp.activate(ignoringOtherApps: true)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            if focusSearch {
                SearchWindowController.shared.show(model: model)
            }
            return
        }

        let root = MainShellView()
            .environmentObject(model)

        let hosting = NSHostingController(rootView: root)
        // The Timeline has fixed-size transport controls and context that can
        // legitimately be wider than the workspace minimum in their ideal
        // layout. NSHostingController's default `.standardBounds` propagates
        // that dynamic SwiftUI minimum back to its owning NSWindow, which can
        // silently replace `contentMinSize` and prevent native window resizing.
        // AppKit owns this window's size contract; SwiftUI still receives and
        // adapts to the actual content bounds through the hosting controller.
        hosting.sizingOptions = []
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Timeline"
        // Keep the descriptive window title for Window menu, VoiceOver, and
        // UI automation, while the unified toolbar owns the visible chrome.
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.titlebarSeparatorStyle = .automatic
        win.toolbarStyle = .unified
        win.toolbar = makeToolbar()
        win.isReleasedWhenClosed = false
        win.backgroundColor = NSColor.windowBackgroundColor
        win.contentViewController = hosting
        // Match the SwiftUI root's content minimum. `minSize` is measured in
        // frame coordinates and would subtract the titlebar from usable space.
        // Apply this after installing the host so it remains the authoritative
        // AppKit window contract.
        win.contentMinSize = SLDesign.workspaceMinimumSize
        // Assigning a hosting controller adopts its fitting size. Restore the
        // intended first-open workspace afterwards; frame autosave may still
        // replace it below for returning users.
        win.setContentSize(NSSize(width: 1080, height: 760))
        win.delegate = self
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace]
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
        if !restoredFrame {
            win.center()
        }

        // Bring accessory app forward so the floating shell is usable.
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        self.window = win
        // The native toolbar completes one more sizing pass after the window
        // is ordered. Reassert the product contract after that pass so custom
        // item fitting widths cannot become a permanent window minimum.
        DispatchQueue.main.async { [weak self, weak win] in
            guard let self, let win, self.window === win else { return }
            self.enforceWorkspaceMinimum(on: win)
        }

        // Search is a separate window and must be ordered last when requested,
        // otherwise a first launch leaves Timeline key and the search field
        // cannot receive typing despite `focusSearch` being true.
        if focusSearch {
            SearchWindowController.shared.show(model: model)
        }
    }

    func hide() {
        window?.orderOut(nil)
        model?.shellVisible = false
        model?.timelineNavigationOrigin = .direct
        model?.stopReplay()
    }

    func toggle(model: AppModel) {
        if isVisible {
            hide()
        } else {
            show(model: model)
        }
    }

    func windowWillClose(_ notification: Notification) {
        model?.shellVisible = false
        model?.timelineNavigationOrigin = .direct
        model?.stopReplay()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window {
            enforceWorkspaceMinimum(on: window)
        }
        model?.shellVisible = true
        model?.shellSearchMode = false
        model?.showSearchOperatorMenu = false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        model?.shellVisible = false
        model?.stopReplay()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        model?.shellVisible = true
    }

    func windowDidMove(_ notification: Notification) {
        guard let window else { return }
        ProductWindowFrameStore.save(window, name: Self.frameAutosaveName)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window else { return }
        enforceWorkspaceMinimum(on: window)
        ProductWindowFrameStore.save(window, name: Self.frameAutosaveName)
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        return toolbar
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.contextItemIdentifier,
            .flexibleSpace,
            Self.captureItemIdentifier,
            Self.libraryItemIdentifier,
            Self.settingsItemIdentifier,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.contextItemIdentifier,
            .flexibleSpace,
            Self.captureItemIdentifier,
            Self.libraryItemIdentifier,
            Self.settingsItemIdentifier,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let model else { return nil }

        switch itemIdentifier {
        case Self.contextItemIdentifier:
            return hostingToolbarItem(
                identifier: itemIdentifier,
                label: "Timeline",
                view: AnyView(
                    TimelineToolbarContextView()
                        .environmentObject(model)
                ),
                minimumWidth: 132,
                maximumWidth: 560,
                priority: .standard
            )
        case Self.captureItemIdentifier:
            return hostingToolbarItem(
                identifier: itemIdentifier,
                label: "Capture Status",
                view: AnyView(
                    TimelineToolbarActionsView()
                        .environmentObject(model)
                ),
                minimumWidth: 148,
                maximumWidth: 360,
                priority: .high
            )
        case Self.libraryItemIdentifier:
            return libraryToolbarItem(identifier: itemIdentifier)
        case Self.settingsItemIdentifier:
            return navigationToolbarItem(
                identifier: itemIdentifier,
                title: "Settings",
                symbolName: "gearshape",
                action: #selector(showSettings(_:)),
                accessibilityIdentifier: "navigation.timeline.settings"
            )
        default:
            return nil
        }
    }

    private func hostingToolbarItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        view: AnyView,
        minimumWidth: CGFloat,
        maximumWidth: CGFloat,
        priority: NSToolbarItem.VisibilityPriority
    ) -> NSToolbarItem {
        let hostingView = NSHostingView(rootView: view)
        // The selected moment and capture state both change while this window
        // remains open. Intrinsic sizing lets AppKit remeasure those updates
        // instead of clipping them to the initial `fittingSize` frame.
        hostingView.sizingOptions = [.intrinsicContentSize]
        // A custom toolbar view otherwise treats its unconstrained SwiftUI
        // fitting width as non-compressible. Give AppKit a truthful lower
        // bound so it can propose narrower widths and let the hosted
        // ViewThatFits choose compact, still-functional toolbar variants.
        hostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth),
            hostingView.widthAnchor.constraint(lessThanOrEqualToConstant: maximumWidth),
            hostingView.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.view = hostingView
        // These composite context groups are not single bordered actions.
        // Keeping them unbordered preserves legibility over adaptive titlebar
        // materials, including Liquid Glass on newer macOS releases.
        item.isBordered = false
        item.visibilityPriority = priority
        return item
    }

    private func libraryToolbarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = navigationToolbarItem(
            identifier: identifier,
            title: "Library",
            symbolName: "books.vertical",
            action: #selector(showLibrary(_:)),
            accessibilityIdentifier: "navigation.timeline.library"
        )
        libraryButton = item.view as? NSButton
        updateLibraryButton()
        return item
    }

    private func navigationToolbarItem(
        identifier: NSToolbarItem.Identifier,
        title: String,
        symbolName: String,
        action: Selector,
        accessibilityIdentifier: String
    ) -> NSToolbarItem {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .toolbar
        button.controlSize = .small
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.setAccessibilityLabel("Show \(title)")

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = title
        item.paletteLabel = title
        item.toolTip = "Show \(title)"
        item.view = button
        item.visibilityPriority = .high
        return item
    }

    private func updateLibraryButton() {
        guard let libraryButton, let model else { return }
        let returnsToSearch = model.timelineNavigationOrigin.returnsToLibrary
        let title = returnsToSearch ? "Back to Library" : "Library"
        libraryButton.title = title
        libraryButton.image = NSImage(
            systemSymbolName: returnsToSearch ? "chevron.left" : "books.vertical",
            accessibilityDescription: title
        )
        libraryButton.toolTip =
            returnsToSearch
            ? "Return to your Library search and filters"
            : "Show Library"
        libraryButton.setAccessibilityLabel(title)
        libraryButton.setAccessibilityIdentifier(
            returnsToSearch
                ? "navigation.timeline.back-to-search"
                : "navigation.timeline.library"
        )
    }

    @objc private func showLibrary(_ sender: Any?) {
        guard let model else { return }
        if model.timelineNavigationOrigin.returnsToLibrary {
            model.returnToLibrary()
        } else {
            model.openSearchWindow()
        }
    }

    @objc private func showSettings(_ sender: Any?) {
        model?.openProductSettings()
    }

    private func enforceWorkspaceMinimum(on window: NSWindow) {
        // Hosted toolbar items can raise the frame minimum after the content
        // contract was installed. Reassert this unconditionally so their
        // intrinsic width never prevents the compact toolbar variants.
        window.contentMinSize = SLDesign.workspaceMinimumSize
    }
}
