import ScreenlogCore

enum AudioTranscriptionMenuAction: Equatable {
    case toggle
    case openSettings
    case none
}

struct AudioTranscriptionMenuPresentation: Equatable {
    var title: String
    var symbolName: String
    var toolTip: String
    var isEnabled: Bool
    var isChecked: Bool
    var action: AudioTranscriptionMenuAction

    static func resolve(
        isSupported: Bool,
        isEnabled: Bool,
        hasSelectedSources: Bool,
        status: AudioTranscriptionStatus
    ) -> AudioTranscriptionMenuPresentation {
        guard isSupported else {
            return AudioTranscriptionMenuPresentation(
                title: "Audio Transcription Requires macOS 26",
                symbolName: "waveform.slash",
                toolTip: AudioTranscriptionSupport.requirementDescription,
                isEnabled: false,
                isChecked: false,
                action: .none
            )
        }

        guard hasSelectedSources else {
            return AudioTranscriptionMenuPresentation(
                title: "Choose Audio Transcription Sources...",
                symbolName: "waveform.badge.mic",
                toolTip: "Choose Computer Audio, Microphone, or both in Settings.",
                isEnabled: true,
                isChecked: false,
                action: .openSettings
            )
        }

        return AudioTranscriptionMenuPresentation(
            title: title(isEnabled: isEnabled, phase: status.phase),
            symbolName: symbol(isEnabled: isEnabled, phase: status.phase),
            toolTip: isEnabled
                ? status.detail
                : "Transcribe the selected audio sources on this Mac.",
            isEnabled: true,
            isChecked: isEnabled,
            action: .toggle
        )
    }

    private static func title(
        isEnabled: Bool,
        phase: AudioTranscriptionPhase
    ) -> String {
        guard isEnabled else { return "Audio Transcription" }
        switch phase {
        case .preparing: return "Audio Transcription - Preparing..."
        case .recovering: return "Audio Transcription - Reconnecting..."
        case .privacyPaused: return "Audio Transcription - Paused for Privacy"
        case .permissionRequired: return "Audio Transcription - Needs Microphone Access"
        case .failed: return "Audio Transcription - Needs Attention"
        case .capturePaused: return "Audio Transcription - Waiting for Capture"
        case .unavailable: return "Audio Transcription - Unavailable"
        case .active, .off: return "Audio Transcription"
        }
    }

    private static func symbol(
        isEnabled: Bool,
        phase: AudioTranscriptionPhase
    ) -> String {
        guard isEnabled else { return "waveform.circle" }
        switch phase {
        case .active: return "waveform.circle.fill"
        case .privacyPaused: return "lock.circle"
        case .preparing: return "arrow.down.circle"
        case .recovering: return "arrow.triangle.2.circlepath"
        case .permissionRequired, .failed: return "exclamationmark.circle"
        case .capturePaused, .unavailable, .off: return "waveform.circle"
        }
    }
}
