/// Typed presentation boundary for loading the website catalog used by
/// Exclusions. Underlying database errors are logged before crossing this
/// boundary, so the UI receives stable, privacy-safe copy and recovery.
public enum RecordedDomainLoadIssue: CaseIterable, Equatable, Sendable {
    case libraryUnavailable
    case queryFailed

    public var title: String {
        switch self {
        case .libraryUnavailable:
            return "Library unavailable"
        case .queryFailed:
            return "Recently recorded websites unavailable"
        }
    }

    public var message: String {
        switch self {
        case .libraryUnavailable:
            return "The Library is unavailable. Load the list again."
        case .queryFailed:
            return "Screenlogger could not load recently recorded websites. Try again."
        }
    }

    public var recoveryAction: RecordedDomainLoadRecoveryAction {
        .retry
    }
}

public enum RecordedDomainLoadRecoveryAction: Equatable, Sendable {
    case retry

    public var title: String {
        switch self {
        case .retry:
            return "Retry"
        }
    }

    public var accessibilityHint: String {
        switch self {
        case .retry:
            return "Load the recently recorded website list again"
        }
    }
}

public enum RecordedDomainLoadState: Equatable, Sendable {
    case loading
    case loaded
    case failed(RecordedDomainLoadIssue)

    public var issue: RecordedDomainLoadIssue? {
        guard case .failed(let issue) = self else { return nil }
        return issue
    }

    public var isLoading: Bool {
        self == .loading
    }
}
