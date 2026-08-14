import AppKit
import Combine
import ScreenlogCore

/// Owns Screenlogger's native menu-bar surface and keeps it synchronized with
/// capture, permission, and Library state.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    let appModel: AppModel
    var statusItem: NSStatusItem?
    var statusMenu: NSMenu?
    var iconCancellable: AnyCancellable?
    var shortcutCancellable: AnyCancellable?
    var captureOnceFeedbackTask: Task<Void, Never>?
    var isShowingCaptureOnceSuccess = false
    let browserURLService = BrowserURLService()

    /// Menu item tags for dynamic titles and state.
    enum ItemTag: Int {
        case openSearch = 1
        case toggleRecording = 2
        case settings = 3
        case pauseOneHour = 4
        case excludeFrontmost = 5
        case timeline = 6
        case undoExclude = 7
        case quit = 8
        case help = 9
        case setup = 10
        case about = 11
        case revealLibrary = 13
        case revealLibraryDiagnostics = 14
        case libraryRecoveryEnd = 15
        case captureOnce = 16
        case captureStatus = 17
        case checkForUpdates = 18
        case excludeCurrentWebsite = 19
        case audioTranscriptionStatus = 20
        case hideMenuBarIcon = 21

        var accessibilityIdentifier: String {
            switch self {
            case .openSearch: return "status-menu.library"
            case .toggleRecording: return "status-menu.capture-toggle"
            case .settings: return "status-menu.settings"
            case .pauseOneHour: return "status-menu.pause-one-hour"
            case .excludeFrontmost: return "status-menu.exclude-app"
            case .timeline: return "status-menu.timeline"
            case .undoExclude: return "status-menu.undo-exclusion"
            case .quit: return "status-menu.quit"
            case .help: return "status-menu.help"
            case .setup: return "status-menu.permissions"
            case .about: return "status-menu.about"
            case .revealLibrary: return "status-menu.reveal-library"
            case .revealLibraryDiagnostics: return "status-menu.reveal-diagnostics"
            case .libraryRecoveryEnd: return "status-menu.library-recovery-end"
            case .captureOnce: return "status-menu.capture-once"
            case .captureStatus: return "status-menu.capture-status"
            case .checkForUpdates: return "status-menu.check-for-updates"
            case .excludeCurrentWebsite: return "status-menu.exclude-website"
            case .audioTranscriptionStatus: return "status-menu.audio-transcription"
            case .hideMenuBarIcon: return "status-menu.hide-icon"
            }
        }
    }

    init(appModel: AppModel) {
        self.appModel = appModel
        super.init()
    }

    func install() {
        restoreStatusItem()
        bindStatusIcon()
        bindKeyboardShortcuts()
    }

    /// Removes the status item for this running session without stopping
    /// capture. Launching Screenlogger again calls `restoreStatusItem()`.
    func hideStatusItemUntilReopen() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        statusMenu = nil
    }

    func restoreStatusItem() {
        guard statusItem == nil else { return }
        setupStatusItem()
        updateStatusItemAppearance()
    }

    func invalidate() {
        iconCancellable?.cancel()
        iconCancellable = nil
        shortcutCancellable?.cancel()
        shortcutCancellable = nil
        captureOnceFeedbackTask?.cancel()
        captureOnceFeedbackTask = nil
        isShowingCaptureOnceSuccess = false

        hideStatusItemUntilReopen()
    }

    func refreshAppearance() {
        updateStatusItemAppearance()
    }

}
