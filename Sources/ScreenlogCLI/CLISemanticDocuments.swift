import Foundation
import ScreenlogCore

/// An explicit whitelist. Runtime messages can contain private paths and are not exported.
struct CLISemanticStatusDocument: Encodable {
    let schemaVersion = 1
    let enabled: Bool
    let mode: SemanticSearchMode
    let phase: SemanticSearchPhase
    let indexingPolicy: SemanticIndexingPolicy
    let modelInstalled: Bool
    let downloadedBytes: Int64
    let downloadBytes: Int64
    let pipelineID: String
    let dimensions: Int
    let index: SemanticIndexStatistics

    init(_ status: SemanticFeatureStatus) {
        enabled = status.enabled
        mode = status.mode
        phase = status.phase
        indexingPolicy = status.indexingPolicy
        modelInstalled = status.modelInstalled
        downloadedBytes = status.downloadedBytes
        downloadBytes = status.downloadBytes
        pipelineID = status.pipelineID
        dimensions = status.dimensions
        index = status.index
    }
}

struct CLISemanticHitDocument: Encodable {
    let kind: SemanticSourceKind
    let score: Double
    let occurrenceCount: Int
    let result: CLISearchResultDocument

    init(_ hit: SemanticSearchHit) {
        kind = hit.kind
        score = hit.score
        occurrenceCount = hit.occurrenceCount
        result = CLISearchResultDocument(hit.result)
    }
}

struct CLISemanticSearchDocument: Encodable {
    let schemaVersion = 1
    let scoreType = "cosine_similarity"
    let hits: [CLISemanticHitDocument]
    let status: CLISemanticStatusDocument

    init(_ response: SemanticSearchResponse) {
        hits = response.hits.map(CLISemanticHitDocument.init)
        status = CLISemanticStatusDocument(response.status)
    }
}

struct CLISemanticErrorDocument: Encodable {
    struct Failure: Encodable {
        let code: String
        let message: String
    }

    let schemaVersion = 1
    let error: Failure
    let status: CLISemanticStatusDocument?

    init(error: Error, status: SemanticFeatureStatus?) {
        self.status = status.map(CLISemanticStatusDocument.init)
        if let semantic = error as? SemanticSearchError {
            switch semantic {
            case .disabled:
                self.error = Failure(
                    code: "semantic_disabled", message: "Semantic search is disabled. Setup requires explicit user approval.")
            case .modelMissing:
                self.error = Failure(
                    code: "semantic_model_missing",
                    message: "The selected model is not installed. Download requires explicit user approval.")
            case .indexEmpty:
                self.error = Failure(code: "semantic_index_empty", message: "No indexed sources are available. Inspect semantic status.")
            case .unavailable:
                self.error = Failure(
                    code: "semantic_unavailable", message: "Semantic search is unavailable. Inspect semantic status in the app.")
            case .invalidRequest:
                self.error = Failure(
                    code: "semantic_invalid_request",
                    message: "The query or selected source mode is invalid. Inspect semantic status and query help.")
            }
        } else if let client = error as? XPCClientError {
            switch client {
            case .incompatibleProtocol:
                self.error = Failure(
                    code: "incompatible_protocol", message: "Semantic commands require IPC protocol 3. Update the app and CLI together.")
            case .mutationAccessDenied:
                self.error = Failure(
                    code: "capability_denied", message: "Allow capture control and maintenance in Settings > Integrations.")
            case .appNotRunning:
                self.error = Failure(code: "app_unavailable", message: "Open Screenlogger.app and enable local tool access.")
            default:
                self.error = Failure(code: "bridge_unavailable", message: "The local app bridge could not complete the semantic request.")
            }
        } else {
            self.error = Failure(code: "semantic_unavailable", message: "The semantic request could not be completed.")
        }
    }
}
