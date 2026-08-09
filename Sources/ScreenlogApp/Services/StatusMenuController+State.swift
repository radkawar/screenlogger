import AppKit
import Combine
import ScreenlogCore

extension StatusMenuController {
    // MARK: - Dynamic state

    func bindStatusIcon() {
        // Debounced icon updates - avoid thrashing the status bar on every published change.
        iconCancellable = appModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAppearance()
            }
    }

    func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        guard !isShowingCaptureOnceSuccess else { return }
        let status = appModel.captureStatusPresentation()
        button.image = statusSymbolImage(status.symbolName)
        button.toolTip = "Screenlogger - \(status.headline)\n\(status.detail)"
        button.setAccessibilityLabel("Screenlogger - \(status.headline)")
        button.setAccessibilityHelp(status.detail)
        // Never leave the button disabled.
        button.isEnabled = true
    }

    func showCaptureOnceSuccessFeedback() {
        captureOnceFeedbackTask?.cancel()
        isShowingCaptureOnceSuccess = true
        let displayCount = appModel.lastCaptureDisplayCount
        let savedDescription =
            displayCount > 1
            ? "\(displayCount) searchable stills were saved to your Library."
            : "One searchable still was saved to your Library."
        if let button = statusItem?.button {
            button.image = menuSymbolImage("checkmark.circle.fill")
            button.toolTip = "Screenlogger - capture saved"
            button.setAccessibilityLabel("Screenlogger - Capture saved")
            button.setAccessibilityHelp(savedDescription)
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "Capture saved to Library.",
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }

        captureOnceFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let self, !Task.isCancelled else { return }
            isShowingCaptureOnceSuccess = false
            captureOnceFeedbackTask = nil
            updateStatusItemAppearance()
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenuItems(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuItems(menu)
        // Refresh permission state before enabling capture.
        Task { @MainActor in
            await appModel.refreshPermissions(force: false)
            refreshMenuItems(menu)
            updateStatusItemAppearance()
        }
    }

    private func refreshMenuItems(_ menu: NSMenu) {
        let libraryIssue = appModel.libraryStartupIssue
        let front = Self.frontmostUserApp()
        let frontmostBundleID = front?.bundleIdentifier
        let websiteAttribution =
            BrowserURLService.isSupportedBrowser(bundleID: frontmostBundleID)
            ? browserURLService.browserAttribution(for: front)
            : nil
        let websitePresentation = WebsiteExclusionMenuPresentation.resolve(
            frontmostBundleID: frontmostBundleID,
            attribution: websiteAttribution,
            isExcluded: appModel.isDomainEffectivelyExcluded
        )
        let status = appModel.captureStatusPresentation()
        let showsLibraryRecoveryTools =
            libraryIssue != nil
            && (appModel.canRevealLibrary || appModel.canRevealLibraryDiagnostics)

        for item in menu.items {
            switch ItemTag(rawValue: item.tag) {
            case .captureStatus:
                item.title = statusMenuTitle(status)
                item.image = menuSymbolImage(status.symbolName)
                item.toolTip = status.detail
                item.isEnabled = status.primaryAction != nil
                item.setAccessibilityLabel(item.title)
                item.setAccessibilityHelp(statusAccessibilityHelp(status))
            case .revealLibrary:
                item.isHidden = libraryIssue == nil || !appModel.canRevealLibrary
                item.isEnabled = libraryIssue != nil && appModel.canRevealLibrary
            case .revealLibraryDiagnostics:
                item.isHidden = libraryIssue == nil || !appModel.canRevealLibraryDiagnostics
                item.isEnabled = libraryIssue != nil && appModel.canRevealLibraryDiagnostics
            case .libraryRecoveryEnd:
                item.isHidden = !showsLibraryRecoveryTools
            case .toggleRecording:
                item.title = "Stop Capture"
                item.image = menuSymbolImage("stop.circle")
                item.isHidden = !status.controls.canStop
                item.isEnabled = status.controls.canStop
                item.toolTip = status.controls.canStop ? "Stop automatic capture" : nil
            case .pauseOneHour:
                item.title = "Pause Capture for 1 Hour"
                item.image = menuSymbolImage("clock.badge.xmark")
                item.isEnabled = status.controls.canSchedulePause
                item.toolTip = status.controls.canSchedulePause ? "Resume automatically in one hour" : nil
                item.isHidden = !status.controls.canSchedulePause
            case .captureOnce:
                if !appModel.permissions.isCaptureReady {
                    item.title = "Set Up Capture Now..."
                    item.image = menuSymbolImage("exclamationmark.shield")
                } else if modelCaptureOnceInProgress {
                    item.title = "Saving Capture..."
                    item.image = menuSymbolImage("camera.badge.clock")
                } else {
                    item.title = "Capture Now"
                    item.image = menuSymbolImage("camera")
                }
                item.isEnabled =
                    status.controls.canCaptureOnce
                    && !modelCaptureOnceInProgress
                item.isHidden = !status.controls.canCaptureOnce && !modelCaptureOnceInProgress
                if !appModel.permissions.isCaptureReady {
                    item.toolTip = "Finish Permissions setup first"
                } else if modelCaptureOnceInProgress {
                    item.toolTip = appModel.captureNowDescription
                } else {
                    item.toolTip = appModel.captureNowDescription
                }
            case .excludeFrontmost:
                if let front {
                    let name = front.localizedName ?? front.bundleIdentifier ?? "App"
                    if let bundleID = front.bundleIdentifier {
                        let isExcluded = appModel.excludedBundles.contains {
                            $0.caseInsensitiveCompare(bundleID) == .orderedSame
                        }
                        item.title =
                            isExcluded
                            ? "Manage App Exclusions..."
                            : "Don't Capture \"\(name)\""
                        item.image = menuSymbolImage(isExcluded ? "slider.horizontal.3" : "eye.slash")
                        item.representedObject = bundleID
                        item.isEnabled = true
                        item.toolTip =
                            isExcluded
                            ? "Open Application Exclusions in Settings"
                            : "Pause capture whenever \(name) is the active app"
                    } else {
                        item.title = "Choose an App to Exclude"
                        item.representedObject = nil
                        item.isEnabled = false
                        item.toolTip = "Switch to the app you don't want Screenlogger to capture"
                    }
                } else {
                    item.title = "Choose an App to Exclude"
                    item.representedObject = nil
                    item.isEnabled = false
                    item.toolTip = "Switch to the app you don't want Screenlogger to capture"
                }
            case .excludeCurrentWebsite:
                switch websitePresentation {
                case .hidden:
                    item.title = "Exclude Website"
                    item.representedObject = nil
                    item.isHidden = true
                    item.isEnabled = false
                    item.toolTip = nil
                case .addressUnavailable:
                    item.title = "Website Address Unavailable"
                    item.image = menuSymbolImage("questionmark.circle")
                    item.representedObject = nil
                    item.isHidden = false
                    item.isEnabled = false
                    item.toolTip = "Screenlogger could not read the active browser address"
                case .available(let domain, let isExcluded):
                    item.title =
                        isExcluded
                        ? "Manage Website Exclusions..."
                        : "Don't Capture \"\(domain)\""
                    item.image = menuSymbolImage(isExcluded ? "slider.horizontal.3" : "globe")
                    item.representedObject = domain
                    item.isHidden = false
                    item.isEnabled = true
                    item.toolTip =
                        isExcluded
                        ? "Open Website Exclusions in Settings"
                        : "Skip capture while \(domain) is open in the active browser tab"
                }
            case .undoExclude:
                switch appModel.recentCaptureExclusion {
                case .application(let change)
                where appModel.excludedBundles.contains(where: {
                    $0.caseInsensitiveCompare(change.bundleID) == .orderedSame
                }):
                    item.title = "Capture \"\(change.displayName)\" Again"
                    item.representedObject = nil
                    item.isHidden = false
                    item.isEnabled = true
                    item.toolTip = "Remove the app from Application Exclusions"
                case .website(let domain)
                where appModel.isDomainEffectivelyExcluded(domain):
                    item.title = "Capture \"\(domain)\" Again"
                    item.representedObject = nil
                    item.isHidden = false
                    item.isEnabled = true
                    item.toolTip = "Remove the website from Website Exclusions"
                default:
                    item.representedObject = nil
                    item.isHidden = true
                    item.isEnabled = false
                    item.toolTip = nil
                }
            case .setup:
                item.title =
                    appModel.permissions.isCaptureReady
                    ? "Permissions & Privacy..."
                    : "Set Up Screen Capture..."
                item.image = menuSymbolImage(
                    appModel.permissions.isCaptureReady
                        ? "checkmark.shield" : "exclamationmark.shield"
                )
                if case .setupCapture = status.primaryAction {
                    item.isHidden = true
                } else {
                    item.isHidden = false
                }
                item.isEnabled = true
            case .checkForUpdates:
                item.isEnabled = AppUpdateController.shared.canCheckForUpdates
                item.toolTip =
                    appModel.airgapMode
                    ? "Turn off Keep Screenlogger Offline to check for updates"
                    : "Check GitHub Releases for a newer verified version"
            default:
                break
            }
        }
    }

    private func statusMenuTitle(_ status: CaptureStatusPresentation) -> String {
        guard let actionLabel = status.actionLabel else { return status.compactLabel }
        return "\(status.compactLabel) - \(actionLabel)"
    }

    private func statusAccessibilityHelp(_ status: CaptureStatusPresentation) -> String {
        guard let actionHint = status.actionHint else { return status.detail }
        return "\(status.detail) \(actionHint)"
    }

    private var modelCaptureOnceInProgress: Bool {
        if case .inProgress = appModel.captureOnceState { return true }
        return false
    }

    /// Frontmost user app, excluding Screenlogger itself.
    private static func frontmostUserApp() -> NSRunningApplication? {
        let selfBID = Bundle.main.bundleIdentifier
        if let app = NSWorkspace.shared.frontmostApplication,
            app.bundleIdentifier != selfBID,
            !app.isTerminated
        {
            return app
        }
        // Fallback: highest-layer regular app that isn't us.
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular
                && $0.bundleIdentifier != selfBID
                && !$0.isTerminated
                && $0.isActive
        }
    }

}
