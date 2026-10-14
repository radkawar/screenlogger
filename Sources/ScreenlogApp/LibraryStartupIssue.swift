import ScreenlogCore

/// Feature-owned presentation for failures that prevent the local Library from
/// opening. Detailed SQLite errors stay in `bootstrap.log`; UI copy remains
/// stable, actionable, and safe for nontechnical users.
enum LibraryStartupIssue: Equatable, Sendable {
    case databaseUnavailable
    case integrityCheckFailed
    case schemaMigrationFailed
    case schemaValidationFailed
    case recoveryFailed
    case unavailable

    init(error: Error) {
        if let startupError = error as? StoreStartupError {
            switch startupError {
            case .databaseUnavailable:
                self = .databaseUnavailable
            case .integrityCheckFailed:
                self = .integrityCheckFailed
            case .schemaMigrationFailed:
                self = .schemaMigrationFailed
            case .schemaValidationFailed:
                self = .schemaValidationFailed
            case .orphanRecoveryFailed:
                self = .recoveryFailed
            }
        } else if error is LibraryDeletionError {
            self = .recoveryFailed
        } else if error is LibraryRestoreError {
            self = .recoveryFailed
        } else {
            self = .unavailable
        }
    }

    var title: String {
        switch self {
        case .integrityCheckFailed, .schemaValidationFailed:
            return "Your Library Needs Attention"
        case .schemaMigrationFailed:
            return "Screenlogger Could Not Update Your Library"
        case .recoveryFailed:
            return "Library Recovery Did Not Finish"
        case .databaseUnavailable, .unavailable:
            return "Your Library Could Not Open"
        }
    }

    var message: String {
        switch self {
        case .databaseUnavailable:
            return "Screenlogger could not open the Library database. Capture is off to protect your saved history."
        case .integrityCheckFailed:
            return
                "Screenlogger found a problem with the Library and stopped before making changes. Your saved files remain on this Mac."
        case .schemaMigrationFailed:
            return "Screenlogger could not safely update the Library. Capture is off. Screenlogger has not replaced your saved files."
        case .schemaValidationFailed:
            return "The Library has inconsistent data. Capture is off to prevent changes to this data."
        case .recoveryFailed:
            return "Screenlogger could not complete Library recovery after an interrupted operation. Capture is off."
        case .unavailable:
            return "Screenlogger could not prepare the Library. Capture is off. Screenlogger saved details for troubleshooting."
        }
    }

    var statusTitle: String { "Library Unavailable" }
}
