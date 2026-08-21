import Foundation
import ScreenlogCore

/// Framework-neutral inputs for Screenlogger's product-wide capture status.
///
/// AppKit and SwiftUI surfaces consume the resolved presentation instead of
/// independently deciding which of several simultaneous states should win.
struct CaptureStatusInput: Equatable, Sendable {
    enum LibraryState: Equatable, Sendable {
        case ready
        case opening(LibraryStartupIssue?)
        case unavailable(LibraryStartupIssue)
        case restoring
    }

    let library: LibraryState
    let permissions: PermissionsSnapshot
    let isRecording: Bool
    let timedPauseUntil: Date?
    let pauseReason: CapturePauseReason?
    let energySaverReason: CaptureEnergySaverReason?

    /// Transitional mirror of RecordingEngine.pausedForDisk. The resolver
    /// normalizes it into `.lowDiskSpace` so every consumer sees one state.
    let pausedForDisk: Bool
    let captureIssue: CaptureIssue?

    init(
        library: LibraryState,
        permissions: PermissionsSnapshot,
        isRecording: Bool,
        timedPauseUntil: Date?,
        pauseReason: CapturePauseReason?,
        energySaverReason: CaptureEnergySaverReason? = nil,
        pausedForDisk: Bool,
        captureIssue: CaptureIssue?
    ) {
        self.library = library
        self.permissions = permissions
        self.isRecording = isRecording
        self.timedPauseUntil = timedPauseUntil
        self.pauseReason = pauseReason
        self.energySaverReason = energySaverReason
        self.pausedForDisk = pausedForDisk
        self.captureIssue = captureIssue
    }
}

enum CaptureStatusPhase: Equatable, Sendable {
    case openingLibrary
    case libraryUnavailable(LibraryStartupIssue)
    case restoringLibrary
    case setupRequired(resumeAt: Date?)
    case captureFailed(CaptureIssue)
    case timedPause(until: Date)
    case lowDiskSpace
    case websiteAddressUnavailable
    case automaticPause(CapturePauseReason)
    case energySaving(CaptureEnergySaverReason)
    case on
    case off
}

enum CaptureStatusScope: Equatable, Sendable {
    case library
    case capture
}

enum CaptureStatusTone: Equatable, Sendable {
    case success
    case neutral
    case warning
    case working
}

/// A semantic command. View layers decide how to route it and which window
/// owns any temporary setup flow.
enum CaptureStatusPrimaryAction: Equatable, Sendable {
    case retryLibrary
    case setupCapture(ScreenlogPermission)
    case retryCapture(CaptureIssue)
    case resumeCapture
    case startCapture
    case manageStorage
    case reviewWebsiteExclusions
}

/// Where a passive status surface should navigate for additional context.
enum CaptureStatusDestination: Equatable, Sendable {
    case capture
    case setup
    case storage
    case websiteExclusions
    case libraryRecovery
}

struct CaptureStatusControls: Equatable, Sendable {
    let canStop: Bool
    let canSchedulePause: Bool
    let canCaptureOnce: Bool
}

/// Canonical copy and semantics shared by menu-bar, toolbar, and Settings
/// adapters. SF Symbol names remain plain strings; there is no AppKit or
/// SwiftUI dependency in this presentation layer.
struct CaptureStatusPresentation: Equatable, Sendable {
    let phase: CaptureStatusPhase
    let scope: CaptureStatusScope
    let headline: String
    let compactLabel: String
    let detail: String
    let compactDetail: String?
    let symbolName: String
    let tone: CaptureStatusTone
    let primaryAction: CaptureStatusPrimaryAction?
    let actionLabel: String?
    let actionHint: String?
    let inspectionDestination: CaptureStatusDestination
    let controls: CaptureStatusControls
}

/// A deliberately small toolbar contract. Recovery belongs in the owning
/// surface, while the toolbar always preserves the direct capture control.
enum CaptureStatusToolbarAction: Equatable, Sendable {
    case perform(CaptureStatusPrimaryAction)
    case stopCapture
}

struct CaptureStatusToolbarPresentation: Equatable, Sendable {
    let title: String
    let symbolName: String
    let action: CaptureStatusToolbarAction?
    let actionHint: String?
}

enum CaptureStatusToolbarResolver {
    static func resolve(
        _ status: CaptureStatusPresentation
    ) -> CaptureStatusToolbarPresentation {
        if status.controls.canStop {
            return presentation(
                title: "Stop Capture",
                symbolName: "stop.fill",
                action: .stopCapture,
                actionHint: "Stop automatic capture."
            )
        }

        switch status.primaryAction {
        case .startCapture:
            return presentation(
                title: "Start Capture",
                symbolName: "play.fill",
                action: .perform(.startCapture),
                actionHint: "Start automatic capture."
            )
        case .setupCapture(let permission):
            return presentation(
                title: "Set Up \(permission.title)",
                symbolName: "play.fill",
                action: .perform(.setupCapture(permission)),
                actionHint: "Allow \(permission.title), then choose whether capture starts."
            )
        case .resumeCapture:
            return presentation(
                title: "Resume Capture",
                symbolName: "play.fill",
                action: .perform(.resumeCapture),
                actionHint: "Resume automatic capture now."
            )
        case .retryCapture(.startFailed):
            return presentation(
                title: "Start Capture",
                symbolName: "play.fill",
                action: .perform(.retryCapture(.startFailed)),
                actionHint: "Try starting automatic capture again."
            )
        case .retryCapture(.resumeFailed):
            return presentation(
                title: "Resume Capture",
                symbolName: "play.fill",
                action: .perform(.retryCapture(.resumeFailed)),
                actionHint: "Try resuming automatic capture again."
            )
        case .retryLibrary, .retryCapture, .manageStorage,
            .reviewWebsiteExclusions, .none:
            return passivePresentation(for: status.phase)
        }
    }

    private static func passivePresentation(
        for phase: CaptureStatusPhase
    ) -> CaptureStatusToolbarPresentation {
        switch phase {
        case .openingLibrary, .libraryUnavailable, .restoringLibrary:
            return presentation(title: "Capture Unavailable", symbolName: "record.circle")
        case .timedPause, .lowDiskSpace, .websiteAddressUnavailable, .automaticPause:
            return presentation(title: "Capture Paused", symbolName: "pause.fill")
        case .energySaving, .on:
            return presentation(title: "Capture On", symbolName: "record.circle.fill")
        case .setupRequired, .captureFailed, .off:
            return presentation(title: "Capture Off", symbolName: "record.circle")
        }
    }

    private static func presentation(
        title: String,
        symbolName: String,
        action: CaptureStatusToolbarAction? = nil,
        actionHint: String? = nil
    ) -> CaptureStatusToolbarPresentation {
        CaptureStatusToolbarPresentation(
            title: title,
            symbolName: symbolName,
            action: action,
            actionHint: actionHint
        )
    }
}

enum CaptureStatusResolver {
    static func resolve(
        _ input: CaptureStatusInput,
        at now: Date = Date()
    ) -> CaptureStatusPresentation {
        resolve(input, at: now) { date in
            date.formatted(date: .omitted, time: .shortened)
        }
    }

    /// `formatTime` is injectable so tests and non-UI clients do not depend on
    /// the machine's locale while the stored presentation remains Equatable.
    static func resolve(
        _ input: CaptureStatusInput,
        at now: Date,
        formatTime: (Date) -> String
    ) -> CaptureStatusPresentation {
        let activePauseUntil = input.timedPauseUntil.flatMap { $0 > now ? $0 : nil }
        let pauseReason = normalizedPauseReason(input)
        let baseControls = controls(
            for: input,
            activePauseUntil: activePauseUntil,
            pauseReason: pauseReason
        )

        switch input.library {
        case .opening:
            return presentation(
                phase: .openingLibrary,
                scope: .library,
                headline: "Opening Library...",
                compactLabel: "Opening Library...",
                detail: "Screenlogger is trying to open your Library again.",
                compactDetail: "Trying again",
                symbolName: "arrow.clockwise",
                tone: .working,
                primaryAction: nil,
                actionLabel: nil,
                actionHint: nil,
                inspectionDestination: .libraryRecovery,
                controls: baseControls
            )

        case .unavailable(let issue):
            return presentation(
                phase: .libraryUnavailable(issue),
                scope: .library,
                headline: "Library Unavailable",
                compactLabel: "Library Unavailable",
                detail: issue.message,
                compactDetail: "Review Library recovery",
                symbolName: "externaldrive.badge.exclamationmark",
                tone: .warning,
                primaryAction: .retryLibrary,
                actionLabel: "Try Again",
                actionHint: "Try opening your Library again.",
                inspectionDestination: .libraryRecovery,
                controls: baseControls
            )

        case .restoring:
            return presentation(
                phase: .restoringLibrary,
                scope: .library,
                headline: "Restoring Library...",
                compactLabel: "Restoring Library...",
                detail: "Capture will remain off until the Library restore finishes.",
                compactDetail: "Capture is temporarily unavailable",
                symbolName: "arrow.triangle.2.circlepath",
                tone: .working,
                primaryAction: nil,
                actionLabel: nil,
                actionHint: nil,
                inspectionDestination: .libraryRecovery,
                controls: baseControls
            )

        case .ready:
            break
        }

        if !input.permissions.isCaptureReady || pauseReason == .permissionRequired {
            let missingPermission =
                input.permissions.primaryMissingRequiredPermission ?? .screenRecording
            let detail: String
            let compactDetail: String
            if let activePauseUntil {
                let time = formatTime(activePauseUntil)
                detail =
                    "Finish Permissions setup to resume capture. The pause scheduled until \(time) will stay in place."
                compactDetail = "Finish Permissions setup, then capture resumes at \(time)"
            } else {
                detail = permissionSetupDetail(input.permissions)
                compactDetail = "Finish Permissions setup"
            }
            return presentation(
                phase: .setupRequired(resumeAt: activePauseUntil),
                scope: .capture,
                headline: "Capture Needs Setup",
                compactLabel: "Setup Required",
                detail: detail,
                compactDetail: compactDetail,
                symbolName: "exclamationmark.shield",
                tone: .warning,
                primaryAction: .setupCapture(missingPermission),
                actionLabel: "Allow \(missingPermission.title)...",
                actionHint: "Open \(missingPermission.title) setup.",
                inspectionDestination: .setup,
                controls: baseControls
            )
        }

        if let issue = input.captureIssue {
            let action: CaptureStatusPrimaryAction? =
                issue.canRetry ? .retryCapture(issue) : nil
            return presentation(
                phase: .captureFailed(issue),
                scope: .capture,
                headline: issue.title,
                compactLabel: issue.title,
                detail: issue.message,
                compactDetail: "Review Capture settings",
                symbolName: captureIssueSymbol(issue),
                tone: .warning,
                primaryAction: action,
                actionLabel: action == nil ? nil : "Try Again",
                actionHint: action == nil ? nil : "Try the failed capture action again.",
                inspectionDestination: .capture,
                controls: baseControls
            )
        }

        if let activePauseUntil {
            let time = formatTime(activePauseUntil)
            return presentation(
                phase: .timedPause(until: activePauseUntil),
                scope: .capture,
                headline: "Capture Paused",
                compactLabel: "Capture Paused",
                detail: "No new moments are being saved. Capture is scheduled to resume at \(time).",
                compactDetail: "Resumes at \(time)",
                symbolName: "pause.circle.fill",
                tone: .neutral,
                primaryAction: .resumeCapture,
                actionLabel: "Resume Now",
                actionHint: "Resume automatic capture now.",
                inspectionDestination: .capture,
                controls: baseControls
            )
        }

        if pauseReason == .lowDiskSpace {
            return presentation(
                phase: .lowDiskSpace,
                scope: .capture,
                headline: "Capture Paused",
                compactLabel: "Low Disk Space",
                detail: CapturePauseReason.lowDiskSpace.userDescription,
                compactDetail: "Free up storage to resume",
                symbolName: CapturePauseReason.lowDiskSpace.systemImageName,
                tone: .warning,
                primaryAction: .manageStorage,
                actionLabel: "Manage Storage...",
                actionHint: "Open Automatic Storage to free up space.",
                inspectionDestination: .storage,
                controls: baseControls
            )
        }

        if pauseReason == .browserAddressUnavailable {
            return presentation(
                phase: .websiteAddressUnavailable,
                scope: .capture,
                headline: "Capture Paused",
                compactLabel: "Website Address Unavailable",
                detail: CapturePauseReason.browserAddressUnavailable.userDescription,
                compactDetail: "Review website protection",
                symbolName: CapturePauseReason.browserAddressUnavailable.systemImageName,
                tone: .warning,
                primaryAction: .reviewWebsiteExclusions,
                actionLabel: "Review Exclusions...",
                actionHint: "Open Website Exclusions to review website protection.",
                inspectionDestination: .websiteExclusions,
                controls: baseControls
            )
        }

        if let pauseReason {
            return presentation(
                phase: .automaticPause(pauseReason),
                scope: .capture,
                headline: pauseReason.statusTitle,
                compactLabel: automaticPauseCompactLabel(pauseReason),
                detail: pauseReason.userDescription,
                compactDetail: automaticPauseCompactDetail(pauseReason),
                symbolName: pauseReason.systemImageName,
                tone: .neutral,
                primaryAction: nil,
                actionLabel: nil,
                actionHint: nil,
                inspectionDestination: .capture,
                controls: baseControls
            )
        }

        if input.isRecording, let reason = input.energySaverReason {
            return presentation(
                phase: .energySaving(reason),
                scope: .capture,
                headline: reason.statusTitle,
                compactLabel: energySaverCompactLabel(reason),
                detail: reason.userDescription,
                compactDetail: "Capture stays on with reduced energy use",
                symbolName: reason.systemImageName,
                tone: .neutral,
                primaryAction: nil,
                actionLabel: nil,
                actionHint: nil,
                inspectionDestination: .capture,
                controls: baseControls
            )
        }

        if input.isRecording {
            return presentation(
                phase: .on,
                scope: .capture,
                headline: "Capture On",
                compactLabel: "Capture On",
                detail: "Screenlogger is saving searchable moments on this Mac.",
                compactDetail: "Saving moments locally",
                symbolName: "record.circle.fill",
                tone: .success,
                primaryAction: nil,
                actionLabel: nil,
                actionHint: nil,
                inspectionDestination: .capture,
                controls: baseControls
            )
        }

        return presentation(
            phase: .off,
            scope: .capture,
            headline: "Capture Off",
            compactLabel: "Capture Off",
            detail: "No new moments are being saved. Your existing Library remains available.",
            compactDetail: "Review Capture settings",
            symbolName: "record.circle",
            tone: .neutral,
            primaryAction: .startCapture,
            actionLabel: "Start Capture",
            actionHint: "Start automatic capture.",
            inspectionDestination: .capture,
            controls: baseControls
        )
    }

    private static func normalizedPauseReason(_ input: CaptureStatusInput) -> CapturePauseReason? {
        // A permission pause is the harder blocker and must not be hidden by a
        // briefly stale disk mirror during engine publication.
        if input.pauseReason == .permissionRequired {
            return .permissionRequired
        }
        if input.pausedForDisk {
            return .lowDiskSpace
        }
        return input.pauseReason
    }

    private static func controls(
        for input: CaptureStatusInput,
        activePauseUntil: Date?,
        pauseReason: CapturePauseReason?
    ) -> CaptureStatusControls {
        let libraryReady = input.library == .ready
        let captureIsBlocked =
            !libraryReady
            || !input.permissions.isCaptureReady
            || input.captureIssue != nil
        let canSchedulePause =
            !captureIsBlocked
            && input.isRecording
            && activePauseUntil == nil
        let canCaptureOnce =
            !captureIsBlocked
            && activePauseUntil == nil
            && pauseReason == nil
        return CaptureStatusControls(
            // A running engine must always retain an explicit Stop path, even
            // when another state prevents new moments from being saved.
            canStop: input.isRecording,
            canSchedulePause: canSchedulePause,
            canCaptureOnce: canCaptureOnce
        )
    }

    private static func permissionSetupDetail(_ permissions: PermissionsSnapshot) -> String {
        switch permissions.missingRequiredPermissions {
        case [.screenRecording, .accessibility]:
            return "Allow Screen Recording and Accessibility in System Settings before starting capture."
        case [.screenRecording]:
            return "Allow Screen Recording in System Settings before starting capture."
        case [.accessibility]:
            return "Allow Accessibility before starting capture so exclusions and app context are applied completely."
        default:
            return "Review Permissions setup before starting capture."
        }
    }

    private static func captureIssueSymbol(_ issue: CaptureIssue) -> String {
        switch issue {
        case .startFailed, .resumeFailed: return "exclamationmark.circle"
        case .stopFailed, .pauseFailed: return "exclamationmark.triangle"
        case .automaticCaptureFailed: return "camera.badge.ellipsis"
        }
    }

    private static func automaticPauseCompactLabel(_ reason: CapturePauseReason) -> String {
        switch reason {
        case .excludedContent: return "Excluded Activity"
        case .privateBrowsing: return "Private Browsing Protected"
        case .inactivity: return "Waiting for Activity"
        case .permissionRequired: return "Setup Required"
        case .browserAddressUnavailable: return "Website Address Unavailable"
        case .lowDiskSpace: return "Low Disk Space"
        }
    }

    private static func automaticPauseCompactDetail(_ reason: CapturePauseReason) -> String {
        switch reason {
        case .excludedContent: return "Resumes when you switch away"
        case .privateBrowsing: return "Resumes outside the private window"
        case .inactivity: return "Resumes when you return"
        case .permissionRequired: return "Finish Permissions Setup"
        case .browserAddressUnavailable: return "Review website protection"
        case .lowDiskSpace: return "Free up storage to resume"
        }
    }

    private static func energySaverCompactLabel(
        _ reason: CaptureEnergySaverReason
    ) -> String {
        switch reason {
        case .battery: return "Battery Saver"
        case .lowPowerMode: return "Low Power Mode"
        case .thermalPressure: return "Cooling Down"
        }
    }

    private static func presentation(
        phase: CaptureStatusPhase,
        scope: CaptureStatusScope,
        headline: String,
        compactLabel: String,
        detail: String,
        compactDetail: String?,
        symbolName: String,
        tone: CaptureStatusTone,
        primaryAction: CaptureStatusPrimaryAction?,
        actionLabel: String?,
        actionHint: String?,
        inspectionDestination: CaptureStatusDestination,
        controls: CaptureStatusControls
    ) -> CaptureStatusPresentation {
        CaptureStatusPresentation(
            phase: phase,
            scope: scope,
            headline: headline,
            compactLabel: compactLabel,
            detail: detail,
            compactDetail: compactDetail,
            symbolName: symbolName,
            tone: tone,
            primaryAction: primaryAction,
            actionLabel: actionLabel,
            actionHint: actionHint,
            inspectionDestination: inspectionDestination,
            controls: controls
        )
    }
}

/// Interval caption used by the Capture pane. The same string must stay
/// truthful when automatic capture is off or paused.
enum CaptureLocalProcessingCopy {
    static func intervalLabel(_ seconds: Double) -> String {
        if seconds == floor(seconds) {
            return "Every \(Int(seconds)) \(Int(seconds) == 1 ? "second" : "seconds")"
        }
        return String(format: "Every %.1f seconds", seconds)
    }

    static func caption(intervalSeconds: Double, isSaving: Bool) -> String {
        let interval = intervalLabel(intervalSeconds)
        if isSaving {
            return "\(interval), captures and recognized text are saved to the Library on this Mac."
        }
        return
            "When capture is on, Screenlogger saves captures and recognized text to the Library on this Mac \(interval.lowercased())."
    }

    static func isActivelySaving(_ status: CaptureStatusPresentation) -> Bool {
        status.phase == .on
    }
}
