import ScreenlogCore

enum AudioTranscriptionPermissionPresentation {
    static func shouldReconcile(
        previous: MicrophoneAuthorization,
        current: MicrophoneAuthorization,
        audioEnabled: Bool,
        microphoneEnabled: Bool
    ) -> Bool {
        previous != current && audioEnabled && microphoneEnabled
    }

    static func statusActionTitle(
        phase: AudioTranscriptionPhase,
        microphoneAuthorization: MicrophoneAuthorization
    ) -> String? {
        switch phase {
        case .failed:
            return "Try Again"
        case .permissionRequired:
            switch microphoneAuthorization {
            case .notDetermined:
                return "Allow Microphone"
            case .denied, .restricted:
                return "Open Settings"
            case .authorized:
                return "Try Again"
            }
        default:
            return nil
        }
    }
}
