import AppKit
import ScreenlogCore
import SwiftUI

private enum CaptureSetupOutcome: Equatable {
    case completed
    case cancelled
}

private enum CaptureSetupDestination: Equatable {
    case library
    case timeline(TimelineNavigationOrigin)
    case settings
    case settingsGuide
    case none
}

private enum ScreenloggerRelaunch {
    static func perform() {
        let appPath = Bundle.main.bundleURL.path
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = [
            "-c",
            "sleep 1; exec /usr/bin/open -n \"$1\"",
            "screenlogger-relaunch",
            appPath,
        ]
        do {
            try launcher.run()
            NSApp.terminate(nil)
        } catch {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }
}

/// The exact retained surface state to restore after the temporary Setup detour.
///
/// `CaptureSetupOrigin.timeline` identifies the visible surface, while
/// `TimelineNavigationOrigin` carries its navigation history. Keeping both
/// prevents Setup from turning a Timeline opened from a Library result into a
/// direct Timeline and silently removing Back/Escape to the preserved query.
private enum CaptureSetupReturnPath: Equatable {
    case library
    case timeline(TimelineNavigationOrigin)
    case settings
    case settingsGuide
    case direct
    case firstRun

    init(origin: CaptureSetupOrigin, timelineOrigin: TimelineNavigationOrigin) {
        switch origin {
        case .library:
            self = .library
        case .timeline:
            self = .timeline(timelineOrigin)
        case .settings:
            self = .settings
        case .settingsGuide:
            self = .settingsGuide
        case .direct:
            self = .direct
        case .directFirstRun:
            self = .firstRun
        }
    }

    func destination(after outcome: CaptureSetupOutcome) -> CaptureSetupDestination {
        switch self {
        case .library:
            return .library
        case .timeline(let origin):
            return .timeline(origin)
        case .settings:
            return .settings
        case .settingsGuide:
            return .settingsGuide
        case .direct:
            return outcome == .completed ? .timeline(.direct) : .none
        case .firstRun:
            return .library
        }
    }
}

/// Owns the temporary setup window and its macOS permission refresh lifecycle.
@MainActor
final class PermissionsHelperController: NSObject, NSWindowDelegate {
    static let shared = PermissionsHelperController()

    private var window: NSWindow?
    private weak var model: AppModel?
    private var returnPath: CaptureSetupReturnPath?
    private var activeOrigin: CaptureSetupOrigin?
    private var preferredPermission: ScreenlogPermission?
    private var companionPermission: ScreenlogPermission?
    private var refreshTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    private override init() {
        super.init()
    }

    func show(
        model: AppModel,
        origin: CaptureSetupOrigin,
        preferredPermission: ScreenlogPermission? = nil
    ) {
        #if DEBUG
            AppUITestFixture.installIfRequested(on: model)
        #endif
        let requestedReturnPath = CaptureSetupReturnPath(
            origin: origin,
            timelineOrigin: model.timelineNavigationOrigin
        )
        let requestedPermission =
            preferredPermission.flatMap { model.permissions.isGranted($0) ? nil : $0 }
            ?? model.permissions.primaryMissingRequiredPermission
        if let window {
            // A visible helper is an active detour whose buttons and guidance
            // must keep their original meaning. A minimized or ordered-out
            // retained helper is no longer an active flow; an explicit reopen
            // may safely adopt the new surface and its exact Timeline history.
            var shouldReplaceContent = false
            if !window.isVisible || window.isMiniaturized,
                returnPath != requestedReturnPath
            {
                self.model = model
                returnPath = requestedReturnPath
                activeOrigin = origin
                shouldReplaceContent = true
            }
            if self.preferredPermission != requestedPermission {
                self.preferredPermission = requestedPermission
                shouldReplaceContent = true
            }
            if shouldReplaceContent {
                window.contentViewController = makeContentController(
                    model: model,
                    origin: activeOrigin ?? origin,
                    preferredPermission: requestedPermission
                )
            }
            NSApp.activate(ignoringOtherApps: true)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            startRefreshLoop()
            return
        }

        // The initiating surface owns a visible Setup flow. If it is later
        // retained out of sight, `show` can intentionally replace this context.
        self.model = model
        returnPath = requestedReturnPath
        activeOrigin = origin
        self.preferredPermission = requestedPermission
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Permissions & Privacy"
        window.titleVisibility = .visible
        window.titlebarSeparatorStyle = .automatic
        window.isReleasedWhenClosed = false
        // Preserve first-click drag initiation on the app tile. The native
        // titlebar remains draggable, so the content background does not need
        // to compete with the cross-application drag gesture.
        window.isMovableByWindowBackground = false
        window.backgroundColor = .windowBackgroundColor
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.level = .normal
        window.hidesOnDeactivate = false
        window.contentMinSize = NSSize(width: 460, height: 428)
        window.delegate = self
        window.contentViewController = makeContentController(
            model: model,
            origin: origin,
            preferredPermission: requestedPermission
        )
        window.setContentSize(NSSize(width: 620, height: 600))

        self.window = window
        positionOnVisibleScreen(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        startRefreshLoop()

        // During early launch `NSScreen.main` may not be established yet. A
        // second pass on the next run-loop turn also handles a just-changed
        // active display without delaying initial presentation on bootstrap.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.positionOnVisibleScreen(window)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func hide() {
        refreshTask?.cancel()
        refreshTask = nil
        stopActivationObserver()
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        model = nil
        returnPath = nil
        activeOrigin = nil
        preferredPermission = nil
        companionPermission = nil
    }

    func windowWillClose(_ notification: Notification) {
        // The window's close button and Command-W mean the same thing as the
        // visible cancel action only while first-launch intent is undecided.
        // Never overwrite an established capture choice when Setup was opened
        // later for a revoked permission or a status check.
        let returningModel = model
        let destination = returnPath?.destination(after: .cancelled) ?? .none
        if let model = returningModel {
            if activeOrigin == .directFirstRun, model.firstRunValueProgress.isWaiting {
                // Match Escape and the visible "Stop & Open Library" action.
                // Closing Setup while the first value is still pending must
                // not silently leave capture running.
                _ = model.keepCaptureOff()
            } else if model.captureIntent == nil {
                _ = model.keepCaptureOff()
            }
        }
        if activeOrigin == .directFirstRun {
            returningModel?.resetFirstRunValueProgress()
        }
        refreshTask?.cancel()
        refreshTask = nil
        stopActivationObserver()
        window = nil
        model = nil
        returnPath = nil
        activeOrigin = nil
        preferredPermission = nil
        companionPermission = nil
        restore(destination, model: returningModel)
    }

    private func finish(_ outcome: CaptureSetupOutcome) {
        guard let returningModel = model else { return }
        let destination = returnPath?.destination(after: outcome) ?? .none
        if activeOrigin == .directFirstRun {
            returningModel.resetFirstRunValueProgress()
        }
        hide()
        restore(destination, model: returningModel)
    }

    private func makeContentController(
        model: AppModel,
        origin: CaptureSetupOrigin,
        preferredPermission: ScreenlogPermission?
    ) -> NSViewController {
        let content = PermissionsHelperView(
            origin: origin,
            preferredPermission: preferredPermission,
            onDismiss: { [weak self] in
                if model.keepCaptureOff() {
                    self?.finish(.cancelled)
                }
            },
            onStart: { [weak self] in
                if origin == .directFirstRun {
                    _ = model.startFirstRunCapture()
                    return
                }
                let started = model.isRecording || model.startCapture()
                if started {
                    self?.finish(.completed)
                }
            },
            onDone: { [weak self] in
                self?.finish(.completed)
            },
            onOpenScreen: { [weak self] in
                model.requestScreenRecordingPermission()
                if model.permissionSettingsResult?.opened == true {
                    #if DEBUG
                        if AppUITestFixture.simulateSetupPermissionGrantIfRequested(on: model) {
                            return
                        }
                    #endif
                    self?.presentAlongsideSystemSettings(for: .screenRecording)
                }
            },
            onOpenAccessibility: { [weak self] in
                model.requestAccessibilityPermission()
                if model.permissionSettingsResult?.opened == true {
                    #if DEBUG
                        if AppUITestFixture.simulateSetupPermissionGrantIfRequested(on: model) {
                            return
                        }
                    #endif
                    self?.presentAlongsideSystemSettings(for: .accessibility)
                }
            },
            onRefresh: {
                Task { await model.refreshPermissions(force: true) }
            },
            onRelaunch: ScreenloggerRelaunch.perform
        )
        .environmentObject(model)
        return NSHostingController(rootView: content)
    }

    private func restore(_ destination: CaptureSetupDestination, model: AppModel?) {
        guard let model else { return }
        switch destination {
        case .library:
            model.openSearchWindow()
        case .timeline(let origin):
            model.openMainShell(origin: origin)
        case .settings:
            model.openProductSettings()
        case .settingsGuide:
            model.openProductSettings(.supportGuide)
            model.requestUserGuidePresentation()
        case .none:
            break
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        startActivationObserver()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let model = self.model else { break }
                // Appearance must never trigger a permission request. The
                // prompt-free preflight is sufficient for setup status.
                await model.refreshPermissions(force: false)
                self.reconcileSystemSettingsCompanion()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func startActivationObserver() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let model = self?.model else { return }
                await model.refreshPermissions(force: false)
                self?.reconcileSystemSettingsCompanion()
            }
        }
    }

    private func stopActivationObserver() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    /// Keep the drag source reachable while System Settings is frontmost.
    /// This mode is entered only after a direct user action and is removed as
    /// soon as the selected permission is granted or Setup closes.
    private func presentAlongsideSystemSettings(for permission: ScreenlogPermission) {
        companionPermission = permission
        guard let window else { return }
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak window] in
            guard let self, let window,
                self.companionPermission == permission,
                self.model?.permissions.isGranted(permission) != true
            else { return }
            window.orderFrontRegardless()
        }
    }

    private func reconcileSystemSettingsCompanion() {
        guard let permission = companionPermission,
            model?.permissions.isGranted(permission) == true
        else { return }
        companionPermission = nil
        window?.level = .normal
    }

    private func positionOnVisibleScreen(_ window: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            // AppKit can briefly report no screens while an accessory app is
            // still finishing Launch Services activation. Core Graphics has a
            // usable main-display geometry at this point, so avoid leaving the
            // default frame at (0, 0), which is off-screen in AppKit space.
            let display = CGDisplayBounds(CGMainDisplayID())
            let size = window.frame.size
            window.setFrameOrigin(
                NSPoint(
                    x: display.maxX - size.width - 24,
                    y: display.height - size.height - 40
                ))
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        guard visible.width >= size.width, visible.height >= size.height else {
            let display = CGDisplayBounds(CGMainDisplayID())
            window.setFrameOrigin(
                NSPoint(
                    x: display.maxX - size.width - 24,
                    y: display.height - size.height - 40
                ))
            return
        }
        let origin = NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 40
        )
        // The origin is already derived from visibleFrame. Calling
        // constrainFrameRect during applicationDidFinishLaunching can return
        // the default zero origin before AppKit finishes screen activation.
        window.setFrameOrigin(origin)
    }
}
