@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import Foundation
import OSLog
@preconcurrency import ScreenCaptureKit

private let audioLog = Logger(subsystem: "dev.screenlog", category: "audio-transcription")

private struct AudioPCMEnvelope: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let presentationTime: CMTime
    let observedAtMs: Int64
}

@available(macOS 26.0, *)
private actor AudioTranscriptionPipeline {
    private let store: Store
    private let locale: Locale
    private var sessions: [TranscriptSource: OnDeviceTranscriptionSession] = [:]
    // A stream must prove that its current foreground context is allowed
    // before the first sample reaches an analyzer.
    private var acceptsAudio = false

    init(store: Store, locale: Locale) {
        self.store = store
        self.locale = locale
    }

    func receive(_ envelope: AudioPCMEnvelope, source: TranscriptSource) async {
        guard acceptsAudio else { return }
        let session: OnDeviceTranscriptionSession
        if let existing = sessions[source] {
            session = existing
        } else {
            let created = OnDeviceTranscriptionSession(
                source: source,
                locale: locale,
                store: store
            )
            sessions[source] = created
            session = created
        }
        do {
            try await session.append(
                envelope.buffer,
                presentationTime: envelope.presentationTime,
                observedAtMs: envelope.observedAtMs
            )
        } catch {
            await session.cancel()
            sessions[source] = nil
            audioLog.error(
                "audio analyzer source=\(source.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Closing sessions on every protected or changed context guarantees an
    /// utterance can never bridge into or out of excluded activity.
    func setAcceptsAudio(_ value: Bool, closeCurrentSegments: Bool) async {
        acceptsAudio = value
        guard closeCurrentSegments else { return }
        let active = sessions.values
        sessions.removeAll()
        for session in active { await session.finish() }
    }

    func finish() async {
        acceptsAudio = false
        let active = sessions.values
        sessions.removeAll()
        for session in active { await session.finish() }
    }
}

@available(macOS 15.0, *)
private final class AudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let deliver: @Sendable (AudioPCMEnvelope, TranscriptSource) -> Void
    private let stateLock = NSLock()
    private var acceptsSamples = true

    init(deliver: @escaping @Sendable (AudioPCMEnvelope, TranscriptSource) -> Void) {
        self.deliver = deliver
    }

    func setAcceptsSamples(_ acceptsSamples: Bool) {
        stateLock.lock()
        self.acceptsSamples = acceptsSamples
        stateLock.unlock()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        stateLock.lock()
        let shouldDeliver = acceptsSamples
        stateLock.unlock()
        guard shouldDeliver else { return }

        let source: TranscriptSource
        switch outputType {
        case .audio: source = .computer
        case .microphone: source = .microphone
        default: return
        }
        guard let buffer = Self.copyPCMBuffer(from: sampleBuffer) else { return }
        deliver(
            AudioPCMEnvelope(
                buffer: buffer,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                observedAtMs: Int64(Date().timeIntervalSince1970 * 1_000)
            ),
            source
        )
    }

    private static func copyPCMBuffer(
        from sampleBuffer: CMSampleBuffer
    ) -> AVAudioPCMBuffer? {
        guard CMSampleBufferDataIsReady(sampleBuffer),
            let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            let format = AVAudioFormat(streamDescription: streamDescription)
        else { return nil }

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0,
            sampleCount <= Int(Int32.max),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleCount)
            )
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}

@available(macOS 12.3, *)
private final class AudioStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let stopped: @Sendable (Error) -> Void

    init(stopped: @escaping @Sendable (Error) -> Void) {
        self.stopped = stopped
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stopped(error)
    }
}

private struct AudioPrivacyContext: Equatable {
    var bundleID: String?
    var domain: String?
    var isAllowed: Bool
    var pauseDetail: String?
}

/// Owns the opt-in SCStream and its two independent on-device analyzers. The
/// coordinator never creates an audio file and never invokes a legacy speech
/// recognizer that could fall back to a server.
@MainActor
final class AudioTranscriptionCoordinator {
    var statusDidChange: (@MainActor @Sendable (AudioTranscriptionStatus) -> Void)?

    private var stream: SCStream?
    private var streamOutput: AnyObject?
    private var streamDelegate: AnyObject?
    private var pipeline: AnyObject?
    private var privacyTask: Task<Void, Never>?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var generation = UUID()
    private var privacyEvaluationRevision: UInt = 0
    private var lastPrivacyContext: AudioPrivacyContext?
    private var applicationFilterIsReady = true
    private var filteredBundleIDs: Set<String> = []
    private var filterDisplayID: CGDirectDisplayID?
    private var captureAvailable = true
    private let browserURL = BrowserURLService()

    private(set) var status: AudioTranscriptionStatus = .off {
        didSet {
            guard status != oldValue else { return }
            statusDidChange?(status)
        }
    }

    func setCaptureAvailable(_ available: Bool) async {
        guard captureAvailable != available else { return }
        captureAvailable = available
        privacyEvaluationRevision &+= 1
        if !available {
            setStreamAcceptsSamples(false)
        }
        if !available, #available(macOS 26.0, *),
            let activePipeline = pipeline as? AudioTranscriptionPipeline
        {
            await activePipeline.setAcceptsAudio(
                false,
                closeCurrentSegments: true
            )
        }
        if !available, stream != nil {
            status = AudioTranscriptionStatus(
                phase: .capturePaused,
                detail: "Audio transcription is paused with capture."
            )
        }
    }

    func apply(
        settings: AudioTranscriptionPreferenceStore.Snapshot,
        captureIsRunning: Bool,
        store: Store?,
        exclusions: ExclusionStore,
        pauseWhenBrowserAddressUnavailable: Bool
    ) async {
        let enabledSources = settings.enabledSources
        guard settings.isEnabled else {
            await stop(finalStatus: .off)
            return
        }
        guard AudioTranscriptionSupport.isAvailable else {
            await stop(
                finalStatus: AudioTranscriptionStatus(
                    phase: .unavailable,
                    detail: AudioTranscriptionSupport.requirementDescription
                )
            )
            return
        }
        guard !enabledSources.isEmpty else {
            await stop(
                finalStatus: AudioTranscriptionStatus(
                    phase: .off,
                    detail: "Choose Computer Audio, Microphone, or both."
                )
            )
            return
        }
        guard captureIsRunning, let store else {
            await stop(
                finalStatus: AudioTranscriptionStatus(
                    phase: .capturePaused,
                    detail: "Audio transcription starts when capture is running."
                )
            )
            return
        }
        var availableSources = enabledSources
        if availableSources.contains(.microphone), MicrophoneAuthorization.current != .authorized {
            availableSources.remove(.microphone)
        }
        guard !availableSources.isEmpty else {
            await stop(
                finalStatus: AudioTranscriptionStatus(
                    phase: .permissionRequired,
                    detail: "Allow Microphone access to transcribe your voice."
                )
            )
            return
        }

        await stop(finalStatus: nil)
        let requestedGeneration = UUID()
        generation = requestedGeneration
        captureAvailable = true
        status = AudioTranscriptionStatus(
            phase: .preparing,
            detail: "Preparing Apple's on-device speech model...",
            preparationProgress: 0
        )

        do {
            if #available(macOS 26.0, *) {
                let locale = try await OnDeviceSpeechPreparation.prepare { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == requestedGeneration else { return }
                        self.status = AudioTranscriptionStatus(
                            phase: .preparing,
                            detail: "Preparing Apple's on-device speech model...",
                            preparationProgress: progress
                        )
                    }
                }
                guard generation == requestedGeneration else { return }
                try await startStream(
                    sources: availableSources,
                    store: store,
                    locale: locale,
                    exclusions: exclusions
                )
                guard generation == requestedGeneration else {
                    await stop(finalStatus: nil)
                    return
                }
                await startPrivacyMonitoring(
                    sources: availableSources,
                    exclusions: exclusions,
                    pauseWhenBrowserAddressUnavailable: pauseWhenBrowserAddressUnavailable
                )
            }
        } catch {
            guard generation == requestedGeneration else { return }
            audioLog.error("audio transcription start failed: \(error.localizedDescription, privacy: .public)")
            await stop(
                finalStatus: AudioTranscriptionStatus(
                    phase: .failed,
                    detail: error.localizedDescription
                )
            )
        }
    }

    func stop(finalStatus: AudioTranscriptionStatus = .off) async {
        await stop(finalStatus: Optional(finalStatus))
    }

    /// Close the in-memory sample gate synchronously. Ordinary capture stop is
    /// intentionally synchronous at the UI boundary, while SCStream teardown
    /// still completes asynchronously afterward.
    func deactivateImmediately(finalStatus: AudioTranscriptionStatus? = .off) {
        generation = UUID()
        privacyEvaluationRevision &+= 1
        setStreamAcceptsSamples(false)
        privacyTask?.cancel()
        privacyTask = nil
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }
        if let finalStatus { status = finalStatus }
    }

    private func stop(finalStatus: AudioTranscriptionStatus?) async {
        deactivateImmediately(finalStatus: finalStatus)
        lastPrivacyContext = nil
        applicationFilterIsReady = true
        filteredBundleIDs = []
        filterDisplayID = nil
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        streamOutput = nil
        streamDelegate = nil
        if #available(macOS 26.0, *),
            let activePipeline = pipeline as? AudioTranscriptionPipeline
        {
            await activePipeline.finish()
        }
        pipeline = nil
        if let finalStatus { status = finalStatus }
    }

    @available(macOS 26.0, *)
    private func startStream(
        sources: Set<TranscriptSource>,
        store: Store,
        locale: Locale,
        exclusions: ExclusionStore
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let excludedBundleIDs = excludedApplicationBundleIDs(from: exclusions)
        let excludedApplications = content.applications.filter {
            excludedBundleIDs.contains($0.bundleIdentifier.lowercased())
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = sources.contains(.computer)
        configuration.captureMicrophone = sources.contains(.microphone)
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.showsCursor = false

        let activePipeline = AudioTranscriptionPipeline(store: store, locale: locale)
        let output = AudioStreamOutput { envelope, source in
            Task { await activePipeline.receive(envelope, source: source) }
        }
        // The privacy context is evaluated only after startCapture succeeds.
        // Keep the output closed until that check completes.
        output.setAcceptsSamples(false)
        let delegate = AudioStreamDelegate { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                audioLog.error("audio stream stopped: \(error.localizedDescription, privacy: .public)")
                await self.stop(
                    finalStatus: AudioTranscriptionStatus(
                        phase: .failed,
                        detail: "Audio capture stopped: \(error.localizedDescription)"
                    )
                )
            }
        }
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: delegate
        )
        if sources.contains(.computer) {
            try stream.addStreamOutput(
                output,
                type: .audio,
                sampleHandlerQueue: DispatchQueue(
                    label: "dev.screenlog.audio.computer",
                    qos: .userInitiated
                )
            )
        }
        if sources.contains(.microphone) {
            try stream.addStreamOutput(
                output,
                type: .microphone,
                sampleHandlerQueue: DispatchQueue(
                    label: "dev.screenlog.audio.microphone",
                    qos: .userInitiated
                )
            )
        }
        try await stream.startCapture()
        self.pipeline = activePipeline
        self.streamOutput = output
        self.streamDelegate = delegate
        self.stream = stream
        filteredBundleIDs = excludedBundleIDs
        filterDisplayID = display.displayID
    }

    @available(macOS 26.0, *)
    private func startPrivacyMonitoring(
        sources: Set<TranscriptSource>,
        exclusions: ExclusionStore,
        pauseWhenBrowserAddressUnavailable: Bool
    ) async {
        privacyTask?.cancel()
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Close the sample gate synchronously with activation, before
                // Accessibility and exclusion checks perform any async work.
                self.setStreamAcceptsSamples(false)
                await self.refreshPrivacyState(
                    sources: sources,
                    exclusions: exclusions,
                    pauseWhenBrowserAddressUnavailable: pauseWhenBrowserAddressUnavailable
                )
            }
        }

        await refreshPrivacyState(
            sources: sources,
            exclusions: exclusions,
            pauseWhenBrowserAddressUnavailable: pauseWhenBrowserAddressUnavailable
        )
        privacyTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled else { return }
                await self.refreshPrivacyState(
                    sources: sources,
                    exclusions: exclusions,
                    pauseWhenBrowserAddressUnavailable: pauseWhenBrowserAddressUnavailable
                )
            }
        }
    }

    @available(macOS 26.0, *)
    private func refreshPrivacyState(
        sources: Set<TranscriptSource>,
        exclusions: ExclusionStore,
        pauseWhenBrowserAddressUnavailable: Bool
    ) async {
        privacyEvaluationRevision &+= 1
        let revision = privacyEvaluationRevision
        let filterReady = await refreshApplicationFilterIfNeeded(exclusions: exclusions)
        let context = currentPrivacyContext(
            exclusions: exclusions,
            pauseWhenBrowserAddressUnavailable: pauseWhenBrowserAddressUnavailable
        )
        let contextChanged =
            context != lastPrivacyContext
            || filterReady != applicationFilterIsReady
        lastPrivacyContext = context
        applicationFilterIsReady = filterReady
        let acceptsAudio = captureAvailable && context.isAllowed && filterReady

        if !acceptsAudio { setStreamAcceptsSamples(false) }
        if let activePipeline = pipeline as? AudioTranscriptionPipeline {
            await activePipeline.setAcceptsAudio(
                acceptsAudio,
                closeCurrentSegments: contextChanged
            )
        }
        guard !Task.isCancelled, revision == privacyEvaluationRevision else { return }
        setStreamAcceptsSamples(acceptsAudio)

        if !captureAvailable {
            status = AudioTranscriptionStatus(
                phase: .capturePaused,
                detail: "Audio transcription is paused with capture."
            )
        } else if !filterReady {
            status = AudioTranscriptionStatus(
                phase: .privacyPaused,
                detail: "Transcription is paused because app exclusions could not be updated."
            )
        } else if context.isAllowed {
            status = AudioTranscriptionStatus(
                phase: .active,
                activeSources: sources,
                detail: activeDetail(for: sources)
            )
        } else {
            status = AudioTranscriptionStatus(
                phase: .privacyPaused,
                detail: context.pauseDetail
                    ?? "Transcription is paused for protected activity."
            )
        }
    }

    @available(macOS 26.0, *)
    private func refreshApplicationFilterIfNeeded(
        exclusions: ExclusionStore
    ) async -> Bool {
        let desired = excludedApplicationBundleIDs(from: exclusions)
        guard desired != filteredBundleIDs else { return true }
        guard let stream else { return false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard
                let display = content.displays.first(where: {
                    $0.displayID == filterDisplayID
                }) ?? content.displays.first
            else { return false }
            let applications = content.applications.filter {
                desired.contains($0.bundleIdentifier.lowercased())
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: applications,
                exceptingWindows: []
            )
            try await stream.updateContentFilter(filter)
            filteredBundleIDs = desired
            filterDisplayID = display.displayID
            return true
        } catch {
            audioLog.error(
                "audio privacy filter update failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func setStreamAcceptsSamples(_ value: Bool) {
        if #available(macOS 15.0, *) {
            (streamOutput as? AudioStreamOutput)?.setAcceptsSamples(value)
        }
    }

    private func currentPrivacyContext(
        exclusions: ExclusionStore,
        pauseWhenBrowserAddressUnavailable: Bool
    ) -> AudioPrivacyContext {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let bundleID = frontmost?.bundleIdentifier
        var attribution: BrowserURLAttribution?
        if BrowserURLService.isSupportedBrowser(bundleID: bundleID) {
            attribution = browserURL.browserAttribution(for: frontmost)
        }
        let domain = attribution?.domain
        if ScreenloggerCapturePrivacy.isScreenlogger(bundleID: bundleID) {
            return AudioPrivacyContext(
                bundleID: bundleID,
                domain: domain,
                isAllowed: false,
                pauseDetail: "Transcription is paused while Screenlogger is active."
            )
        }
        if exclusions.isExcluded(bundleID: bundleID, domain: domain) {
            return AudioPrivacyContext(
                bundleID: bundleID,
                domain: domain,
                isAllowed: false,
                pauseDetail: "The current app or website is excluded."
            )
        }
        if PrivateBrowsingDetector.looksPrivate(
            title: attribution?.title,
            url: attribution?.url,
            bundleID: bundleID
        ) {
            return AudioPrivacyContext(
                bundleID: bundleID,
                domain: domain,
                isAllowed: false,
                pauseDetail: "Transcription is paused in Private Browsing."
            )
        }
        if BrowserCapturePrivacyPolicy.shouldPause(
            capturedBundleID: bundleID,
            attribution: attribution,
            pauseWhenAddressUnavailable: pauseWhenBrowserAddressUnavailable
        ) {
            return AudioPrivacyContext(
                bundleID: bundleID,
                domain: domain,
                isAllowed: false,
                pauseDetail: "Transcription is paused because the website address is unavailable."
            )
        }
        return AudioPrivacyContext(
            bundleID: bundleID,
            domain: domain,
            isAllowed: true,
            pauseDetail: nil
        )
    }

    private func excludedApplicationBundleIDs(
        from exclusions: ExclusionStore
    ) -> Set<String> {
        var bundleIDs = Set(exclusions.allSorted().map { $0.lowercased() })
        if exclusions.passwordManagersCategoryEnabled {
            bundleIDs.formUnion(ExclusionCatalog.passwordManagerBundleIDs.map { $0.lowercased() })
        }
        return ScreenloggerCapturePrivacy.includingScreenlogger(in: bundleIDs)
    }

    private func activeDetail(for sources: Set<TranscriptSource>) -> String {
        if sources == Set(TranscriptSource.allCases) {
            return "Transcribing microphone and computer audio on this Mac."
        }
        if sources.contains(.microphone) {
            return "Transcribing microphone audio on this Mac."
        }
        return "Transcribing computer audio on this Mac."
    }
}
