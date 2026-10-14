import Foundation

/// An expected, recoverable reason that the capture loop is running without
/// saving a new frame.
///
/// These are deliberately separate from `RecordingEngine.lastError`: privacy
/// exclusions, inactivity, and low storage are useful product states, not
/// capture failures. Keeping their copy here gives every UI surface the same
/// explanation and recovery guidance.
public enum CapturePauseReason: String, CaseIterable, Codable, Sendable, Equatable {
    case permissionRequired
    case excludedContent
    case privateBrowsing
    case browserAddressUnavailable
    case inactivity
    case lowDiskSpace

    /// Compact copy for status badges and menu-bar tooltips.
    public var statusTitle: String {
        switch self {
        case .permissionRequired:
            return "Paused - Permission Required"
        case .excludedContent:
            return "Paused - Excluded Activity"
        case .privateBrowsing:
            return "Paused - Private Browsing"
        case .browserAddressUnavailable:
            return "Paused - Website Unknown"
        case .inactivity:
            return "Paused - Inactive"
        case .lowDiskSpace:
            return "Paused - Low Disk Space"
        }
    }

    /// Plain-language explanation suitable for a settings row or help popover.
    public var userDescription: String {
        switch self {
        case .permissionRequired:
            return "Allow Screen Recording and Accessibility in System Settings to resume capture."
        case .excludedContent:
            return
                "Screenlogger excludes the current application or website. Capture resumes when you switch to another application or website."
        case .privateBrowsing:
            return "Screenlogger excludes Private Browsing. Capture resumes when you leave the private window."
        case .browserAddressUnavailable:
            return
                "Screenlogger could not identify this browser's website. Allow Accessibility access or turn off strict website protection."
        case .inactivity:
            return "Screenlogger detected no keyboard or pointer activity. Capture resumes when you return."
        case .lowDiskSpace:
            return "Make more storage space available on this Mac. Screenlogger resumes automatically when space is available."
        }
    }

    /// SF Symbol shared by AppKit and SwiftUI status surfaces.
    public var systemImageName: String {
        switch self {
        case .permissionRequired:
            return "exclamationmark.shield"
        case .excludedContent:
            return "eye.slash"
        case .privateBrowsing:
            return "hand.raised"
        case .browserAddressUnavailable:
            return "globe.badge.chevron.backward"
        case .inactivity:
            return "moon.zzz"
        case .lowDiskSpace:
            return "externaldrive.badge.exclamationmark"
        }
    }

    /// Permission and storage pauses need user attention. Privacy and idle
    /// pauses are normal, intentional behavior.
    public var needsUserAction: Bool {
        switch self {
        case .permissionRequired, .browserAddressUnavailable, .lowDiskSpace:
            return true
        case .excludedContent, .privateBrowsing, .inactivity:
            return false
        }
    }
}
