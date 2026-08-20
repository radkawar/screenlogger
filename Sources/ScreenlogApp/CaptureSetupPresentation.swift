import Foundation

/// The product surface that initiated the temporary capture setup flow.
///
/// Setup is a detour, not a new workspace. Keeping its origin explicit lets
/// the controller restore a retained window without losing its navigation
/// state, search, filters, or selection.
enum CaptureSetupOrigin: Equatable {
    case library
    case timeline
    case settings
    case settingsGuide
    case direct
    case directFirstRun

    var returnSurfaceName: String {
        switch self {
        case .library: return "Library"
        case .timeline, .direct: return "Timeline"
        case .directFirstRun: return "Library"
        case .settings: return "Settings"
        case .settingsGuide: return "Getting Started"
        }
    }

    var returnsToInitiatingSurface: Bool {
        switch self {
        case .library, .timeline, .settings, .settingsGuide: return true
        case .direct, .directFirstRun: return false
        }
    }
}

/// Shared first-run and return-path copy for Setup's footer.
enum CaptureSetupGuidance {
    static func completionDestination(for origin: CaptureSetupOrigin) -> String {
        if origin.returnsToInitiatingSurface {
            return "Starting capture returns you to \(origin.returnSurfaceName)."
        }
        return "Starting capture opens \(origin.returnSurfaceName)."
    }

    static func missingPermissionFooter(for origin: CaptureSetupOrigin) -> String {
        "Allowing access does not start capture. \(completionDestination(for: origin))"
    }

    static func readyFooter(for origin: CaptureSetupOrigin) -> String {
        "Capture stays off until you choose Start Capture. \(completionDestination(for: origin))"
    }
}
