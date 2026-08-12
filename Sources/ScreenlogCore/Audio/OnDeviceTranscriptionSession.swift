@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Speech

private let transcriptionSessionLog = Logger(
    subsystem: "dev.screenlog",
    category: "audio-transcription-session"
)

enum OnDeviceTranscriptionError: LocalizedError {
    case speechUnavailable
    case unsupportedLocale
    case modelUnavailable
    case incompatibleAudioFormat

    var errorDescription: String? {
        switch self {
        case .speechUnavailable:
            return "On-device speech recognition is unavailable on this Mac."
        case .unsupportedLocale:
            return "The current language is not supported for on-device transcription."
        case .modelUnavailable:
            return "The on-device speech model could not be prepared."
        case .incompatibleAudioFormat:
            return "The current audio format cannot be transcribed."
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
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: false
        )
        let modules: [any SpeechModule] = [transcriber, detector]
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
    private let source: TranscriptSource
    private let locale: Locale
    private let store: Store
    private let transcriber: SpeechTranscriber
    private let detector: SpeechDetector
    private let analyzer: SpeechAnalyzer

    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var sourceTimeAnchor: CMTime?
    private var wallClockAnchorMs: Int64?
    private var isPrepared = false

    init(source: TranscriptSource, locale: Locale, store: Store) {
        self.source = source
        self.locale = locale
        self.store = store
        self.transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        self.detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: false
        )
        self.analyzer = SpeechAnalyzer(modules: [transcriber, detector])
    }

    func append(
        _ buffer: AVAudioPCMBuffer,
        presentationTime: CMTime,
        observedAtMs: Int64
    ) async throws {
        if !isPrepared {
            try await prepare(for: buffer.format)
            sourceTimeAnchor = presentationTime
            wallClockAnchorMs = observedAtMs
        }
        guard let inputFormat, inputFormat == buffer.format,
            let converted = try convertedBuffer(from: buffer),
            let sourceTimeAnchor
        else {
            throw OnDeviceTranscriptionError.incompatibleAudioFormat
        }
        let relativeTime = CMTimeSubtract(presentationTime, sourceTimeAnchor)
        inputContinuation?.yield(
            AnalyzerInput(
                buffer: converted,
                bufferStartTime: relativeTime.isValid ? relativeTime : nil
            )
        )
    }

    func finish() async {
        guard isPrepared else { return }
        inputContinuation?.finish()
        inputContinuation = nil
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            transcriptionSessionLog.error(
                "audio analyzer finalization failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        _ = await analysisTask?.result
        _ = await resultTask?.result
        analysisTask = nil
        resultTask = nil
        converter = nil
        inputFormat = nil
        outputFormat = nil
        isPrepared = false
    }

    func cancel() async {
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer.cancelAndFinishNow()
        analysisTask?.cancel()
        resultTask?.cancel()
        analysisTask = nil
        resultTask = nil
        converter = nil
        inputFormat = nil
        outputFormat = nil
        isPrepared = false
    }

    private func prepare(for naturalFormat: AVAudioFormat) async throws {
        let modules: [any SpeechModule] = [transcriber, detector]
        guard
            let compatibleFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: modules,
                considering: naturalFormat
            )
        else {
            throw OnDeviceTranscriptionError.incompatibleAudioFormat
        }
        guard let converter = AVAudioConverter(from: naturalFormat, to: compatibleFormat) else {
            throw OnDeviceTranscriptionError.incompatibleAudioFormat
        }
        try await analyzer.prepareToAnalyze(in: compatibleFormat)

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = continuation
        inputFormat = naturalFormat
        outputFormat = compatibleFormat
        self.converter = converter
        isPrepared = true

        analysisTask = Task { [analyzer] in
            do {
                try await analyzer.start(inputSequence: stream)
            } catch is CancellationError {
            } catch {
                transcriptionSessionLog.error(
                    "audio analyzer input failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        let source = self.source
        let localeIdentifier = locale.identifier
        resultTask = Task { [transcriber, store] in
            do {
                for try await result in transcriber.results {
                    guard result.isFinal else { continue }
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty,
                        let anchorMs = self.wallClockAnchorMs
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
            }
        }
    }

    private func convertedBuffer(
        from input: AVAudioPCMBuffer
    ) throws -> AVAudioPCMBuffer? {
        guard let converter, let outputFormat else { return nil }
        let ratio = outputFormat.sampleRate / max(1, input.format.sampleRate)
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: max(1, capacity)
            )
        else { return nil }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard status == .haveData || status == .inputRanDry else { return nil }
        return output.frameLength > 0 ? output : nil
    }
}
