import Foundation

public enum CLIConnectionFailure: Error, LocalizedError, Equatable, Sendable {
    case libraryUnavailable
    case notListening
    case startFailed

    public var errorDescription: String? {
        switch self {
        case .libraryUnavailable:
            return "The local Library is unavailable. Reopen Screenlogger. Try again."
        case .notListening:
            return "The local connection stopped unexpectedly."
        case .startFailed:
            return "Screenlogger could not start the local command-line connection. Try again or reopen the app."
        }
    }
}

public enum CLIConnectionState: Equatable, Sendable {
    case disabled
    case starting
    case available(socketPath: String)
    case unavailable(CLIConnectionFailure)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var failure: CLIConnectionFailure? {
        if case .unavailable(let failure) = self { return failure }
        return nil
    }
}

public enum CLIInstallFailure: Error, LocalizedError, Equatable, Sendable {
    case artifactsUnavailable
    case artifactsInvalid
    case installationFailed
    case removalFailed
    case installationRecoveryRequired(String)
    case removalRecoveryRequired(String)

    public init(recovery: CLIArtifactRecovery) {
        switch recovery {
        case .installation(let directory):
            self = .installationRecoveryRequired(directory)
        case .removal(let directory):
            self = .removalRecoveryRequired(directory)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .artifactsUnavailable:
            return "Screenlogger could not find a complete screenlog CLI installation."
        case .artifactsInvalid:
            return "Screenlogger could not verify its bundled Terminal command. Reinstall Screenlogger. Try again."
        case .installationFailed:
            return "Screenlogger could not install the screenlog command. It preserved existing command files."
        case .removalFailed:
            return "Screenlogger could not remove the screenlog command. It preserved existing command files."
        case .installationRecoveryRequired(let path):
            return
                "Screenlogger could not fully restore the previous command installation. It kept recovery files at \(path)."
        case .removalRecoveryRequired(let path):
            return
                "Screenlogger could not fully undo command removal. It kept recovery files at \(path)."
        }
    }

    public var recoveryDirectory: String? {
        switch self {
        case .installationRecoveryRequired(let path), .removalRecoveryRequired(let path):
            return path
        case .artifactsUnavailable, .artifactsInvalid, .installationFailed, .removalFailed:
            return nil
        }
    }
}

public enum CLIInstallState: Equatable, Sendable {
    case notInstalled
    case installing
    case removing
    /// The authenticated command matches the copy bundled with this app.
    case ready(path: String)
    /// An authenticated command is intact but older than the bundled copy.
    case updateAvailable(path: String)
    /// An authenticated command exists, but the app bundle cannot provide the
    /// comparison artifacts needed to verify its version.
    case verificationUnavailable(path: String)
    case conflict(CLIArtifactConflict)
    case failed(CLIInstallFailure)

    public init(
        inspection: CLIArtifactInstallationState,
        commandPath: String,
        bundledArtifactsAvailable: Bool
    ) {
        switch inspection {
        case .notInstalled:
            self = .notInstalled
        case .current:
            self = .ready(path: commandPath)
        case .managed:
            self =
                bundledArtifactsAvailable
                ? .updateAvailable(path: commandPath)
                : .verificationUnavailable(path: commandPath)
        case .conflict(let conflict):
            self = .conflict(conflict)
        }
    }

    public var isInstalling: Bool {
        self == .installing
    }

    public var isBusy: Bool {
        self == .installing || self == .removing
    }

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var commandPath: String? {
        switch self {
        case .ready(let path), .updateAvailable(let path), .verificationUnavailable(let path):
            return path
        case .notInstalled, .installing, .removing, .conflict, .failed:
            return nil
        }
    }

    public var canRemove: Bool {
        switch self {
        case .ready, .updateAvailable, .verificationUnavailable:
            return true
        case .notInstalled, .installing, .removing, .conflict, .failed:
            return false
        }
    }

    public var failure: CLIInstallFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

    public var recoveryDirectory: String? {
        failure?.recoveryDirectory
    }

    public var conflict: CLIArtifactConflict? {
        if case .conflict(let conflict) = self { return conflict }
        return nil
    }
}
