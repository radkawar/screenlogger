import AppKit
import SwiftUI

/// Native Library window for searching and refining captured moments.
@MainActor
final class SearchWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = SearchWindowController()
    private static let frameAutosaveName = "ScreenloggerLibraryWindow"
    private static let toolbarIdentifier = NSToolbar.Identifier("ScreenloggerLibraryToolbar")
    private static let locationItemIdentifier = NSToolbarItem.Identifier("ScreenloggerLibraryLocation")
    private static let captureItemIdentifier = NSToolbarItem.Identifier("ScreenloggerLibraryCapture")
    private static let timelineItemIdentifier = NSToolbarItem.Identifier("ScreenloggerLibraryTimeline")
    private static let settingsItemIdentifier = NSToolbarItem.Identifier("ScreenloggerLibrarySettings")

    private var window: NSWindow?
    private weak var model: AppModel?

    private override init() {
        super.init()
    }

    var isVisible: Bool {
        window?.isVisible == true && window?.isMiniaturized == false
    }

    func show(model: AppModel, intent: LibraryPresentationIntent = .show) {
        #if DEBUG
            AppUITestFixture.installIfRequested(on: model)
        #endif
        self.model = model
        model.enterShellSearch(intent: intent)
        model.refreshScopedLibrarySearchForPresentation()

        if model.showDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            requestSearchFocus(model, selectingExistingQuery: intent.selectsExistingQuery)
            return
        }

        let root = FloatingSearchView()
            .environmentObject(model)

        let hosting = NSHostingController(rootView: root)
        // AppKit owns the Library window's size contract. Without this,
        // SwiftUI fitting changes from results, filters, or toolbar controls
        // can silently replace the tested content minimum.
        hosting.sizingOptions = []
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Library"
        // Keep the descriptive window title for Window menu, VoiceOver, and
        // UI automation, while the unified toolbar owns the visible chrome.
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.titlebarSeparatorStyle = .automatic
        win.toolbarStyle = .unified
        win.toolbar = makeToolbar()
        win.isReleasedWhenClosed = false
        // Match the SwiftUI root's content minimum. `minSize` includes the
        // titlebar and can otherwise leave the Library's controls clipped.
        win.backgroundColor = .windowBackgroundColor
        win.isOpaque = true
        win.hasShadow = true
        win.contentViewController = hosting
        win.contentMinSize = SLDesign.workspaceMinimumSize
        // Assigning a hosting controller adopts its fitting size, so set the
        // intended initial workspace size afterwards.
        win.setContentSize(NSSize(width: 1080, height: 720))
        win.delegate = self
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.level = .normal
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

        // Prefer upper-center on first use so the Library stays close to the
        // user's focus. Later openings restore the frame they chose.
        if !restoredFrame, let screen = NSScreen.main {
            let vis = screen.visibleFrame
            let origin = NSPoint(
                x: vis.midX - win.frame.width / 2,
                y: vis.midY - win.frame.height / 3
            )
            win.setFrameOrigin(origin)
        }

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        self.window = win
        requestSearchFocus(model, selectingExistingQuery: intent.selectsExistingQuery)
        DispatchQueue.main.async { [weak self, weak win] in
            guard let self, let win, self.window === win else { return }
            win.contentMinSize = SLDesign.workspaceMinimumSize
        }
    }

    func hide() {
        window?.orderOut(nil)
        resetSearchState()
    }

    func toggle(model: AppModel) {
        if isVisible { hide() } else { show(model: model) }
    }

    func windowWillClose(_ notification: Notification) {
        resetSearchState()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        model?.shellFocusSearch = false
        // Minimizing is a reversible window-management action, not leaving
        // the Library. Preserve query/filter context exactly so restoring the
        // window cannot auto-enable a selected-session filter or dismiss an
        // in-progress search workspace.
        model?.showSearchOperatorMenu = false
        // This is presentation state, not query/filter context. Marking the
        // minimized surface inactive also lets its SwiftUI seam dismiss local
        // compact popovers instead of reopening them on restore.
        model?.shellSearchMode = false
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let model else { return }
        model.enterShellSearch()
        model.refreshScopedLibrarySearchForPresentation()
        requestSearchFocus(model)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let model else { return }
        // Timeline may mark search inactive while this retained window stays
        // alive. Re-keying Library must restore autocomplete eligibility even
        // when SwiftUI's search FocusState never changed.
        if !model.shellSearchMode {
            model.enterShellSearch()
        }
        model.refreshScopedLibrarySearchForPresentation()
    }

    func windowDidMove(_ notification: Notification) {
        guard let window else { return }
        ProductWindowFrameStore.save(window, name: Self.frameAutosaveName)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window else { return }
        ProductWindowFrameStore.save(window, name: Self.frameAutosaveName)
    }

    private func requestSearchFocus(
        _ model: AppModel,
        selectingExistingQuery: Bool = false
    ) {
        // Presenting Sessions must not enqueue a focus request that switches
        // the retained workspace back to Search. Find remains explicit.
        guard model.libraryWorkspaceNavigation.prepareSearchFocus(selectingExistingQuery: selectingExistingQuery) else {
            model.shellFocusSearch = false
            return
        }
        // Re-arm the observable request so a reused window always focuses the
        // field, even when the previous presentation also left it true.
        model.shellFocusSearch = false
        DispatchQueue.main.async { [weak self, weak model] in
            guard let self, let model, self.window?.isVisible == true else { return }
            guard model.libraryWorkspaceNavigation.acceptsSearchFocus else {
                return
            }
            model.shellFocusSearch = true
            guard selectingExistingQuery, !model.searchQuery.isEmpty else { return }
            // SwiftUI applies FocusState on this run-loop turn. Select through
            // the responder chain on the next turn so Command-F replaces the existing
            // query just like Find in other native Mac apps.
            DispatchQueue.main.async { [weak self] in
                guard self?.window?.isKeyWindow == true else { return }
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private func resetSearchState() {
        model?.shellFocusSearch = false
        model?.showSearchOperatorMenu = false
        model?.exitShellSearch()
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
            Self.locationItemIdentifier,
            .flexibleSpace,
            Self.captureItemIdentifier,
            Self.timelineItemIdentifier,
            Self.settingsItemIdentifier,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.locationItemIdentifier,
            .flexibleSpace,
            Self.captureItemIdentifier,
            Self.timelineItemIdentifier,
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
        case Self.locationItemIdentifier:
            return hostingToolbarItem(
                identifier: itemIdentifier,
                label: "Library",
                view: AnyView(LibraryToolbarLocationView())
            )
        case Self.captureItemIdentifier:
            return hostingToolbarItem(
                identifier: itemIdentifier,
                label: "Capture Status",
                view: AnyView(
                    LibraryToolbarActionsView()
                        .environmentObject(model)
                )
            )
        case Self.timelineItemIdentifier:
            return navigationToolbarItem(
                identifier: itemIdentifier,
                title: "Timeline",
                symbolName: "clock",
                action: #selector(showTimeline(_:)),
                accessibilityIdentifier: "navigation.library.timeline"
            )
        case Self.settingsItemIdentifier:
            return navigationToolbarItem(
                identifier: itemIdentifier,
                title: "Settings",
                symbolName: "gearshape",
                action: #selector(showSettings(_:)),
                accessibilityIdentifier: "navigation.library.settings"
            )
        default:
            return nil
        }
    }

    private func hostingToolbarItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        view: AnyView
    ) -> NSToolbarItem {
        let hostingView = NSHostingView(rootView: view)
        // Let AppKit measure the hosted SwiftUI view from its intrinsic size.
        // A one-time frame derived from `fittingSize` becomes stale as capture
        // state changes and can clip a longer status label.
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.view = hostingView
        // Custom informational groups should sit directly in the titlebar.
        // Explicitly opting out also avoids an oversized glass capsule on
        // newer macOS releases, where the foreground can lose contrast.
        item.isBordered = false
        item.visibilityPriority = .high
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

    @objc private func showTimeline(_ sender: Any?) {
        model?.openMainShell(origin: .direct)
    }

    @objc private func showSettings(_ sender: Any?) {
        model?.openProductSettings()
    }
}
