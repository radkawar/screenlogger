import AVFoundation
import Foundation

public enum AudioTranscriptionPhase: String, Sendable, Equatable, Codable {
    case unavailable
    case off
    case permissionRequired
    case preparing
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
