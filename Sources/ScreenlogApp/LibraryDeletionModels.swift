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
        case .preparationFailed: return "Deletion Review Couldn't Open"
        case .nothingToDelete: return "Nothing to Delete"
        case .reviewExpired: return "Review This Deletion Again"
        case .deletionFailed: return "History Wasn't Deleted"
        case .captureCouldNotPause: return "Capture Couldn't Pause"
        }
    }

    var message: String {
        switch self {
        case .preparationFailed:
            return "Screenlogger couldn't safely inspect that selection. Your history was not changed."
        case .nothingToDelete:
            return "There are no saved moments in that selection."
        case .reviewExpired:
            return "The Library changed after you reviewed it. Review the current selection before deleting anything."
        case .deletionFailed:
            return "Screenlogger kept your history because the reviewed deletion couldn't finish safely. You can try again or cancel."
        case .captureCouldNotPause:
            return "Screenlogger didn't start the review because capture must pause before the affected moments can be counted."
        }
    }

    var canRetry: Bool {
        if case .nothingToDelete = self { return false }
        return true
    }
}
