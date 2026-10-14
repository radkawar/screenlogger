import AppKit

extension StatusMenuController {
    // MARK: - Actions

    @objc func performCaptureStatusAction(_ sender: Any?) {
        if let action = appModel.captureStatusPresentation().primaryAction {
            appModel.performCaptureStatusPrimaryAction(action, setupOrigin: .direct)
        }
        updateStatusItemAppearance()
    }

    @objc func openSearchShell(_ sender: Any?) {
        appModel.showLibrarySection(.search)
    }

    @objc func openSessions(_ sender: Any?) {
        appModel.showLibrarySection(.sessions)
    }

    @objc func toggleRecording(_ sender: Any?) {
        appModel.performKeyboardShortcutCaptureToggle()
        updateStatusItemAppearance()
    }

    @objc func captureOnce(_ sender: Any?) {
        guard appModel.libraryStartupIssue == nil,
            appModel.libraryRestoreState != .restoring
        else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await appModel.captureOnce()
            if case .success = appModel.captureOnceState {
                showCaptureOnceSuccessFeedback()
            } else if case .failure = appModel.captureOnceState {
                // Keep this as a one-shot request: Capture Once publishes its
                // typed failure without changing automatic-capture intent.
                // Settings then reveals the explanation, Retry, and any exact
                // Storage, Privacy, or Exclusions recovery action.
                appModel.openProductSettings(.captureOnce)
            } else {
                updateStatusItemAppearance()
            }
        }
    }

    @objc func openSettingsWindow(_ sender: Any?) {
        appModel.openProductSettings()
    }

    @objc func openAudioTranscriptionSettings(_ sender: Any?) {
        appModel.openProductSettings(.captureAudio)
    }

    @objc func toggleAudioTranscription(_ sender: Any?) {
        let presentation = audioTranscriptionMenuPresentation
        switch presentation.action {
        case .toggle:
            appModel.setAudioTranscriptionEnabledFromUserAction(
                !appModel.audioTranscriptionEnabled
            )
        case .openSettings:
            openAudioTranscriptionSettings(sender)
        case .none:
            break
        }
        updateStatusItemAppearance()
    }

    @objc func hideMenuBarIcon(_ sender: Any?) {
        // Let the status menu dismiss before presenting its confirmation.
        // Attaching a sheet while AppKit still owns the menu-tracking window
        // can leave the alert outside the app's accessible window hierarchy.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.presentHideMenuBarIconConfirmation()
        }
    }

    private func presentHideMenuBarIconConfirmation() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Hide the Menu Bar Icon?"
        alert.informativeText =
            "Screenlogger will keep running in the background. Open Screenlogger again from Spotlight, Finder, or the Dock to restore the icon."
        alert.addButton(withTitle: "Hide Icon")
        alert.addButton(withTitle: "Cancel")

        let hostWindow =
            NSApp.mainWindow
            ?? NSApp.windows.first {
                $0.isVisible && $0.level == .normal && $0.styleMask.contains(.titled)
            }
        if let hostWindow {
            alert.beginSheetModal(for: hostWindow) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.hideStatusItemUntilReopen()
            }
            return
        }

        NSRunningApplication.current.activate(options: [.activateAllWindows])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        hideStatusItemUntilReopen()
    }

    @objc func openHelp(_ sender: Any?) {
        appModel.openProductGuide()
    }

    @objc func openAbout(_ sender: Any?) {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.orderFrontStandardAboutPanel(sender)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        AppUpdateController.shared.checkForUpdates()
    }

    @objc func openPrivacySettings(_ sender: Any?) {
        if appModel.permissions.isCaptureReady {
            appModel.openProductSettings(.privacyPermissions)
        } else {
            appModel.showPermissions(origin: .direct)
        }
    }

    @objc func revealLibrary(_ sender: Any?) {
        appModel.revealLibrary()
    }

    @objc func revealLibraryDiagnostics(_ sender: Any?) {
        appModel.revealLibraryDiagnostics()
    }

    @objc func pauseRecordingOneHour(_ sender: Any?) {
        if let until = appModel.recordingPausedUntil, until > Date() {
            if appModel.permissions.isCaptureReady {
                appModel.resumeRecordingFromPause()
            } else {
                appModel.showPermissions(origin: .direct)
            }
        } else {
            appModel.pauseRecordingForOneHour()
        }
        updateStatusItemAppearance()
    }

    @objc func excludeFrontmostApp(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
            let bundleID = item.representedObject as? String,
            !bundleID.isEmpty
        else {
            appModel.statusMessage = "No app to exclude"
            return
        }
        if appModel.excludedBundles.contains(where: {
            $0.caseInsensitiveCompare(bundleID) == .orderedSame
        }) {
            appModel.openProductSettings(.exclusionsApplications)
            return
        }
        appModel.excludeApplication(bundleID: bundleID)
    }

    @objc func excludeCurrentWebsite(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
            let domain = item.representedObject as? String,
            !domain.isEmpty
        else {
            appModel.statusMessage = "Website address unavailable"
            return
        }
        if appModel.isDomainEffectivelyExcluded(domain) {
            appModel.openProductSettings(.exclusionsWebsites)
            return
        }
        appModel.excludeWebsite(domain: domain)
    }

    @objc func undoLastCaptureExclusion(_ sender: Any?) {
        appModel.undoRecentCaptureExclusion()
    }

    @objc func openTimeline(_ sender: Any?) {
        appModel.showMainShellFromGlobalRoute()
    }

    @objc func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

}
