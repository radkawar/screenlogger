/// Semantic presentation for the result of an assistant-integration action.
/// This is intentionally separate from readiness and filesystem inspection:
/// those remain authoritative, while a notice is transient user feedback.
public enum AssistantIntegrationActionNotice: Equatable, Sendable {
    case installed(AssistantIntegrationTarget)
    case verified(AssistantIntegrationTarget)
    case removed(AssistantIntegrationTarget)
    case alreadyRemoved(AssistantIntegrationTarget)
    case inspectionUnavailable(AssistantIntegrationTarget)
    case inspectionAvailableAgain(AssistantIntegrationTarget)
    case inspectionCurrent(AssistantIntegrationTarget)
    case inspectionUnchanged(AssistantIntegrationTarget)
    case failed(AssistantIntegrationActionFailure)

    public var severity: AssistantIntegrationActionNoticeSeverity {
        switch self {
        case .installed, .verified, .removed, .inspectionAvailableAgain, .inspectionCurrent:
            return .success
        case .alreadyRemoved, .inspectionUnchanged:
            return .information
        case .inspectionUnavailable, .failed:
            return .failure
        }
    }

    public var message: String {
        switch self {
        case .installed(let target):
            return "Screenlogger installed the \(target.label) integration files. Restart \(target.label) if it was already open."
        case .verified(let target):
            return "The \(target.label) integration files are current."
        case .removed(let target):
            return "Screenlogger removed the \(target.label) integration."
        case .alreadyRemoved(let target):
            return "The \(target.label) integration is already absent."
        case .inspectionUnavailable(let target):
            return
                "The \(target.label) integration is still unavailable. Reinstall Screenlogger if the problem continues."
        case .inspectionAvailableAgain(let target):
            return "The \(target.label) integration is available again."
        case .inspectionCurrent(let target):
            return "The \(target.label) integration files are current."
        case .inspectionUnchanged:
            return "Screenlogger checked the integration again. It changed no files."
        case .failed(let failure):
            return failure.message
        }
    }
}

public enum AssistantIntegrationActionNoticeSeverity: Equatable, Sendable {
    case success
    case information
    case failure

    public var accessibilityLabel: String {
        switch self {
        case .success:
            return "Assistant integration updated"
        case .information:
            return "Assistant integration information"
        case .failure:
            return "Assistant integration action failed"
        }
    }
}

public enum AssistantIntegrationActionFailure: Equatable, Sendable {
    case resourcesUnavailable
    case configurationUnavailable
    case malformedConfiguration
    case updateRequired
    case destinationConflict
    case unsafeDestination
    case replacementFailed
    case unknown

    public init(_ issue: AssistantIntegrationError) {
        switch issue {
        case .sourceMissing:
            self = .resourcesUnavailable
        case .configMissing:
            self = .configurationUnavailable
        case .malformedConfiguration:
            self = .malformedConfiguration
        case .destinationNeedsUpgrade:
            self = .updateRequired
        case .destinationNotOwned:
            self = .destinationConflict
        case .unsafeDestination:
            self = .unsafeDestination
        case .replacementFailed:
            self = .replacementFailed
        }
    }

    public var message: String {
        switch self {
        case .resourcesUnavailable:
            return "Screenlogger's integration resources are unavailable. Reinstall the app. Try again."
        case .configurationUnavailable:
            return "OpenClaw's configuration is unavailable. Install or open OpenClaw. Try again."
        case .malformedConfiguration:
            return "Screenlogger could not read OpenClaw's integration settings. It left the file unchanged."
        case .updateRequired:
            return "This Screenlogger integration needs an update. Choose Resolve to review the update."
        case .destinationConflict:
            return "Another item is using the integration location. Screenlogger left it unchanged."
        case .unsafeDestination:
            return "Screenlogger refused an unsafe integration location. It changed no files."
        case .replacementFailed:
            return "Screenlogger could not replace the integration. It preserved the previous installation."
        case .unknown:
            return "Screenlogger could not change the integration. It replaced no unrelated files."
        }
    }
}
