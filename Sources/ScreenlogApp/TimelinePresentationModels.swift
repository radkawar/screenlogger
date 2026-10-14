import Foundation
import ScreenlogCore

/// Why Timeline is currently being presented.
enum TimelineNavigationOrigin: Sendable, Equatable {
    case direct
    case libraryResult
    case librarySession

    /// Library handoffs preserve that window and expose the native Back route.
    var returnsToLibrary: Bool {
        self != .direct
    }
}

/// A recoverable failure owned by the Timeline experience.
///
/// Keeping recovery as data (rather than retaining a UI closure) makes retries
/// predictable even if the selected session or moment changes before the user
/// acts on the banner.
enum TimelineIssue: Equatable, Sendable {
    case refreshSessions
    case refreshTimeline
    case showRecentActivity
    case reloadSession(startMs: Int64, day: Date? = nil, preferLatestMoment: Bool = true)
    case reopenMoment(frameID: Int64, timestampMs: Int64?)

    var title: String {
        switch self {
        case .refreshSessions:
            return "Could not refresh recorded days"
        case .refreshTimeline:
            return "Could not refresh Timeline"
        case .showRecentActivity:
            return "Could not open recent activity"
        case .reloadSession:
            return "Could not open session"
        case .reopenMoment:
            return "Could not open moment"
        }
    }

    var message: String {
        switch self {
        case .refreshSessions:
            return "Screenlogger could not load your recorded days. Try again."
        case .refreshTimeline:
            return "Screenlogger could not load your recent moments. Try again."
        case .showRecentActivity:
            return "Your current session is still open. Try showing recent activity again."
        case .reloadSession:
            return "Screenlogger could not load this session. Try to open it again."
        case .reopenMoment:
            return "Screenlogger could not open this moment. Try to open it again."
        }
    }
}

/// Why the selected Timeline moment cannot currently show captured pixels.
/// Retention is presented separately from a missing row or unreadable file so
/// the recovery action never promises to restore intentionally removed media.
enum TimelinePreviewIssue: Equatable, Sendable {
    case momentMissing
    case mediaUnavailable
    case mediaUnreadable

    var systemImage: String {
        switch self {
        case .momentMissing: "arrow.clockwise.circle"
        case .mediaUnavailable: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .mediaUnreadable: "photo.badge.exclamationmark"
        }
    }

    var title: String {
        switch self {
        case .momentMissing: "Moment Not Found"
        case .mediaUnavailable: "Preview No Longer Stored"
        case .mediaUnreadable: "Could Not Load Preview"
        }
    }

    var message: String {
        switch self {
        case .momentMissing:
            "The Timeline may have changed. Refresh it to find the nearest available moment."
        case .mediaUnavailable:
            "The saved text, app, and time are still available. Screenlogger removed this captured image because of your storage limits."
        case .mediaUnreadable:
            "The saved text, app, and time are still available. Try loading the image again."
        }
    }

    var canRetry: Bool { self != .mediaUnavailable }
}

extension AppModel {
    /// One primary surface at a time: progress, full-page recovery, contextual
    /// empty guidance, or usable Timeline content.
    var timelineContentState: TimelineContentState {
        TimelineContentState.resolve(
            hasFrames: !timeline.isEmpty,
            loadState: timelineLoadState,
            hasTimelineIssue: timelineIssue != nil,
            openedFromLibraryResult: timelineNavigationOrigin == .libraryResult,
            hasSelectedSession: selectedSession != nil
        )
    }
}
