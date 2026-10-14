@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Speech

private let transcriptionSessionLog = Logger(
    subsystem: "dev.screenlog",
    category: "audio-transcription-session"
)

struct AudioAnalyzerTimeline {
    private(set) var endTime: CMTime?

    mutating func startTime(
        relativePresentationTime: CMTime,
        frameLength: AVAudioFrameCount,
        sampleRate: Double
    ) -> CMTime {
        let zero = CMTime.zero
        let proposed: CMTime
        if relativePresentationTime.isValid,
            relativePresentationTime.isNumeric,
            CMTimeCompare(relativePresentationTime, zero) >= 0
        {
            proposed = relativePresentationTime
        } else {
            proposed = endTime ?? zero
        }

        let start: CMTime
        if let endTime, CMTimeCompare(proposed, endTime) < 0 {
            start = endTime
        } else {
            start = proposed
        }
        let duration = CMTime(
            value: CMTimeValue(frameLength),
            timescale: CMTimeScale(max(1, Int32(sampleRate.rounded())))
        )
        endTime = CMTimeAdd(start, duration)
        return start
    }

    mutating func reset() {
        endTime = nil
    }
}

enum OnDeviceTranscriptionError: LocalizedError {
    case speechUnavailable
    case unsupportedLocale
    case modelUnavailable
    case incompatibleAudioFormat
    case analyzerClosed

    var errorDescription: String? {
        switch self {
        case .speechUnavailable:
            return "On-device speech recognition is unavailable on this Mac."
        case .unsupportedLocale:
            return "On-device transcription does not support the current language."
        case .modelUnavailable:
            return "Screenlogger could not prepare the on-device speech model."
        case .incompatibleAudioFormat:
            return "Screenlogger cannot transcribe the current audio format."
        case .analyzerClosed:
            return "The on-device speech analyzer stopped accepting audio."
        }
    }
}

@available(macOS 26.0, *)
enum OnDeviceSpeechPreparation {
    static func prepare(
        preferredLocale: Locale = .current,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else {
            throw OnDeviceTranscriptionError.speechUnavailable
        }
        guard
            let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: preferredLocale
            )
        else {
            throw OnDeviceTranscriptionError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        let modules: [any SpeechModule] = [transcriber]
        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            progressHandler(1)
        case .unsupported:
            throw OnDeviceTranscriptionError.modelUnavailable
        case .supported, .downloading:
            guard
                let request = try await AssetInventory.assetInstallationRequest(
                    supporting: modules
                )
            else {
                throw OnDeviceTranscriptionError.modelUnavailable
            }
            let observation = request.progress.observe(\.fractionCompleted) { progress, _ in
                progressHandler(progress.fractionCompleted)
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
            progressHandler(1)
        @unknown default:
            throw OnDeviceTranscriptionError.modelUnavailable
        }
        return locale
    }
}

/// One ephemeral analyzer for either microphone or computer audio. PCM exists
/// only in memory until SpeechAnalyzer consumes it; only finalized text enters
/// the Store.
@available(macOS 26.0, *)
actor OnDeviceTranscriptionSession {
    private struct PendingInput {
        let buffer: AVAudioPCMBuffer
        let presentationTime: CMTime
        let observedAtMs: Int64
    }

    private let source: TranscriptSource
    private let locale: Locale
    private let store: Store
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer

    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var sourceTimeAnchor: CMTime?
    private var wallClockAnchorMs: Int64?
    private var analyzerTimeline = AudioAnalyzerTimeline()
    private var terminalFailureDetail: String?
    private var droppedAnalyzerInputCount = 0
    private var preparationGate = AudioTranscriptionPreparationGate<PendingInput>()

    init(source: TranscriptSource, locale: Locale, store: Store) {
        self.source = source
        self.locale = locale
        self.store = store
        self.transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        self.analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(
                priority: .utility,
                modelRetention: .lingering
            )
        )
    }

    func append(
        _ buffer: AVAudioPCMBuffer,
        presentationTime: CMTime,
        observedAtMs: Int64
    ) async throws {
        if terminalFailureDetail != nil {
            throw OnDeviceTranscriptionError.analyzerClosed
        }
        let input = PendingInput(
            buffer: buffer,
            presentationTime: presentationTime,
            observedAtMs: observedAtMs
        )
        switch preparationGate.enqueue(input) {
        case .queued, .discarded:
            return
        case .process(let readyInput):
            try yieldPrepared(readyInput)
        case .beginPreparation(let token):
            do {
                try await prepareAnalyzer(for: buffer.format)
            } catch {
                guard preparationGate.fail(token: token) else { return }
                resetResources()
                throw error
            }
            guard var pending = preparationGate.complete(token: token) else {
                await analyzer.cancelAndFinishNow()
                resetResources()
                return
            }
            pending.sort {
                CMTimeCompare($0.presentationTime, $1.presentationTime) < 0
            }
            guard let first = pending.first else {
                preparationGate.finish()
                resetResources()
                return
            }
            sourceTimeAnchor = first.presentationTime
            wallClockAnchorMs = first.observedAtMs
            startTasks()
            do {
                for input in pending {
                    try yieldPrepared(input)
                }
            } catch {
                preparationGate.finish()
                throw error
            }
        }
    }

    private func yieldPrepared(_ input: PendingInput) throws {
        guard let inputFormat, inputFormat == input.buffer.format,
            let sourceTimeAnchor
        else {
            throw OnDeviceTranscriptionError.incompatibleAudioFormat
        }
        let relativeTime = CMTimeSubtract(input.presentationTime, sourceTimeAnchor)
        let converted = try convertedBuffers(from: input.buffer)
        for buffer in converted {
            let startTime = analyzerTimeline.startTime(
                relativePresentationTime: relativeTime,
                frameLength: buffer.frameLength,
                sampleRate: buffer.format.sampleRate
            )
            try yieldAnalyzerBuffer(buffer, startTime: startTime)
        }
    }

    private func yieldAnalyzerBuffer(
        _ buffer: AVAudioPCMBuffer,
        startTime: CMTime?
    ) throws {
        guard let inputContinuation else {
            throw OnDeviceTranscriptionError.analyzerClosed
        }
        let result = inputContinuation.yield(
            AnalyzerInput(buffer: buffer, bufferStartTime: startTime)
        )
        switch result {
        case .enqueued:
            break
        case .dropped:
            droppedAnalyzerInputCount += 1
            if droppedAnalyzerInputCount == 1
                || droppedAnalyzerInputCount.isMultiple(of: 64)
            {
                transcriptionSessionLog.warning(
                    "audio analyzer source=\(self.source.rawValue, privacy: .public) dropped \(self.droppedAnalyzerInputCount, privacy: .public) queued inputs"
                )
            }
        case .terminated:
            throw OnDeviceTranscriptionError.analyzerClosed
        @unknown default:
            throw OnDeviceTranscriptionError.analyzerClosed
        }
    }

    func finish() async {
        let previousPhase = preparationGate.finish()
        if previousPhase == .ready {
            do {
                try flushConverterTail()
            } catch {
                transcriptionSessionLog.error(
                    "audio converter flush failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        inputContinuation?.finish()
        inputContinuation = nil
        switch previousPhase {
        case .ready:
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                transcriptionSessionLog.error(
                    "audio analyzer finalization failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        case .idle, .preparing, .finished:
            // Preparation is already in flight inside SpeechAnalyzer. The
            // invalidated gate discards its completion; calling a second
            // analyzer lifecycle method concurrently would recreate the race
            // this state machine is designed to prevent.
            break
        }
        _ = await analysisTask?.result
        _ = await resultTask?.result
        resetResources()
    }

    func cancel() async {
        let previousPhase = preparationGate.finish()
        inputContinuation?.finish()
        inputContinuation = nil
        let stoppedAnalysisTask = analysisTask
        let stoppedResultTask = resultTask
        stoppedAnalysisTask?.cancel()
        stoppedResultTask?.cancel()
        if previousPhase == .ready {
            await analyzer.cancelAndFinishNow()
        }
        _ = await stoppedAnalysisTask?.result
        _ = await stoppedResultTask?.result
        resetResources()
    }

    private func prepareAnalyzer(for naturalFormat: AVAudioFormat) async throws {
        let modules: [any SpeechModule] = [transcriber]
        guard
            let compatibleFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: modules,
                considering: naturalFormat
            )
        else {
            throw OnDeviceTranscriptionError.incompatibleAudioFormat
        }
        let converter: AVAudioConverter?
        if naturalFormat == compatibleFormat {
            converter = nil
        } else {
            guard let audioConverter = AVAudioConverter(from: naturalFormat, to: compatibleFormat)
            else {
                throw OnDeviceTranscriptionError.incompatibleAudioFormat
            }
            audioConverter.primeMethod = .none
            converter = audioConverter
        }
        try await analyzer.prepareToAnalyze(in: compatibleFormat)
        inputFormat = naturalFormat
        outputFormat = compatibleFormat
        self.converter = converter
    }

    private func startTasks() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        inputContinuation = continuation

        analysisTask = Task { [weak self, analyzer] in
            do {
                _ = try await analyzer.analyzeSequence(stream)
            } catch is CancellationError {
            } catch {
                transcriptionSessionLog.error(
                    "audio analyzer input failed: \(error.localizedDescription, privacy: .public)"
                )
                await self?.markTerminalFailure(error.localizedDescription)
            }
        }

        let source = self.source
        let localeIdentifier = locale.identifier
        let wallClockAnchorMs = self.wallClockAnchorMs
        resultTask = Task { [weak self, transcriber, store] in
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    guard result.isFinal else { continue }
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty,
                        let anchorMs = wallClockAnchorMs
                    else { continue }
                    let startSeconds = max(0, result.range.start.seconds)
                    let durationSeconds = max(0, result.range.duration.seconds)
                    let startMs = anchorMs + Int64((startSeconds * 1_000).rounded())
                    let endMs = startMs + Int64((durationSeconds * 1_000).rounded())
                    do {
                        _ = try store.storeTranscript(
                            TranscriptSegmentDraft(
                                startTimestampMs: startMs,
                                endTimestampMs: max(startMs, endMs),
                                source: source,
                                text: text,
                                localeIdentifier: localeIdentifier
                            )
                        )
                    } catch {
                        transcriptionSessionLog.error(
                            "transcript persistence failed for \(source.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            } catch is CancellationError {
            } catch {
                transcriptionSessionLog.error(
                    "audio analyzer results failed for \(source.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                await self?.markTerminalFailure(error.localizedDescription)
            }
        }
    }

    private func markTerminalFailure(_ detail: String) {
        guard preparationGate.phase == .ready else { return }
        terminalFailureDetail = detail
        inputContinuation?.finish()
        inputContinuation = nil
    }

    private func resetResources() {
        inputContinuation = nil
        analysisTask = nil
        resultTask = nil
        converter = nil
        inputFormat = nil
        outputFormat = nil
        sourceTimeAnchor = nil
        wallClockAnchorMs = nil
        analyzerTimeline.reset()
        terminalFailureDetail = nil
        droppedAnalyzerInputCount = 0
    }

    private func convertedBuffers(
        from input: AVAudioPCMBuffer
    ) throws -> [AVAudioPCMBuffer] {
        guard let inputFormat, let outputFormat else { return [] }
        if inputFormat == outputFormat { return [input] }
        guard let converter else { return [] }
        let ratio = outputFormat.sampleRate / max(1, input.format.sampleRate)
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1
        var outputs: [AVAudioPCMBuffer] = []
        var supplied = false
        for _ in 0..<8 {
            guard
                let output = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: max(1, capacity)
                )
            else { return outputs }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) {
                _, inputStatus in
                guard !supplied else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if let conversionError { throw conversionError }
            if output.frameLength > 0 { outputs.append(output) }
            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                return outputs
            case .error:
                throw OnDeviceTranscriptionError.incompatibleAudioFormat
            @unknown default:
                throw OnDeviceTranscriptionError.incompatibleAudioFormat
            }
        }
        return outputs
    }

    private func flushConverterTail() throws {
        guard let converter, let outputFormat else { return }
        let capacity = AVAudioFrameCount(max(1, outputFormat.sampleRate / 10))
        for _ in 0..<8 {
            guard
                let output = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: capacity
                )
            else { return }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) {
                _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let conversionError { throw conversionError }
            if output.frameLength > 0 {
                let startTime = analyzerTimeline.startTime(
                    relativePresentationTime: analyzerTimeline.endTime ?? .zero,
                    frameLength: output.frameLength,
                    sampleRate: output.format.sampleRate
                )
                try yieldAnalyzerBuffer(output, startTime: startTime)
            }
            if status == .endOfStream { return }
            if status == .error {
                throw OnDeviceTranscriptionError.incompatibleAudioFormat
            }
        }
    }
}
