import Foundation

/// Privacy-safe reasons a Library query can be retried locally.
/// Underlying SQLite and filesystem errors never cross this boundary.
enum LibrarySearchIssue: Equatable, Sendable {
    case libraryNotReady
    case queryFailed

    var title: String {
        switch self {
        case .libraryNotReady: return "Library isn't ready"
        case .queryFailed: return "Couldn't search your Library"
        }
    }

    var message: String {
        switch self {
        case .libraryNotReady:
            return "Your saved history is still on this Mac. Wait a moment, then try again."
        case .queryFailed:
            return "Your saved history is still on this Mac. Try the search again."
        }
    }
}

/// Operation state for Library search. Query shape, filters, and result counts
/// remain separate data so cancellation never fabricates an empty result.
enum LibrarySearchState: Equatable, Sendable {
    case idle
    case loading
    case complete
    case failed(LibrarySearchIssue)

    var isLoading: Bool { self == .loading }

    var issue: LibrarySearchIssue? {
        guard case .failed(let issue) = self else { return nil }
        return issue
    }
}

enum LibraryContentMode: String, CaseIterable, Identifiable, Sendable {
    case search
    case sessions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .search: return "Search"
        case .sessions: return "Sessions"
        }
    }
}

/// Durable presentation state for the Library results workspace.
///
/// Query criteria already live on `AppModel`; keeping the remaining navigation
/// state there as well makes a Library -> Timeline -> Library round trip
/// independent of whether AppKit retained or rebuilt the SwiftUI hierarchy.
struct LibraryWorkspaceNavigationState: Equatable, Sendable {
    var selectedResultID: Int64?
    var resultViewportAnchorID: Int64?
    var compactPreviewPresented = false
    var inspectorPanePresented = true
    var contentMode = LibraryContentMode.search
    var selectedSessionStartMs: Int64?

    mutating func selectResult(_ frameID: Int64?) {
        selectedResultID = frameID
        resultViewportAnchorID = frameID
    }

    /// Keep the exact selection when possible. If filtering removes it, choose
    /// the nearest surviving result from the previous ordering instead of
    /// unexpectedly jumping to the first card.
    mutating func reconcileSelection(
        currentResultIDs: [Int64],
        previousResultIDs: [Int64]
    ) {
        guard !currentResultIDs.isEmpty else {
            selectResult(nil)
            return
        }
        if let selectedResultID, currentResultIDs.contains(selectedResultID) {
            resultViewportAnchorID = selectedResultID
            return
        }

        if let selectedResultID,
            let previousIndex = previousResultIDs.firstIndex(of: selectedResultID)
        {
            let visibleIDs = Set(currentResultIDs)
            if let nearest = previousResultIDs.enumerated()
                .filter({ visibleIDs.contains($0.element) })
                .min(by: {
                    abs($0.offset - previousIndex) < abs($1.offset - previousIndex)
                })
            {
                selectResult(nearest.element)
                return
            }
        }

        selectResult(currentResultIDs.first)
    }
}

/// Bounded work and interaction rules for the Library search pipeline.
/// Keyboard input is acknowledged synchronously by setting `.loading`; Store
/// work starts only after the debounce and always runs off MainActor.
enum LibrarySearchInteractionPolicy {
    static let inputAcknowledgementBudgetMilliseconds = 100
    static let debounceNanoseconds: UInt64 = 240_000_000
    static let pageSize = 80

    static func resultsRemainInteractive(
        visibleCount: Int,
        state: LibrarySearchState
    ) -> Bool {
        switch state {
        case .idle, .loading, .complete, .failed:
            return visibleCount > 0
        }
    }
}

/// One publication gate for every asynchronous Library result. Cancellation
/// and generation checks must stay coupled so no superseded page or facet scan
/// can mutate the retained workspace.
enum LibrarySearchPublicationPolicy {
    static func allowsPublication(
        requestGeneration: UInt,
        currentGeneration: UInt,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && requestGeneration == currentGeneration
    }
}

/// Truthful presentation for one bounded Library result page. A page never
/// claims its visible count is the total when SQLite returned a sentinel row.
struct LibrarySearchPagePresentation: Equatable, Sendable {
    static let maximumVisibleResults = 500

    let visibleCount: Int
    let isTruncated: Bool

    var countLabel: String {
        let suffix = isTruncated ? "+" : ""
        let noun = visibleCount == 1 && !isTruncated ? "result" : "results"
        return "\(visibleCount)\(suffix) \(noun)"
    }

    var canLoadMore: Bool {
        isTruncated && visibleCount < Self.maximumVisibleResults
    }

}
