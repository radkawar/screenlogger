import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

/// Fixed-capacity FIFO that drops the oldest element when a real-time
/// producer outruns its consumer. Storage is reused and dequeue is O(1).
final class BoundedNewestQueue<Element> {
    private var storage: [Element?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = Array(repeating: nil, count: max(1, capacity))
    }

    /// Returns true when the oldest queued element was replaced.
    func append(_ element: Element) -> Bool {
        appendReturningDropped(element) != nil
    }

    /// Returns the replaced element so callers can maintain a byte or time
    /// budget in addition to this queue's fixed item count.
    func appendReturningDropped(_ element: Element) -> Element? {
        if count == storage.count {
            let dropped = storage[head]
            storage[head] = element
            head = (head + 1) % storage.count
            return dropped
        }
        let insertionIndex = (head + count) % storage.count
        storage[insertionIndex] = element
        count += 1
        return nil
    }

    func popFirst() -> Element? {
        guard count > 0 else { return nil }
        let element = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        return element
    }

    func removeAll() {
        storage = Array(repeating: nil, count: storage.count)
        head = 0
        count = 0
    }
}

enum AudioTranscriptionPreparationPhase: Equatable {
    case idle
    case preparing(UUID)
    case ready
    case finished
}

enum AudioTranscriptionEnqueueDecision<Element> {
    case beginPreparation(UUID)
    case queued
    case process(Element)
    case discarded
}

/// A synchronous state machine used before an analyzer crosses its first
/// suspension point. Marking preparation in flight before awaiting prevents
/// actor reentrancy from starting the same analyzer or result stream twice.
struct AudioTranscriptionPreparationGate<Element> {
    private(set) var phase: AudioTranscriptionPreparationPhase = .idle
    private(set) var queuedCount = 0
    private var queued: [Element] = []
    private let maximumQueueDepth: Int

    init(maximumQueueDepth: Int = 64) {
        self.maximumQueueDepth = max(1, maximumQueueDepth)
    }

    mutating func enqueue(_ element: Element) -> AudioTranscriptionEnqueueDecision<Element> {
        switch phase {
        case .idle:
            let token = UUID()
            phase = .preparing(token)
            appendBounded(element)
            return .beginPreparation(token)
        case .preparing:
            appendBounded(element)
            return .queued
        case .ready:
            return .process(element)
        case .finished:
            return .discarded
        }
    }

    mutating func complete(token: UUID) -> [Element]? {
        guard phase == .preparing(token) else { return nil }
        phase = .ready
        let pending = queued
        queued.removeAll(keepingCapacity: false)
        queuedCount = 0
        return pending
    }

    mutating func fail(token: UUID) -> Bool {
        guard phase == .preparing(token) else { return false }
        phase = .finished
        queued.removeAll(keepingCapacity: false)
        queuedCount = 0
        return true
    }

    @discardableResult
    mutating func finish() -> AudioTranscriptionPreparationPhase {
        let previous = phase
        phase = .finished
        queued.removeAll(keepingCapacity: false)
        queuedCount = 0
        return previous
    }

    private mutating func appendBounded(_ element: Element) {
        queued.append(element)
        if queued.count > maximumQueueDepth {
            queued.removeFirst(queued.count - maximumQueueDepth)
        }
        queuedCount = queued.count
    }
}

/// Classifies ScreenCaptureKit failures without matching localized text.
/// Display and WindowServer interruptions are safe to retry; consent and
/// configuration failures require an explicit person-driven action instead.
enum AudioStreamFailureDisposition: Equatable {
    case recoverable
    case requiresAttention

    static func classify(_ error: Error) -> AudioStreamFailureDisposition {
        if let captureError = error as? CaptureError {
            switch captureError {
            case .noDisplay:
                return .recoverable
            case .encodeFailed, .notAuthorized, .diskFull, .excluded:
                return .requiresAttention
            }
        }
        let error = error as NSError
        guard error.domain == SCStreamError.errorDomain,
            let code = SCStreamError.Code(rawValue: error.code)
        else { return .requiresAttention }

        switch code {
        case .systemStoppedStream,
            .noCaptureSource,
            .noDisplayList,
            .noWindowList,
            .failedApplicationConnectionInvalid,
            .failedApplicationConnectionInterrupted,
            .failedNoMatchingApplicationContext,
            .failedToStart,
            .failedToStartAudioCapture,
            .failedToStopAudioCapture,
            .failedToStartMicrophoneCapture,
            .internalError:
            return .recoverable
        default:
            return .requiresAttention
        }
    }
}

/// A finite retry window prevents a permanent framework failure from turning
/// into an expensive model/stream restart loop. A wake event or explicit Retry
/// resets the schedule and starts a fresh recovery window.
struct AudioStreamRecoverySchedule: Equatable {
    static let delays: [TimeInterval] = [0.75, 1.5, 3, 6, 12]

    private(set) var attempt = 0

    mutating func nextDelay() -> TimeInterval? {
        guard attempt < Self.delays.count else { return nil }
        defer { attempt += 1 }
        return Self.delays[attempt]
    }

    mutating func reset() {
        attempt = 0
    }
}

public enum AudioTranscriptionPhase: String, Sendable, Equatable, Codable {
    case unavailable
    case off
    case permissionRequired
    case preparing
    case recovering
    case active
    case privacyPaused
    case capturePaused
    case failed
}

/// A small, stable state object suitable for Settings, the menu bar, and XPC.
public struct AudioTranscriptionStatus: Sendable, Equatable, Codable {
    public var phase: AudioTranscriptionPhase
    public var activeSources: Set<TranscriptSource>
    public var detail: String
    public var preparationProgress: Double?

    public init(
        phase: AudioTranscriptionPhase,
        activeSources: Set<TranscriptSource> = [],
        detail: String,
        preparationProgress: Double? = nil
    ) {
        self.phase = phase
        self.activeSources = activeSources
        self.detail = detail
        self.preparationProgress = preparationProgress
    }

    public static let off = AudioTranscriptionStatus(
        phase: .off,
        detail: "Audio transcription is off."
    )

    public var isConspicuouslyActive: Bool {
        phase == .active && !activeSources.isEmpty
    }
}

public enum AudioTranscriptionSupport {
    public static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    public static var requirementDescription: String {
        "On-device audio transcription requires macOS 26 or later."
    }
}

public enum MicrophoneAuthorization: String, Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized

    public static var current: MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    public static func request() async -> MicrophoneAuthorization {
        guard current == .notDetermined else { return current }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return current
    }
}
