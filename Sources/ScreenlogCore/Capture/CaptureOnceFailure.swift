public enum CaptureOnceFailure: Equatable, Sendable {
    case permissionRequired
    case lowDiskSpace
    case excludedContent
    case privateBrowsing
    case browserAddressUnavailable
    case displayUnavailable
    case encodingFailed
    case captureFailed

    /// Reduces operational errors to a payload-free state before they can be
    /// published to the UI. The underlying error remains available to the
    /// caller for local diagnostics.
    public static func classify(
        _ error: Error,
        pauseReason: CapturePauseReason?
    ) -> CaptureOnceFailure {
        guard let captureError = error as? CaptureError else {
            return .captureFailed
        }

        switch captureError {
        case .notAuthorized:
            return .permissionRequired
        case .diskFull:
            return .lowDiskSpace
        case .excluded:
            switch pauseReason {
            case .privateBrowsing:
                return .privateBrowsing
            case .browserAddressUnavailable:
                return .browserAddressUnavailable
            default:
                return .excludedContent
            }
        case .noDisplay:
            return .displayUnavailable
        case .encodeFailed:
            return .encodingFailed
        }
    }

    public var userTitle: String {
        switch self {
        case .permissionRequired: return "Permissions setup required"
        case .lowDiskSpace: return "Not enough free storage"
        case .excludedContent: return "This activity is excluded"
        case .privateBrowsing: return "Private Browsing is excluded"
        case .browserAddressUnavailable: return "Unknown active website"
        case .displayUnavailable: return "No display is available"
        case .encodingFailed: return "Image processing failed"
        case .captureFailed: return "Capture save failed"
        }
    }

    public var userMessage: String {
        switch self {
        case .permissionRequired:
            return "Allow Screen Recording and Accessibility in Permissions & Privacy. Try again."
        case .lowDiskSpace:
            return "Make more storage space available on this Mac. Retry the capture."
        case .excludedContent:
            return "Switch to an application or website without an exclusion. Try again."
        case .privateBrowsing:
            return "Leave the private window or tab. Try again."
        case .browserAddressUnavailable:
            return "Allow Accessibility access, switch away from the browser, or review strict website protection."
        case .displayUnavailable:
            return "Screenlogger could not find a display to capture. Reconnect or wake the display. Try again."
        case .encodingFailed:
            return "Screenlogger could not process this image. Your existing Library remains available. Try again."
        case .captureFailed:
            return "Screenlogger could not save this capture. Your existing Library remains available. Try again."
        }
    }
}
