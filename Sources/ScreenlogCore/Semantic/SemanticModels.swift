import CryptoKit
import Foundation

public enum SemanticSearchMode: String, Codable, CaseIterable, Sendable {
    case images, text, both

    public var label: String {
        switch self {
        case .images: return "Images"
        case .text: return "Text"
        case .both: return "Images and text"
        }
    }

    public var includesImages: Bool { self != .text }
    public var includesText: Bool { self != .images }
}

public enum SemanticSourceKind: String, Codable, Sendable {
    case image, screenText, transcript
}

public enum SemanticSearchPhase: String, Codable, Sendable {
    case disabled, modelMissing, downloading, verifying, ready, indexing, paused, failed, unsupported
}

public enum SemanticIndexingPolicy: String, Codable, Sendable {
    case automatic, manual
}

public struct SemanticIndexStatistics: Codable, Equatable, Sendable {
    public var imageSources: Int
    public var textSources: Int
    public var transcriptSources: Int
    public var pendingSources: Int
    public var indexedSources: Int
    public var failedSources: Int
    public var vectorCount: Int
    public var vectorBytes: Int64

    public init(
        imageSources: Int = 0, textSources: Int = 0, transcriptSources: Int = 0,
        pendingSources: Int = 0, indexedSources: Int = 0, failedSources: Int = 0,
        vectorCount: Int = 0, vectorBytes: Int64 = 0
    ) {
        self.imageSources = imageSources
        self.textSources = textSources
        self.transcriptSources = transcriptSources
        self.pendingSources = pendingSources
        self.indexedSources = indexedSources
        self.failedSources = failedSources
        self.vectorCount = vectorCount
        self.vectorBytes = vectorBytes
    }
}

public struct SemanticFeatureStatus: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var mode: SemanticSearchMode
    public var phase: SemanticSearchPhase
    public var indexingPolicy: SemanticIndexingPolicy
    public var modelInstalled: Bool
    public var downloadedBytes: Int64
    public var downloadBytes: Int64
    public var index: SemanticIndexStatistics
    public var message: String?
    public var pipelineID: String
    public var dimensions: Int

    public init(
        enabled: Bool = false, mode: SemanticSearchMode = .images,
        phase: SemanticSearchPhase = .disabled, indexingPolicy: SemanticIndexingPolicy = .automatic,
        modelInstalled: Bool = false,
        downloadedBytes: Int64 = 0, downloadBytes: Int64 = 0,
        index: SemanticIndexStatistics = .init(), message: String? = nil,
        pipelineID: String = SemanticPipeline.identity, dimensions: Int = SemanticPipeline.dimensions
    ) {
        self.enabled = enabled
        self.mode = mode
        self.phase = phase
        self.indexingPolicy = indexingPolicy
        self.modelInstalled = modelInstalled
        self.downloadedBytes = downloadedBytes
        self.downloadBytes = downloadBytes
        self.index = index
        self.message = message
        self.pipelineID = pipelineID
        self.dimensions = dimensions
    }
}

public struct SemanticSearchRequest: Codable, Sendable {
    public var query: String
    public var mode: SemanticSearchMode?
    public var limit: Int
    public var appFilter: String?
    public var siteFilter: String?
    public var appBundleID: String?
    public var domain: String?
    public var fromTimestampMs: Int64?
    public var toTimestampMs: Int64?
    public var content: LibrarySearchContent

    public init(
        query: String, mode: SemanticSearchMode? = nil, limit: Int = 50,
        appFilter: String? = nil, siteFilter: String? = nil, appBundleID: String? = nil,
        domain: String? = nil, fromTimestampMs: Int64? = nil, toTimestampMs: Int64? = nil,
        content: LibrarySearchContent = .all
    ) {
        self.query = query
        self.mode = mode
        self.limit = limit
        self.appFilter = appFilter
        self.siteFilter = siteFilter
        self.appBundleID = appBundleID
        self.domain = domain
        self.fromTimestampMs = fromTimestampMs
        self.toTimestampMs = toTimestampMs
        self.content = content
    }
}

public struct SemanticSearchHit: Codable, Sendable {
    public var result: FTSResult
    public var kind: SemanticSourceKind
    /// Cosine similarity, not confidence or probability.
    public var score: Double
    public var occurrenceCount: Int

    public init(result: FTSResult, kind: SemanticSourceKind, score: Double, occurrenceCount: Int = 1) {
        self.result = result
        self.kind = kind
        self.score = score
        self.occurrenceCount = occurrenceCount
    }
}

public struct SemanticSearchResponse: Codable, Sendable {
    public var hits: [SemanticSearchHit]
    public var status: SemanticFeatureStatus

    public init(hits: [SemanticSearchHit], status: SemanticFeatureStatus) {
        self.hits = hits
        self.status = status
    }
}

public enum SemanticControlAction: String, Codable, Sendable {
    case downloadModels, enable, disable, pause, resume, indexNow, removeIndex, removeModels
}

public struct SemanticControlRequest: Codable, Sendable {
    public var action: SemanticControlAction
    public var mode: SemanticSearchMode?
    public var enableWhenReady: Bool

    public init(action: SemanticControlAction, mode: SemanticSearchMode? = nil, enableWhenReady: Bool = false) {
        self.action = action
        self.mode = mode
        self.enableWhenReady = enableWhenReady
    }
}

public protocol SemanticToolService: Sendable {
    func status() async -> SemanticFeatureStatus
    func search(_ request: SemanticSearchRequest) async throws -> SemanticSearchResponse
    func control(_ request: SemanticControlRequest) async throws -> SemanticFeatureStatus
}

public enum SemanticSearchError: Error, LocalizedError, Sendable {
    case disabled, modelMissing, indexEmpty
    case unavailable(String)
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case .disabled: return "Semantic search is off."
        case .modelMissing: return "Download the semantic search models first."
        case .indexEmpty: return "The semantic index has no results yet."
        case .unavailable(let message), .invalidRequest(let message): return message
        }
    }
}

public struct SemanticWorkItem: Sendable {
    public var id: Int64
    public var revision: Int64
    public var kind: SemanticSourceKind
    public var frameID: Int64
    public var transcriptID: Int64?
    public var title: String?
    public var text: String?
    public var preview: FramePreviewDescriptor?

    public init(
        id: Int64, revision: Int64, kind: SemanticSourceKind, frameID: Int64,
        transcriptID: Int64? = nil, title: String? = nil, text: String? = nil,
        preview: FramePreviewDescriptor? = nil
    ) {
        self.id = id
        self.revision = revision
        self.kind = kind
        self.frameID = frameID
        self.transcriptID = transcriptID
        self.title = title
        self.text = text
        self.preview = preview
    }
}

public struct SemanticVectorChunk: Codable, Sendable {
    public var hash: String
    public var values: [Float]

    public init(hash: String, values: [Float]) {
        self.hash = hash
        self.values = values
    }
}

/// Every preprocessing or runtime change requires a new identity. The complete
/// manifest is retained beside its digest so index compatibility is inspectable.
public enum SemanticPipeline {
    public static let dimensions = 768
    public static let imageTokenBudget = 280
    public static let maximumImageSide = 2048
    public static let textChunkTokens = 512
    public static let textChunkOverlap = 64
    public static let manifest = """
        screenlogger-semantic-v1
        encoder=screenlogger-owned-v1;reference=transformers@637b76e40bac9398965086863a818f2dd1e7bfd1;pooling=sentence-transformers@af42679b98dee46267af508551b9d8d54ec3b2ab
        mlx=0.32.3;swift-transformers=1.3.0
        model=Nurymanau/EmbeddingGemma-2-MLX-Swift@06b4e075e6b3772e3c29df9f2a2ace7bd4950bdd
        text-q8/model.safetensors=288118885:eb8a067456a3cff750bebadc7b985420444e673508a2da5bcf56e726e52d62c9
        text-q8/config.json=2359:e090bf087c627155c55b481fca9d216461bdaf44d5a980e018ed3deb92fc7664
        text-q8/tokenizer.json=32170510:4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4
        text-q8/tokenizer_config.json=1599:17bd5d6e9364ca49a534e1502076593317c298d4a663623091ed45388f004874
        text-q8/config_sentence_transformers.json=1565:031e56a498d33c349ab489a21885bcfe25b4fcba841149dc99e1e90d4a7c28f5
        text-q8/quantization.json=16288:9de7e788a89f36a07387c9758dd187b596675bfe9e0dbf9e56c3a09f1f410965
        text-q8/manifest.json=379:d9cdb30351293694b7343078970c72b3696eb12034ff06bff2af663fdc3c5cd8
        vision-q8/vision.safetensors=193095171:9b18ee38272989696737fe3a0c4302dfa06f47cc37192b1b8f7583f8447da173
        vision-q8/config.json=3453:6ece510cf4df3d5370011ea0e856486f971dbd8019f5587c6a059977d61571d4
        vision-q8/quantization.json=11258:19c4f4d59a942f0829b4c5b6d8da12e24c5a5306434a22f0705e10ff2ced1186
        vision-q8/manifest.json=380:db92014f981b36cde052bc4759929d343d30b22f7888c623375b50427ffa11a4
        float32-le;l2-normalized;dimensions=768
        image=FrameExtractor.previewCGImage;max-side=2048;opaque-white-sRGB-RGB8;SHA256(UTF8(screenlog-rgb8-srgb-white-v1:{width}x{height}:)+RGB8);image-token-budget=280;canonical-bicubic-antialias-uint8;patch16;pool3;boi-placeholder-eoi
        document=title: {title or none} | text: {text};tokenize-full-once;verify-header-prefix;header=empty-document-format-minus-trailing-separator-space;retain-header-BOS-remove-header-EOS;repeat-header-per-chunk;body-retains-separator-space;append-EOS-per-chunk;tokens=512;body-overlap=64;per-token-projection;fp32-mean-cast-bf16-normalize-fp32-unit
        query=task: search result | query: {text};prefix-once
        """
    public static let identity =
        "screenlogger-semantic-v1:sha256:"
        + SHA256.hash(data: Data(manifest.utf8))
        .map { String(format: "%02x", $0) }.joined()
}
