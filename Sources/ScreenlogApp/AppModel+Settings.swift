import AppKit
import Foundation
import ScreenlogCore

typealias CaptureQuality = CaptureQualityPreset

/// Loads persisted preferences and applies capture-facing settings.
///
/// Property observers on AppModel deliberately enter through these methods so
/// persistence and engine updates remain serialized on the main actor.
@MainActor
extension AppModel {
    private enum DefaultsKey {
        static let interval = CapturePreferenceStore.intervalSeconds
        static let maxDimension = CapturePreferenceStore.maxDimension
        static let retentionDays = CapturePreferenceStore.retentionDays
        static let storageCapMB = CapturePreferenceStore.storageCapMB
    }

    // MARK: - Settings persistence

    func loadSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }

        let d = preferences
        let snap = CapturePreferenceStore.load(from: d)
        if d.object(forKey: DefaultsKey.interval) != nil {
            intervalSeconds = max(0.5, d.double(forKey: DefaultsKey.interval))
        }
        if d.object(forKey: DefaultsKey.maxDimension) != nil {
            maxDimension = snap.maxDimension
        }
        if d.object(forKey: DefaultsKey.retentionDays) != nil {
            retentionDays = max(1, d.integer(forKey: DefaultsKey.retentionDays))
        }
        if d.object(forKey: DefaultsKey.storageCapMB) != nil {
            storageCapMB = max(0, Int64(d.integer(forKey: DefaultsKey.storageCapMB)))
        }
        airgapMode = d.bool(forKey: ProductPreferenceKey.airgapMode)
        FaviconCache.shared.airgapMode = airgapMode
        remoteFaviconsEnabled = d.bool(forKey: ProductPreferenceKey.remoteFaviconsEnabled)
        FaviconCache.shared.remoteFetchingEnabled = remoteFaviconsEnabled
        showDockIcon = d.bool(forKey: ProductPreferenceKey.showDockIcon)
        if d.object(forKey: ProductPreferenceKey.pauseOnInactivity) != nil {
            pauseOnInactivity = d.bool(forKey: ProductPreferenceKey.pauseOnInactivity)
        }
        captureDisplayMode = snap.displayMode
        if let raw = d.string(forKey: ProductPreferenceKey.appearance),
            let pref = AppearancePreference(rawValue: raw)
        {
            appearancePreference = pref
        }
        if let raw = d.string(forKey: ProductPreferenceKey.storageMode),
            let mode = StorageManagementMode(rawValue: raw)
        {
            storageMode = mode
        }
        // Snapshot-class prefs (same keys as CapturePreferenceStore).
        if d.object(forKey: ProductPreferenceKey.stillEncoding) != nil {
            stillEncoding = snap.stillEncoding
        }
        if d.object(forKey: ProductPreferenceKey.ocrLanguages) != nil {
            ocrLanguagesCSV = snap.ocrLanguagesCSV
        }
        if d.object(forKey: ProductPreferenceKey.differentialOCR) != nil {
            differentialOCREnabled = snap.differentialOCR
        }
        let audio = AudioTranscriptionPreferenceStore.load(from: d)
        audioTranscriptionEnabled = audio.isEnabled
        computerAudioTranscriptionEnabled = audio.computerAudioEnabled
        microphoneTranscriptionEnabled = audio.microphoneEnabled
        if let raw = d.string(forKey: ProductPreferenceKey.accentColor),
            let accent = AccentColorPreference(rawValue: raw)
        {
            accentColorPreference = accent
        }
        if d.object(forKey: ProductPreferenceKey.showOpenExternally) != nil {
            showOpenExternally = d.bool(forKey: ProductPreferenceKey.showOpenExternally)
        }
        if d.object(forKey: ProductPreferenceKey.showLiveText) != nil {
            showLiveText = d.bool(forKey: ProductPreferenceKey.showLiveText)
        }
        if d.object(forKey: ProductPreferenceKey.showZoomControls) != nil {
            showZoomControls = d.bool(forKey: ProductPreferenceKey.showZoomControls)
        }
        if d.object(forKey: ProductPreferenceKey.showSegmentNavigation) != nil {
            showSegmentNavigation = d.bool(forKey: ProductPreferenceKey.showSegmentNavigation)
        }
        if d.object(forKey: ProductPreferenceKey.excludePrivateTabs) != nil {
            excludePrivateTabs = d.bool(forKey: ProductPreferenceKey.excludePrivateTabs)
        }
        if d.object(forKey: ProductPreferenceKey.pauseWhenBrowserAddressUnavailable) != nil {
            pauseWhenBrowserAddressUnavailable = BrowserAddressProtectionPreference.value(from: d)
        }
        if d.object(forKey: ProductPreferenceKey.cliEnabled) != nil {
            cliEnabled = d.bool(forKey: ProductPreferenceKey.cliEnabled)
        } else {
            cliEnabled = true
        }
        if let value = d.string(forKey: ProductPreferenceKey.assistantHandoffRouting) {
            libraryAssistantRoutingPreference = LibraryAssistantRoutingPreference(
                persistedValue: value
            )
        }
        localToolCaptureControlAndMaintenanceEnabled =
            LocalToolControlAccessPreference.isEnabled(in: d)
        // The live ServiceManagement status is authoritative. A stored request
        // must never make the switch look enabled when macOS rejected it.
        refreshLaunchAtLoginState()
        recentSearchQueries = recentSearchStore.all()
        pinnedSessionIDs = sessionPinStore.pinnedIDs()
        reloadExclusionsFromStore()
        applyAppearancePreference()
        #if DEBUG
            AppUITestFixture.applyPresentationOverridesIfRequested(on: self)
        #endif
        applyDockIconPreference()
    }

    func persistAndApplySettings() {
        guard !isLoadingSettings else { return }
        let d = preferences
        d.set(intervalSeconds, forKey: DefaultsKey.interval)
        d.set(maxDimension, forKey: DefaultsKey.maxDimension)
        d.set(retentionDays, forKey: DefaultsKey.retentionDays)
        d.set(storageCapMB, forKey: DefaultsKey.storageCapMB)
        // Debounce engine apply slightly so slider/typing does not thrash.
        settingsApplyTask?.cancel()
        settingsApplyTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            applySettingsToEngine()
        }
    }

    func applySettingsToEngine() {
        let plan = storageMaintenancePlan()
        engine.applySettings(
            intervalSeconds: intervalSeconds,
            maxDimension: maxDimension,
            stillQuality: quality.stillCompressionQuality,
            retentionDays: plan.retentionDays,
            storageCapMB: plan.storageCapMB,
            autoCompactEnabled: plan.runCompact,
            autoRetentionEnabled: plan.runRetention,
            pauseOnInactivity: pauseOnInactivity,
            inactivityThresholdSeconds: 300,
            excludePrivateTabs: excludePrivateTabs,
            pauseWhenBrowserAddressUnavailable: pauseWhenBrowserAddressUnavailable,
            displayMode: captureDisplayMode
        )
        applySnapshotPrefsToEngine()
        applyAudioTranscriptionSettingsToEngine()
    }

    func applySnapshotPrefsToEngine() {
        let langs =
            ocrLanguagesCSV
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        engine.applySnapshotSettings(
            preferJPEG: stillEncoding == .jpeg,
            ocrLanguages: langs,
            differentialOCR: differentialOCREnabled
        )
    }

    func persistAndApplyAudioTranscriptionSettings() {
        let snapshot = currentAudioTranscriptionSettings
        AudioTranscriptionPreferenceStore.save(snapshot, to: preferences)
        engine.applyAudioTranscriptionSettings(snapshot)
    }

    func applyAudioTranscriptionSettingsToEngine() {
        engine.applyAudioTranscriptionSettings(currentAudioTranscriptionSettings)
    }

    var currentAudioTranscriptionSettings: AudioTranscriptionPreferenceStore.Snapshot {
        AudioTranscriptionPreferenceStore.Snapshot(
            isEnabled: audioTranscriptionEnabled,
            computerAudioEnabled: computerAudioTranscriptionEnabled,
            microphoneEnabled: microphoneTranscriptionEnabled
        )
    }

    /// Called only from the explicit Settings switch. Loading persisted state
    /// never invokes the microphone prompt.
    func setAudioTranscriptionEnabledFromUserAction(_ enabled: Bool) {
        guard enabled, microphoneTranscriptionEnabled,
            MicrophoneAuthorization.current == .notDetermined
        else {
            audioTranscriptionEnabled = enabled
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await MicrophoneAuthorization.request()
            self.audioTranscriptionEnabled = true
        }
    }

    /// A microphone permission prompt is also appropriate when the user adds
    /// the microphone after starting in computer-audio-only mode.
    func setMicrophoneTranscriptionEnabledFromUserAction(_ enabled: Bool) {
        guard enabled, audioTranscriptionEnabled,
            MicrophoneAuthorization.current == .notDetermined
        else {
            microphoneTranscriptionEnabled = enabled
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await MicrophoneAuthorization.request()
            self.microphoneTranscriptionEnabled = true
        }
    }

    func retryMicrophoneAuthorizationFromUserAction() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if MicrophoneAuthorization.current == .notDetermined {
                _ = await MicrophoneAuthorization.request()
            } else if MicrophoneAuthorization.current != .authorized {
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
            self.applyAudioTranscriptionSettingsToEngine()
        }
    }

    /// Pure map of current UI storage mode to engine maintenance plan (unit-tested).
    func storageMaintenancePlan() -> StorageMaintenancePlan {
        storageMode.maintenancePlan(
            retentionDays: retentionDays,
            storageCapMB: storageCapMB
        )
    }

    /// Days/cap used by manual Clean / engine when mode is Limit.
    func effectiveRetentionForEngine() -> (days: Int, capMB: Int64) {
        let plan = storageMaintenancePlan()
        return (plan.retentionDays, plan.storageCapMB)
    }

    func setQuality(_ q: CaptureQuality) {
        maxDimension = q.maxDimension
    }

}
