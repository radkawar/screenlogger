import AppKit
import ScreenlogCore

extension StatusMenuController {
    // MARK: - Status item

    func setupStatusItem() {
        // Fixed length is more stable than variableLength for template icons.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        item.autosaveName = "dev.screenlog.statusItem"

        if let button = item.button {
            button.image = statusSymbolImage("exclamationmark.shield")
            button.imagePosition = .imageOnly
            button.toolTip = "Screenlogger"
            button.setButtonType(.momentaryChange)
            button.setAccessibilityIdentifier("status-menu.button")
        }

        // A native menu keeps capture controls fast and familiar on macOS.
        let menu = buildStatusMenu()
        menu.delegate = self
        item.menu = menu
        statusMenu = menu
        statusItem = item
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let captureStatus = makeItem(
            title: "Capture needs setup",
            action: #selector(performCaptureStatusAction(_:)),
            tag: .captureStatus,
            symbol: "exclamationmark.shield"
        )
        // State decides whether this native menu item is an action. It starts
        // disabled so it can never perform a command before the first refresh.
        captureStatus.isEnabled = false
        menu.addItem(captureStatus)

        menu.addItem(.separator())

        menu.addItem(
            makeItem(
                title: "Show Library",
                action: #selector(openSearchShell(_:)),
                tag: .openSearch,
                symbol: "books.vertical",
                shortcut: .showLibrary
            ))
        menu.addItem(
            makeItem(
                title: "Show Timeline",
                action: #selector(openTimeline(_:)),
                tag: .timeline,
                symbol: "clock",
                shortcut: .showTimeline
            ))

        menu.addItem(.separator())

        let revealLibrary = makeItem(
            title: "Reveal Library in Finder",
            action: #selector(revealLibrary(_:)),
            tag: .revealLibrary,
            symbol: "folder"
        )
        revealLibrary.isHidden = true
        menu.addItem(revealLibrary)

        let revealDiagnostics = makeItem(
            title: "Reveal Diagnostics",
            action: #selector(revealLibraryDiagnostics(_:)),
            tag: .revealLibraryDiagnostics,
            symbol: "doc.text.magnifyingglass"
        )
        revealDiagnostics.isHidden = true
        menu.addItem(revealDiagnostics)

        let recoveryEnd = NSMenuItem.separator()
        recoveryEnd.tag = ItemTag.libraryRecoveryEnd.rawValue
        recoveryEnd.isHidden = true
        menu.addItem(recoveryEnd)

        menu.addItem(
            makeItem(
                title: "Start Capture",
                action: #selector(toggleRecording(_:)),
                tag: .toggleRecording,
                symbol: "record.circle",
                shortcut: .toggleCapture
            ))

        menu.addItem(
            makeItem(
                title: "Pause Capture for 1 Hour",
                action: #selector(pauseRecordingOneHour(_:)),
                tag: .pauseOneHour,
                symbol: "clock.badge.xmark"
            ))
        menu.addItem(
            makeItem(
                title: "Capture Now",
                action: #selector(captureOnce(_:)),
                tag: .captureOnce,
                symbol: "camera"
            ))
        menu.addItem(
            makeItem(
                title: "Exclude App",
                action: #selector(excludeFrontmostApp(_:)),
                tag: .excludeFrontmost,
                symbol: "eye.slash"
            ))
        let excludeWebsite = makeItem(
            title: "Exclude Website",
            action: #selector(excludeCurrentWebsite(_:)),
            tag: .excludeCurrentWebsite,
            symbol: "globe"
        )
        excludeWebsite.isHidden = true
        menu.addItem(excludeWebsite)
        let undoExclude = makeItem(
            title: "Undo Exclusion",
            action: #selector(undoLastCaptureExclusion(_:)),
            tag: .undoExclude,
            symbol: "arrow.uturn.backward.circle"
        )
        undoExclude.isHidden = true
        menu.addItem(undoExclude)

        menu.addItem(.separator())

        menu.addItem(
            makeItem(
                title: "Permissions & Privacy...",
                action: #selector(openPrivacySettings(_:)),
                tag: .setup,
                symbol: "checkmark.shield"
            ))
        menu.addItem(
            makeItem(
                title: "Settings...",
                action: #selector(openSettingsWindow(_:)),
                tag: .settings,
                symbol: "gearshape",
                shortcut: .showSettings
            ))
        menu.addItem(
            makeItem(
                title: "Screenlogger Help...",
                action: #selector(openHelp(_:)),
                tag: .help,
                symbol: "questionmark.circle"
            ))

        menu.addItem(.separator())

        menu.addItem(
            makeItem(
                title: "About Screenlogger",
                action: #selector(openAbout(_:)),
                tag: .about,
                symbol: "info.circle"
            ))
        menu.addItem(
            makeItem(
                title: "Check for Updates...",
                action: #selector(checkForUpdates(_:)),
                tag: .checkForUpdates,
                symbol: "arrow.triangle.2.circlepath"
            ))
        menu.addItem(
            makeItem(
                title: "Quit Screenlogger",
                action: #selector(quitApp(_:)),
                tag: .quit,
                symbol: "power",
                shortcut: .quit
            ))
        return menu
    }

    private func makeItem(
        title: String,
        action: Selector?,
        tag: ItemTag,
        symbol: String? = nil,
        shortcut: KeyboardShortcutActionID? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag.rawValue
        if let shortcut {
            applyKeyboardShortcut(shortcut, to: item)
        }
        if let symbol {
            item.image = menuSymbolImage(symbol)
        }
        item.setAccessibilityIdentifier(tag.accessibilityIdentifier)
        return item
    }

    func bindKeyboardShortcuts() {
        shortcutCancellable = appModel.$keyboardShortcutRevision
            .sink { [weak self] _ in
                self?.refreshMenuKeyboardShortcuts()
            }
    }

    private func refreshMenuKeyboardShortcuts() {
        let shortcuts: [(ItemTag, KeyboardShortcutActionID)] = [
            (.openSearch, .showLibrary),
            (.timeline, .showTimeline),
            (.toggleRecording, .toggleCapture),
            (.settings, .showSettings),
            (.quit, .quit),
        ]
        for (tag, actionID) in shortcuts {
            guard let item = statusMenu?.item(withTag: tag.rawValue) else { continue }
            applyKeyboardShortcut(actionID, to: item)
        }
    }

    private func applyKeyboardShortcut(
        _ actionID: KeyboardShortcutActionID,
        to item: NSMenuItem
    ) {
        guard let binding = appModel.keyboardShortcutBinding(for: actionID) else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = binding.appKitKeyEquivalent
        item.keyEquivalentModifierMask = binding.appKitModifiers
    }

    func menuSymbolImage(_ name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configured = image.withSymbolConfiguration(config) ?? image
        configured.isTemplate = true
        return configured
    }

    func statusSymbolImage(_ name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: "Screenlogger") else {
            // Absolute fallback so we never show an empty status slot.
            let fallback = NSImage(size: NSSize(width: 18, height: 18))
            fallback.isTemplate = true
            return fallback
        }
        image.isTemplate = true
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        return image.withSymbolConfiguration(config) ?? image
    }

}
