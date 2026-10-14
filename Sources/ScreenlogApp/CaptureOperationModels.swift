import ScreenlogCore

/// Failures owned by automatic capture controls. Expected pauses such as low
/// disk space, permissions, exclusions, and inactivity remain `CapturePauseReason`.
enum CaptureIssue: Equatable, Sendable {
    case startFailed
    case stopFailed
    case pauseFailed
    case resumeFailed
    case automaticCaptureFailed

    var title: String {
        switch self {
        case .startFailed: return "Capture Could Not Start"
        case .stopFailed: return "Capture Could Not Stop"
        case .pauseFailed: return "Capture Could Not Pause"
        case .resumeFailed: return "Capture Could Not Resume"
        case .automaticCaptureFailed: return "Screenlogger Could Not Save a Moment"
        }
    }

    var message: String {
        switch self {
        case .startFailed:
            return "Screenlogger could not start automatic capture. Your existing Library is unchanged."
        case .stopFailed:
            return "Screenlogger could not confirm that automatic capture stopped. Try again before you work with private content."
        case .pauseFailed:
            return "Screenlogger could not pause automatic capture. Screenlogger did not schedule a timed pause."
        case .resumeFailed:
            return "The pause ended, but Screenlogger could not resume automatic capture."
        case .automaticCaptureFailed:
            return "Screenlogger skipped the latest moment and will retry automatically. Your existing Library remains available."
        }
    }

    var canRetry: Bool { self != .automaticCaptureFailed }
}

enum CaptureOnceState: Equatable, Sendable {
    case idle
    case inProgress
    case success(frameID: Int64)
    case failure(CaptureOnceFailure)
}
