import Foundation

/// Semantic importance for transient feedback owned by the Timeline surface.
///
/// This is intentionally independent from capture and Library health so a
/// moment action cannot overwrite the app's authoritative operating status.
enum TimelineNoticeSeverity: String, Equatable, Sendable {
    case success
    case information
    case warning

    var accessibilityLabel: String {
        switch self {
        case .success:
            return "Success"
        case .information:
            return "Information"
        case .warning:
            return "Warning"
        }
    }
}

enum TimelineNoticeAnnouncementPriority: Equatable, Sendable {
    case low
    case medium
    case high
}

struct TimelineNoticeAnnouncement: Equatable, Sendable {
    let message: String
    let priority: TimelineNoticeAnnouncementPriority
}

/// The result of resolving a requested moment against retained history.
/// Distinguishing nearest/recent substitutions prevents the UI from claiming
/// that it opened media which retention has already removed.
enum TimelineMomentNavigationResolution: Equatable, Sendable {
    case requestedMoment
    case nearestAvailableMoment
    case recentActivity
    case unavailable

    var noticeEvent: TimelineNotice.Event {
        switch self {
        case .requestedMoment:
            return .momentOpened
        case .nearestAvailableMoment:
            return .nearestMomentShown
        case .recentActivity:
            return .recentActivityShownInstead
        case .unavailable:
            return .momentUnavailable
        }
    }
}

/// Truthful outcomes for actions performed on the selected Timeline moment.
/// AppKit APIs report whether pasteboard writes and external opens succeeded;
/// callers should publish the corresponding result rather than assuming them.
enum TimelineMomentActionOutcome: Equatable, Sendable {
    case imageCopied
    case imageUnavailable
    case imageCopyFailed
    case textCopied
    case textUnavailable
    case textCopyFailed
    case sourceOpened(label: String)
    case sourceOpenFailed(label: String?)
    case sourceUnavailable
    case noMomentSelected

    var noticeEvent: TimelineNotice.Event {
        switch self {
        case .imageCopied:
            return .imageCopied
        case .imageUnavailable:
            return .imageUnavailable
        case .imageCopyFailed:
            return .imageCopyFailed
        case .textCopied:
            return .textCopied
        case .textUnavailable:
            return .textUnavailable
        case .textCopyFailed:
            return .textCopyFailed
        case .sourceOpened(let label):
            return .sourceOpened(label: label)
        case .sourceOpenFailed(let label):
            return .sourceOpenFailed(label: label)
        case .sourceUnavailable:
            return .sourceUnavailable
        case .noMomentSelected:
            return .noMomentSelected
        }
    }
}

/// Surface-local, short-lived feedback for Timeline navigation and moment
/// actions. Persistent failures continue to use `TimelineIssue` and its retry
/// affordance; notices describe completed or unavailable operations.
struct TimelineNotice: Identifiable, Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        case recent
        case session
    }

    enum Event: Equatable, Sendable {
        case timelineLoaded(scope: Scope, momentCount: Int)
        case sessionUnavailable
        case dayHasNoCaptures
        case momentOpened
        case nearestMomentShown
        case recentActivityShownInstead
        case momentUnavailable
        case imageCopied
        case imageUnavailable
        case imageCopyFailed
        case textCopied
        case textUnavailable
        case textCopyFailed
        case sourceOpened(label: String)
        case sourceOpenFailed(label: String?)
        case sourceUnavailable
        case noMomentSelected
        case momentsDeleted(count: Int, cleanupPending: Bool)
    }

    let id: UUID
    let event: Event

    init(_ event: Event, id: UUID = UUID()) {
        self.id = id
        self.event = event
    }

    var message: String {
        switch event {
        case .timelineLoaded(.recent, let momentCount):
            if momentCount == 0 { return "No captured moments yet" }
            return "Showing \(momentCount) recent \(Self.momentNoun(momentCount))"
        case .timelineLoaded(.session, let momentCount):
            return "Showing \(momentCount) \(Self.momentNoun(momentCount)) in this session"
        case .sessionUnavailable:
            return "That session is no longer available. Showing recent activity."
        case .dayHasNoCaptures:
            return "No captures were saved on this day"
        case .momentOpened:
            return "Moment opened"
        case .nearestMomentShown:
            return "That moment is no longer available. Showing the nearest saved moment."
        case .recentActivityShownInstead:
            return "That moment is no longer available. Showing recent activity."
        case .momentUnavailable:
            return "That moment is no longer available"
        case .imageCopied:
            return "Image copied"
        case .imageUnavailable:
            return "This moment no longer has an image to copy"
        case .imageCopyFailed:
            return "Could not copy image"
        case .textCopied:
            return "Text copied"
        case .textUnavailable:
            return "This moment has no text to copy"
        case .textCopyFailed:
            return "Could not copy text"
        case .sourceOpened(let label):
            return "Opened \(label)"
        case .sourceOpenFailed(let label):
            if let label, !label.isEmpty { return "Could not open \(label)" }
            return "Could not open the source"
        case .sourceUnavailable:
            return "This moment does not include a source to open"
        case .noMomentSelected:
            return "Select a moment first"
        case .momentsDeleted(let count, let cleanupPending):
            let base = "Deleted \(count) \(Self.momentNoun(count))"
            return cleanupPending ? "\(base) - finishing file cleanup" : base
        }
    }

    var severity: TimelineNoticeSeverity {
        switch event {
        case .timelineLoaded, .dayHasNoCaptures, .imageUnavailable, .textUnavailable,
            .sourceUnavailable, .noMomentSelected:
            return .information
        case .momentOpened, .imageCopied, .textCopied, .sourceOpened, .momentsDeleted:
            return .success
        case .sessionUnavailable, .nearestMomentShown, .recentActivityShownInstead,
            .momentUnavailable, .imageCopyFailed, .textCopyFailed, .sourceOpenFailed:
            return .warning
        }
    }

    /// A bounded lifetime keeps old feedback from describing a new selection.
    /// Warnings remain available longer without becoming persistent error UI.
    var dismissalDelay: TimeInterval {
        switch severity {
        case .success:
            return 3
        case .information:
            return 5
        case .warning:
            return 7
        }
    }

    var accessibilityAnnouncement: TimelineNoticeAnnouncement {
        let priority: TimelineNoticeAnnouncementPriority =
            switch severity {
            case .success:
                .low
            case .information:
                .medium
            case .warning:
                .high
            }
        return TimelineNoticeAnnouncement(message: message, priority: priority)
    }

    private static func momentNoun(_ count: Int) -> String {
        count == 1 ? "moment" : "moments"
    }
}
