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

private struct AudioIngressPacket: @unchecked Sendable {
    let envelope: AudioPCMEnvelope
    let source: TranscriptSource
    let authorizationRevision: UInt64
    let capturedAtUptimeNanoseconds: UInt64
    let validationDeadlineUptimeNanoseconds: UInt64
    let durationNanoseconds: UInt64
}

/// A synchronous privacy boundary shared by ScreenCaptureKit's callback and
/// the async transcription pipeline. Closing it invalidates packets already
/// copied or dequeued so they cannot enter a later privacy context.
final class AudioSampleAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var acceptsSamples = false
    private var validatedThroughUptimeNanoseconds: UInt64 = 0

    func validateAndOpen(at uptimeNanoseconds: UInt64) {
        lock.lock()
        acceptsSamples = true
        validatedThroughUptimeNanoseconds = max(
            validatedThroughUptimeNanoseconds,
            uptimeNanoseconds
        )
        lock.unlock()
    }

    func close() {
        lock.lock()
        acceptsSamples = false
        validatedThroughUptimeNanoseconds = 0
        revision &+= 1
        lock.unlock()
    }

    func revisionIfOpen() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return acceptsSamples ? revision : nil
    }

    func accepts(revision candidate: UInt64, capturedAt uptimeNanoseconds: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return acceptsSamples
            && revision == candidate
            && validatedThroughUptimeNanoseconds >= uptimeNanoseconds
    }
}

@available(macOS 26.0, *)
private actor AudioTranscriptionPipeline {
    private let store: Store
    private let locale: Locale
    private let authorization: AudioSampleAuthorization
    private let failureHandler: @Sendable (TranscriptSource, String) -> Void
    private var sessions: [TranscriptSource: OnDeviceTranscriptionSession] = [:]
    private var failedSources: Set<TranscriptSource> = []
    // A stream must prove that its current foreground context is allowed
    // before the first sample reaches an analyzer.
    private var acceptsAudio = false

    init(
        store: Store,
        locale: Locale,
        authorization: AudioSampleAuthorization,
        failureHandler: @escaping @Sendable (TranscriptSource, String) -> Void
    ) {
        self.store = store
        self.locale = locale
        self.authorization = authorization
        self.failureHandler = failureHandler
    }

    func receive(_ packet: AudioIngressPacket) async {
        guard acceptsAudio,
            !failedSources.contains(packet.source),
            authorization.accepts(
                revision: packet.authorizationRevision,
                capturedAt: packet.capturedAtUptimeNanoseconds
            )
        else { return }
        let source = packet.source
        let envelope = packet.envelope
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
            failedSources.insert(source)
            audioLog.error(
                "audio analyzer source=\(source.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            failureHandler(source, error.localizedDescription)
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
        failedSources.removeAll()
        let active = sessions.values
        sessions.removeAll()
        for session in active { await session.finish() }
    }
}

@available(macOS 15.0, *)
private final class AudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let deliver: @Sendable (AudioIngressPacket) async -> Void
    private let authorization: AudioSampleAuthorization
    private let ingressLock = NSLock()
    private var pendingBySource: [TranscriptSource: BoundedNewestQueue<AudioIngressPacket>] = [:]
    private var drainingSources: Set<TranscriptSource> = []
    private var droppedPacketCounts: [TranscriptSource: Int] = [:]
    private var queuedDurationBySource: [TranscriptSource: UInt64] = [:]
    private let maximumQueueDepth = 96
    private let maximumQueuedDurationNanoseconds: UInt64 = 2_000_000_000
    private let privacyValidationTimeoutNanoseconds: UInt64 = 800_000_000

    init(
        authorization: AudioSampleAuthorization,
        deliver: @escaping @Sendable (AudioIngressPacket) async -> Void
    ) {
        self.authorization = authorization
        self.deliver = deliver
    }

    func setAcceptsSamples(_ acceptsSamples: Bool) {
        guard !acceptsSamples else { return }
        authorization.close()
        ingressLock.lock()
        pendingBySource.removeAll(keepingCapacity: true)
        queuedDurationBySource.removeAll(keepingCapacity: true)
        ingressLock.unlock()
    }

    func validateAndAcceptSamples(through uptimeNanoseconds: UInt64) {
        authorization.validateAndOpen(at: uptimeNanoseconds)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard let authorizationRevision = authorization.revisionIfOpen() else { return }

        let source: TranscriptSource
        switch outputType {
        case .audio: source = .computer
        case .microphone: source = .microphone
        default: return
        }
        guard let buffer = Self.copyPCMBuffer(from: sampleBuffer) else { return }
        let capturedAt = DispatchTime.now().uptimeNanoseconds
        let durationNanoseconds = UInt64(
            (Double(buffer.frameLength) / max(1, buffer.format.sampleRate)
                * 1_000_000_000).rounded(.up)
        )
        let packet = AudioIngressPacket(
            envelope: AudioPCMEnvelope(
                buffer: buffer,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                observedAtMs: Int64(Date().timeIntervalSince1970 * 1_000)
            ),
            source: source,
            authorizationRevision: authorizationRevision,
            capturedAtUptimeNanoseconds: capturedAt,
            validationDeadlineUptimeNanoseconds:
                capturedAt &+ privacyValidationTimeoutNanoseconds,
            durationNanoseconds: durationNanoseconds
        )
        var shouldStartDrain = false
        var droppedPackets = 0
        ingressLock.lock()
        let queue =
            pendingBySource[source]
            ?? BoundedNewestQueue(capacity: maximumQueueDepth)
        var queuedDuration = queuedDurationBySource[source, default: 0]
        if let dropped = queue.appendReturningDropped(packet) {
            droppedPackets = 1
            queuedDuration =
                queuedDuration >= dropped.durationNanoseconds
                ? queuedDuration - dropped.durationNanoseconds : 0
            droppedPacketCounts[source, default: 0] += 1
        }
        queuedDuration &+= packet.durationNanoseconds
        while queuedDuration > maximumQueuedDurationNanoseconds,
            let dropped = queue.popFirst()
        {
            queuedDuration =
                queuedDuration >= dropped.durationNanoseconds
                ? queuedDuration - dropped.durationNanoseconds : 0
            droppedPackets += 1
            droppedPacketCounts[source, default: 0] += 1
        }
        pendingBySource[source] = queue
        queuedDurationBySource[source] = queuedDuration
        if drainingSources.insert(source).inserted {
            shouldStartDrain = true
        }
        let totalDropped = droppedPacketCounts[source, default: 0]
        ingressLock.unlock()

        if droppedPackets > 0,
            totalDropped == droppedPackets || totalDropped.isMultiple(of: 64)
        {
            audioLog.warning(
                "audio ingress source=\(source.rawValue, privacy: .public) dropped \(totalDropped, privacy: .public) stale packets"
            )
        }
        if shouldStartDrain {
            Task(priority: .utility) { [weak self] in
                await self?.drain(source: source)
            }
        }
    }

    private func drain(source: TranscriptSource) async {
        while !Task.isCancelled {
            guard let packet = dequeue(source: source) else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if packet.validationDeadlineUptimeNanoseconds > now {
                try? await Task.sleep(
                    nanoseconds: packet.validationDeadlineUptimeNanoseconds - now
                )
                guard !Task.isCancelled else { return }
            }
            guard
                authorization.accepts(
                    revision: packet.authorizationRevision,
                    capturedAt: packet.capturedAtUptimeNanoseconds
                )
            else {
                continue
            }
            await deliver(packet)
        }
    }

    private func dequeue(source: TranscriptSource) -> AudioIngressPacket? {
        ingressLock.lock()
        defer { ingressLock.unlock() }
        guard let queue = pendingBySource[source],
            let packet = queue.popFirst()
        else {
            drainingSources.remove(source)
            return nil
        }
        pendingBySource[source] = queue
        let duration = queuedDurationBySource[source, default: 0]
        queuedDurationBySource[source] =
            duration >= packet.durationNanoseconds
            ? duration - packet.durationNanoseconds : 0
        return packet
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
        let sampleDuration = Double(sampleCount) / max(1, format.sampleRate)
        guard sampleCount > 0,
            sampleCount <= Int(Int32.max),
            sampleDuration <= 0.25,
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
        guard !Task.isCancelled else { return }
        let requestedGeneration = UUID()
        generation = requestedGeneration
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
                guard !Task.isCancelled, generation == requestedGeneration else { return }
                try await startStream(
                    sources: availableSources,
                    store: store,
                    locale: locale,
                    exclusions: exclusions,
                    requestedGeneration: requestedGeneration
                )
                guard !Task.isCancelled, generation == requestedGeneration else { return }
                await startPrivacyMonitoring(
                    sources: availableSources,
                    exclusions: exclusions,
                    pauseWhenBrowserAddressUnavailable: pauseWhenBrowserAddressUnavailable,
                    requestedGeneration: requestedGeneration
                )
            }
        } catch is CancellationError {
            return
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

        // Detach this generation before the first suspension. If another
        // apply starts while teardown awaits ScreenCaptureKit, the old stop
        // can only finish the resources it captured here.
        let stoppedStream = stream
        let stoppedOutput = streamOutput
        let stoppedDelegate = streamDelegate
        let stoppedPipeline = pipeline
        stream = nil
        streamOutput = nil
        streamDelegate = nil
        pipeline = nil

        if let stoppedStream {
            try? await stoppedStream.stopCapture()
        }
        if #available(macOS 26.0, *),
            let activePipeline = stoppedPipeline as? AudioTranscriptionPipeline
        {
            await activePipeline.finish()
        }
        withExtendedLifetime((stoppedOutput, stoppedDelegate)) {}
    }

    @available(macOS 26.0, *)
    private func startStream(
        sources: Set<TranscriptSource>,
        store: Store,
        locale: Locale,
        exclusions: ExclusionStore,
        requestedGeneration: UUID
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        try Task.checkCancellation()
        guard generation == requestedGeneration else { throw CancellationError() }
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
        // SpeechTranscriber currently selects 16 kHz mono on Apple silicon.
        // Asking ScreenCaptureKit for that rate avoids a 48-to-16 kHz
        // resample on every continuous audio packet.
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.showsCursor = false

        let authorization = AudioSampleAuthorization()
        let activePipeline = AudioTranscriptionPipeline(
            store: store,
            locale: locale,
            authorization: authorization,
            failureHandler: { [weak self] source, detail in
                Task { @MainActor [weak self] in
                    guard let self,
                        self.generation == requestedGeneration
                    else { return }
                    await self.stop(
                        finalStatus: AudioTranscriptionStatus(
                            phase: .failed,
                            detail: "\(source.label) transcription stopped: \(detail)"
                        )
                    )
                }
            }
        )
        let output = AudioStreamOutput(authorization: authorization) { packet in
            await activePipeline.receive(packet)
        }
        // The privacy context is evaluated only after startCapture succeeds.
        // Keep the output closed until that check completes.
        output.setAcceptsSamples(false)
        let delegate = AudioStreamDelegate { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self,
                    self.generation == requestedGeneration
                else { return }
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
                    qos: .utility
                )
            )
        }
        if sources.contains(.microphone) {
            try stream.addStreamOutput(
                output,
                type: .microphone,
                sampleHandlerQueue: DispatchQueue(
                    label: "dev.screenlog.audio.microphone",
                    qos: .utility
                )
            )
        }
        try await stream.startCapture()
        guard !Task.isCancelled, generation == requestedGeneration else {
            output.setAcceptsSamples(false)
            try? await stream.stopCapture()
            await activePipeline.finish()
            throw CancellationError()
        }
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
        pauseWhenBrowserAddressUnavailable: Bool,
        requestedGeneration: UUID
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
                guard let self,
                    self.generation == requestedGeneration
                else { return }
                // Close the sample gate synchronously with activation, before
                // Accessibility and exclusion checks perform any async work.
                self.setStreamAcceptsSamples(false)
                await self.refreshPrivacyState(
                    sources: sources,
                    exclusions: exclusions,
                    pauseWhenBrowserAddressUnavailable: pauseWhenBrowserAddressUnavailable,
                    requestedGeneration: requestedGeneration
                )
            }
        }

        await refreshPrivacyState(
            sources: sources,
            exclusions: exclusions,
            pauseWhenBrowserAddressUnavailable: pauseWhenBrowserAddressUnavailable,
            requestedGeneration: requestedGeneration
        )
        guard !Task.isCancelled, generation == requestedGeneration else { return }
        privacyTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled,
                    self.generation == requestedGeneration
                else { return }
                await self.refreshPrivacyState(
                    sources: sources,
                    exclusions: exclusions,
                    pauseWhenBrowserAddressUnavailable: pauseWhenBrowserAddressUnavailable,
                    requestedGeneration: requestedGeneration
                )
            }
        }
    }

    @available(macOS 26.0, *)
    private func refreshPrivacyState(
        sources: Set<TranscriptSource>,
        exclusions: ExclusionStore,
        pauseWhenBrowserAddressUnavailable: Bool,
        requestedGeneration: UUID
    ) async {
        guard generation == requestedGeneration else { return }
        privacyEvaluationRevision &+= 1
        let revision = privacyEvaluationRevision
        let desiredFilteredBundleIDs = excludedApplicationBundleIDs(from: exclusions)
        let applicationFilterChanged = desiredFilteredBundleIDs != filteredBundleIDs
        if applicationFilterChanged {
            setStreamAcceptsSamples(false)
            if let activePipeline = pipeline as? AudioTranscriptionPipeline {
                await activePipeline.setAcceptsAudio(
                    false,
                    closeCurrentSegments: true
                )
            }
            guard !Task.isCancelled,
                generation == requestedGeneration,
                revision == privacyEvaluationRevision
            else { return }
        }
        let filterReady = await refreshApplicationFilterIfNeeded(
            exclusions: exclusions,
            requestedGeneration: requestedGeneration,
            privacyRevision: revision
        )
        guard !Task.isCancelled,
            generation == requestedGeneration,
            revision == privacyEvaluationRevision
        else { return }
        // This watermark represents the last packet capture time proven by
        // the observation below. Keep it at the beginning of the observation
        // so packets arriving during Accessibility work must wait for the
        // following poll instead of being validated retroactively.
        let observedThroughUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        let context = await currentPrivacyContext(
            exclusions: exclusions,
            pauseWhenBrowserAddressUnavailable: pauseWhenBrowserAddressUnavailable
        )
        guard !Task.isCancelled,
            generation == requestedGeneration,
            revision == privacyEvaluationRevision
        else { return }
        let contextChanged =
            context != lastPrivacyContext
            || filterReady != applicationFilterIsReady
            || applicationFilterChanged
        lastPrivacyContext = context
        applicationFilterIsReady = filterReady
        let acceptsAudio = captureAvailable && context.isAllowed && filterReady

        if !acceptsAudio || contextChanged { setStreamAcceptsSamples(false) }
        if let activePipeline = pipeline as? AudioTranscriptionPipeline {
            await activePipeline.setAcceptsAudio(
                acceptsAudio,
                closeCurrentSegments: contextChanged
            )
        }
        guard !Task.isCancelled,
            generation == requestedGeneration,
            revision == privacyEvaluationRevision
        else { return }
        if acceptsAudio {
            validateAndAcceptStreamSamples(
                through: observedThroughUptimeNanoseconds
            )
        }

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
        exclusions: ExclusionStore,
        requestedGeneration: UUID,
        privacyRevision: UInt
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
            guard !Task.isCancelled,
                generation == requestedGeneration,
                privacyEvaluationRevision == privacyRevision
            else { return false }
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

    private func validateAndAcceptStreamSamples(through uptimeNanoseconds: UInt64) {
        if #available(macOS 15.0, *) {
            (streamOutput as? AudioStreamOutput)?.validateAndAcceptSamples(
                through: uptimeNanoseconds
            )
        }
    }

    private func currentPrivacyContext(
        exclusions: ExclusionStore,
        pauseWhenBrowserAddressUnavailable: Bool
    ) async -> AudioPrivacyContext {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let bundleID = frontmost?.bundleIdentifier
        var attribution: BrowserURLAttribution?
        if BrowserURLService.isSupportedBrowser(bundleID: bundleID),
            let processIdentifier = frontmost?.processIdentifier
        {
            let browserURL = self.browserURL
            attribution = await Task.detached(priority: .utility) {
                browserURL.browserAttribution(
                    for: NSRunningApplication(processIdentifier: processIdentifier)
                )
            }.value
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
