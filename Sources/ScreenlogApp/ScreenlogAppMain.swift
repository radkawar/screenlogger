import AppKit
import Combine
import Darwin
import ScreenlogCore
import SwiftUI

@main
struct ScreenlogAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Multi-pane preferences for capture, privacy, integrations, and storage.
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appModel)
        }
        .commands {
            ScreenloggerCommands(model: appDelegate.appModel)
        }
    }
}

private struct ScreenloggerCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject private var updates = AppUpdateController.shared

    var body: some Commands {
        // Keep the native menu placements while sourcing every product key
        // equivalent from the same live, user-editable registry.
        CommandGroup(after: .textEditing) {
            shortcutButton(
                "Find in Library",
                actionID: .findLibrary,
                accessibilityIdentifier: "commands.find-in-library"
            ) {
                model.openSearchWindow(intent: .find)
            }
        }

        CommandGroup(after: .windowList) {
            Divider()
            shortcutButton(
                "Show Library",
                actionID: .showLibrary,
                accessibilityIdentifier: "commands.show-library"
            ) {
                model.openSearchWindow(intent: .show)
            }
            shortcutButton(
                "Search Library",
                actionID: .searchLibrary,
                accessibilityIdentifier: "commands.search-library"
            ) {
                model.openSearchWindow(intent: .show)
            }
            shortcutButton(
                "Show Timeline",
                actionID: .showTimeline,
                accessibilityIdentifier: "commands.show-timeline"
            ) {
                model.openMainShell(origin: .direct)
            }
        }

        CommandMenu("Capture") {
            shortcutButton(
                model.isRecording ? "Stop Capture" : "Start Capture",
                actionID: .toggleCapture,
                accessibilityIdentifier: "commands.toggle-capture"
            ) {
                model.performKeyboardShortcutCaptureToggle()
            }
        }

        CommandGroup(replacing: .appSettings) {
            shortcutButton(
                "Settings...",
                actionID: .showSettings,
                accessibilityIdentifier: "commands.show-settings"
            ) {
                model.openProductSettings()
            }
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates...") {
                updates.checkForUpdates()
            }
            .disabled(!updates.canCheckForUpdates)
            .accessibilityIdentifier("commands.check-for-updates")

            Divider()

            Button("Permissions & Privacy...") {
                model.openProductSettings(.privacyPermissions)
            }
            .accessibilityIdentifier("commands.show-privacy")
        }

        CommandGroup(replacing: .appTermination) {
            shortcutButton(
                "Quit Screenlogger",
                actionID: .quit,
                accessibilityIdentifier: "commands.quit"
            ) {
                NSApp.terminate(nil)
            }
        }

        CommandGroup(replacing: .help) {
            Button("Screenlogger Help...") {
                model.openProductGuide()
            }
            .accessibilityIdentifier("commands.show-help")
        }
    }

    @ViewBuilder
    private func shortcutButton(
        _ title: String,
        actionID: KeyboardShortcutActionID,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        if let binding = model.keyboardShortcutBinding(for: actionID),
            let keyEquivalent = binding.swiftUIKeyEquivalent
        {
            Button(title, action: action)
                .keyboardShortcut(keyEquivalent, modifiers: binding.swiftUIModifiers)
                .accessibilityIdentifier(accessibilityIdentifier)
        } else {
            Button(title, action: action)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}

/// Owns app lifecycle and single-instance routing.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appModel = AppModel()

    private var statusMenuController: StatusMenuController?
    private var instanceLockFD: Int32 = -1
    private var updaterNetworkPolicyCancellable: AnyCancellable?

    /// Typed window intents relayed by a second process to the already-running
    /// menu bar app. Reopen is intentionally not a launch argument: it is the
    /// native fallback for an otherwise unqualified second invocation.
    private enum LaunchIntent: String {
        case library
        case timeline
        case setup
        case reopen

        init?(arguments: [String]) {
            if arguments.contains("--open-library") {
                self = .library
            } else if arguments.contains("--open-timeline") {
                self = .timeline
            } else if arguments.contains("--open-setup") {
                self = .setup
            } else {
                return nil
            }
        }
    }

    private static let launchRouteNotification = Notification.Name("dev.screenlog.launch-route")
    private static let launchRouteKey = "route"
    private static let launchRouteTargetPIDKey = "targetPID"

    private enum InstanceLockResult {
        case acquired
        case heldByOtherProcess
        case unavailable
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Register before the single-instance decision in didFinishLaunching so
        // another invocation can route a requested window to this process.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleLaunchRouteNotification(_:)),
            name: Self.launchRouteNotification,
            object: Bundle.main.bundleIdentifier
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let route = LaunchIntent(arguments: arguments)
        #if DEBUG
            // The route smoke owns an isolated, first-launch preference home.
            // Suppress only automatic Setup so it can exercise a genuinely
            // windowless singleton owner; explicit routes remain unchanged.
            let suppressAutomaticSetupForWindowRouteSmoke =
                ProcessInfo.processInfo.environment["SCREENLOG_WINDOW_ROUTE_SMOKE"]
                == "windowless-v1"
        #else
            let suppressAutomaticSetupForWindowRouteSmoke = false
        #endif

        // `open -na` always starts another process. An atomic lock decides
        // ownership; Launch Services' process list can briefly contain stale
        // entries and is used only to target activation and route delivery.
        let lockResult = acquireInstanceLock()
        let existingInstance = Self.existingInstance()
        let existingInstancePredatesCurrentProcess =
            existingInstance.map {
                ($0.launchDate ?? .distantPast) <= (NSRunningApplication.current.launchDate ?? .distantFuture)
            } ?? false
        let shouldYieldToExistingInstance =
            lockResult == .heldByOtherProcess
            || (lockResult == .unavailable && existingInstance != nil)
            // Upgrade edge: a build launched before this lock existed can be
            // live without owning it. The older product process still wins.
            || (lockResult == .acquired && existingInstancePredatesCurrentProcess)
        if shouldYieldToExistingInstance {
            Self.relay(route ?? .reopen, to: existingInstance?.processIdentifier)
            existingInstance?.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }

        // TCC grants are tied to the running app's path and code identity.
        // Launching directly from a read-only installer volume would create a
        // disposable identity that cannot reliably follow the installed copy.
        if AppInstallLocation.requiresInstallationBeforePermissionSetup(
            bundleURL: Bundle.main.bundleURL
        ) {
            presentInstallBeforeLaunchAlert(bundleURL: Bundle.main.bundleURL)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        // Install the menu-bar surface first so bootstrap never delays its icon.
        let statusMenuController = StatusMenuController(appModel: appModel)
        statusMenuController.install()
        self.statusMenuController = statusMenuController

        // A requested surface must become visible before store/IPC bootstrap.
        // The views already tolerate an initializing model, and this keeps a
        // slow or contended local library from making launch look unresponsive.
        if let route {
            perform(route)
        }

        // Bootstrap store / capture / IPC off the critical click path as much as possible.
        appModel.bootstrap()
        AppUpdateController.shared.start(networkAccessAllowed: !appModel.airgapMode)
        updaterNetworkPolicyCancellable = appModel.$airgapMode
            .removeDuplicates()
            .sink { offline in
                AppUpdateController.shared.setNetworkAccessAllowed(!offline)
            }
        statusMenuController.refreshAppearance()

        // A first launch that still needs required permission must never look
        // like a no-op. Returning configured users keep the quiet menu-bar
        // launch behavior; explicit Library/Timeline routes remain untouched.
        if route == nil, !suppressAutomaticSetupForWindowRouteSmoke {
            Task { @MainActor in
                await appModel.refreshPermissions(force: false)
                if appModel.libraryStartupIssue == nil,
                    !appModel.permissions.isCaptureReady || appModel.captureIntent == nil
                {
                    appModel.showPermissions(origin: .directFirstRun)
                }
            }
        }
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        appModel.applyAppearancePreference()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        releaseInstanceLock()
        statusMenuController?.invalidate()
        statusMenuController = nil
        updaterNetworkPolicyCancellable?.cancel()
        updaterNetworkPolicyCancellable = nil
        appModel.shutdown()
    }

    /// A regular macOS app should recover a useful window when its Dock icon
    /// is clicked after the last window was closed. Library is Screenlogger's
    /// primary workspace and is safe to show even before capture is configured.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        statusMenuController?.restoreStatusItem()
        reopenPrimaryWorkspaceIfNeeded(hasVisibleProductWindow: flag)
        return true
    }

    /// Restores Screenlogger's primary workspace only when reopening would
    /// otherwise appear to do nothing. Key-capable app windows are product
    /// surfaces; excluding minimized windows matches each retained window
    /// controller's visibility semantics.
    private var hasVisibleProductWindow: Bool {
        NSApp.windows.contains {
            $0.isVisible && !$0.isMiniaturized && $0.canBecomeKey
        }
    }

    private func reopenPrimaryWorkspaceIfNeeded(hasVisibleProductWindow: Bool) {
        guard !hasVisibleProductWindow else { return }
        appModel.openSearchWindow()
    }

    /// Finds another instance of this exact product bundle, if one is running.
    private static func existingInstance() -> NSRunningApplication? {
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.screenlog.app"
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter {
                $0.processIdentifier != currentPID
                    && !$0.isTerminated
                    && Darwin.kill($0.processIdentifier, 0) == 0
            }
            .min {
                ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture)
            }
    }

    private func presentInstallBeforeLaunchAlert(bundleURL: URL) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Install Screenlogger First"
        alert.informativeText =
            "Drag Screenlogger to Applications, then open that installed copy. macOS permissions belong to the installed app."
        alert.addButton(withTitle: "Show Installer")
        alert.addButton(withTitle: "Quit")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(bundleURL.deletingLastPathComponent())
        }
        NSApp.terminate(nil)
    }

    private func acquireInstanceLock() -> InstanceLockResult {
        // Singleton ownership is per user/product, never per selected library.
        // SCREENLOG_DATA_DIR is intentionally ignored here so two writers cannot
        // bypass ownership by pointing at different data roots.
        let root = ScreenlogPaths.applicationSupportRoot
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return .unavailable
        }

        let path = root.appendingPathComponent("app.instance.lock", isDirectory: false).path
        // O_EXLOCK makes acquisition atomic with opening the file on macOS;
        // closing the descriptor releases the advisory lock after any exit.
        let descriptor = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            return errno == EWOULDBLOCK || errno == EAGAIN
                ? .heldByOtherProcess
                : .unavailable
        }

        instanceLockFD = descriptor
        return .acquired
    }

    private func releaseInstanceLock() {
        guard instanceLockFD >= 0 else { return }
        Darwin.close(instanceLockFD)
        instanceLockFD = -1
    }

    private static func relay(_ intent: LaunchIntent, to targetPID: pid_t?) {
        DistributedNotificationCenter.default().postNotificationName(
            launchRouteNotification,
            object: Bundle.main.bundleIdentifier,
            userInfo: [
                launchRouteKey: intent.rawValue,
                // Zero broadcasts to whichever observer owns the instance lock.
                launchRouteTargetPIDKey: Int(targetPID ?? 0),
            ],
            deliverImmediately: true
        )
    }

    @objc private func handleLaunchRouteNotification(_ notification: Notification) {
        guard
            let targetPID = notification.userInfo?[Self.launchRouteTargetPIDKey] as? Int,
            targetPID == Int(ProcessInfo.processInfo.processIdentifier) || (targetPID == 0 && instanceLockFD >= 0),
            let rawRoute = notification.userInfo?[Self.launchRouteKey] as? String,
            let intent = LaunchIntent(rawValue: rawRoute)
        else { return }

        statusMenuController?.restoreStatusItem()
        perform(intent)
    }

    private func perform(_ intent: LaunchIntent) {
        switch intent {
        case .library:
            appModel.openSearchWindow()
        case .timeline:
            appModel.openMainShell(origin: .direct)
        case .setup:
            appModel.showPermissions(origin: .direct)
        case .reopen:
            reopenPrimaryWorkspaceIfNeeded(hasVisibleProductWindow: hasVisibleProductWindow)
        }
    }
}
