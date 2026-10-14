import Foundation
import ScreenlogCore

enum LibraryDeletionOrigin: Sendable, Equatable {
    case timeline
    case storage
    /// Raised from a Library result, so its failures belong on the Library
    /// surface rather than the Timeline the user did not open.
    case library
}

/// Where the outcome of a deletion is reported.
///
/// Settings renders its result in place, so it needs no transient notice. The
/// Timeline and Library windows have no such panel, and a deletion that
/// reported only into a status string no view rendered was indistinguishable
/// from one that silently failed.
enum LibraryDeletionFeedbackSurface: Equatable, Sendable {
    case notice
    case settingsPanel
}

extension LibraryDeletionOrigin {
    var feedbackSurface: LibraryDeletionFeedbackSurface {
        switch self {
        case .timeline, .library: return .notice
        case .storage: return .settingsPanel
        }
    }
}

struct LibraryDeletionRequest: Sendable {
    let selection: LibraryDeletionSelection
    let origin: LibraryDeletionOrigin
    let title: String
    let detail: String
}

struct LibraryDeletionReview: Identifiable, Sendable {
    let origin: LibraryDeletionOrigin
    let title: String
    let detail: String
    let plan: LibraryDeletionPlan
    let captureWasPaused: Bool

    var id: UUID { plan.reviewID }
}

struct LibraryDeletionSuccess: Equatable, Sendable {
    let deletedMomentCount: Int
    let freedBytes: Int64
    let cleanupPending: Bool
}

enum LibraryDeletionIssue: Sendable {
    case preparationFailed(LibraryDeletionRequest)
    case nothingToDelete(LibraryDeletionRequest)
    case reviewExpired(LibraryDeletionRequest)
    case deletionFailed(LibraryDeletionReview)
    case captureCouldNotPause(LibraryDeletionRequest)

    var origin: LibraryDeletionOrigin {
        switch self {
        case .preparationFailed(let request),
            .nothingToDelete(let request),
            .reviewExpired(let request),
            .captureCouldNotPause(let request):
            return request.origin
        case .deletionFailed(let review):
            return review.origin
        }
    }

    var title: String {
        switch self {
        case .preparationFailed: return "Deletion Review Could Not Open"
        case .nothingToDelete: return "Nothing to Delete"
        case .reviewExpired: return "Review This Deletion Again"
        case .deletionFailed: return "History Not Deleted"
        case .captureCouldNotPause: return "Capture Could Not Pause"
        }
    }

    var message: String {
        switch self {
        case .preparationFailed:
            return "Screenlogger could not safely inspect that selection. Screenlogger did not change your history."
        case .nothingToDelete:
            return "There are no saved moments in that selection."
        case .reviewExpired:
            return "The Library changed after your review. Review the current selection before you delete anything."
        case .deletionFailed:
            return "Screenlogger kept your history because it could not safely complete the deletion. Try again or cancel."
        case .captureCouldNotPause:
            return "Screenlogger did not start the review. Capture must pause before Screenlogger can count the affected moments."
        }
    }

    var canRetry: Bool {
        if case .nothingToDelete = self { return false }
        return true
    }
}
