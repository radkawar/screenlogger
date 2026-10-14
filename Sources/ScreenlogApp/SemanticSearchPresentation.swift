import CryptoKit
import Foundation
import ScreenlogCore

enum LibrarySearchEngine: String, CaseIterable, Identifiable {
    case exact
    case related
    var id: String { rawValue }
    var label: String { self == .exact ? "Exact" : "Related" }
}

/// Owns admission so queued controls and availability changes use the same rule.
struct LibrarySearchEngineSelection {
    private(set) var engine: LibrarySearchEngine = .exact
    private(set) var relatedAvailable = false
    private(set) var relatedMode: SemanticSearchMode?
    private(set) var availabilityRevision: UInt = 0

    @discardableResult
    mutating func select(_ requested: LibrarySearchEngine, availabilityRevision expectedRevision: UInt? = nil) -> Bool {
        guard
            requested != .related
                || (relatedAvailable && (expectedRevision == nil || expectedRevision == availabilityRevision)),
            engine != requested
        else { return false }
        engine = requested
        return true
    }

    /// Returns true when the active search must be replaced. Keep the observed
    /// source mode with admission: Published sends its new value before the
    /// controller's stored featureStatus changes.
    @discardableResult
    mutating func updateAvailability(_ available: Bool, mode: SemanticSearchMode? = nil) -> Bool {
        let modeChanged = relatedMode != mode
        if relatedAvailable != available || modeChanged { availabilityRevision &+= 1 }
        relatedAvailable = available
        relatedMode = mode
        if !available { return select(.exact) }
        return engine == .related && modeChanged
    }
}

/// Pure rules shared by the controller and native result presentation.
enum SemanticSearchPresentation {
    static func hasSearchDescription(_ parsed: ParsedSearchQuery) -> Bool {
        !parsed.ftsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func allowsContent(_ content: LibrarySearchContent, mode: SemanticSearchMode) -> Bool {
        content != .transcripts || mode.includesText
    }

    static func supportedContent(_ content: LibrarySearchContent, mode: SemanticSearchMode) -> LibrarySearchContent {
        allowsContent(content, mode: mode) ? content : .all
    }

    static func canSearch(status: SemanticFeatureStatus) -> Bool {
        guard status.enabled, status.modelInstalled, status.index.indexedSources > 0 else { return false }
        switch status.phase {
        case .ready, .indexing, .paused:
            return true
        case .disabled, .modelMissing, .downloading, .verifying, .failed, .unsupported:
            return false
        }
    }

    static func queryMode(_ requested: SemanticSearchMode?, enabled: SemanticSearchMode) throws -> SemanticSearchMode {
        let mode = requested ?? enabled
        guard
            (!mode.includesImages || enabled.includesImages)
                && (!mode.includesText || enabled.includesText)
        else {
            throw SemanticSearchError.invalidRequest("The requested sources are not enabled. Change Semantic Search in Settings first.")
        }
        return mode
    }

    static func lowerBound(_ first: Int64?, _ second: Int64?) -> Int64? {
        guard let first else { return second }
        guard let second else { return first }
        return max(first, second)
    }

    static func upperBound(_ first: Int64?, _ second: Int64?) -> Int64? {
        guard let first else { return second }
        guard let second else { return first }
        return min(first, second)
    }

    static func textIdentity(title: String?, text: String) -> String {
        var digest = SHA256()
        for component in [SemanticPipeline.identity, "full-document", title == nil ? "no-title" : "title", title ?? "", text] {
            var length = UInt64(component.utf8.count).littleEndian
            withUnsafeBytes(of: &length) { digest.update(bufferPointer: $0) }
            digest.update(data: Data(component.utf8))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sourceLabel(_ kind: SemanticSourceKind) -> String {
        switch kind {
        case .image: return "Visual match"
        case .screenText: return "Screen text match"
        case .transcript: return "Transcript match"
        }
    }

    static func sourceSymbol(_ kind: SemanticSourceKind) -> String {
        switch kind {
        case .image: return "photo"
        case .screenText: return "text.viewfinder"
        case .transcript: return "waveform"
        }
    }
}
