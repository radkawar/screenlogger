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
        appModel.openSearchWindow()
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
        appModel.openMainShell(origin: .direct)
    }

    @objc func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

}
