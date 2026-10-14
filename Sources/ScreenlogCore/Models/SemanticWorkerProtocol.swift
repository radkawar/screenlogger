import Foundation

/// Private, versioned app/helper transport. It does not load the native runtime in Core or the CLI.
public enum SemanticWorkerLimits {
    public static let protocolVersion = 1
    public static let maximumLineBytes = 1_048_576
    public static let maximumTextBytes = 131_072
    public static let maximumChunks = 64
    public static let maximumPendingJobs = 16
}

public struct SemanticPreparedTextChunk: Codable, Sendable {
    public let hash: String
    public let tokenIDs: [Int]

    public init(hash: String, tokenIDs: [Int]) {
        self.hash = hash
        self.tokenIDs = tokenIDs
    }
}

public struct SemanticWorkerRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case query, prepareText, encodeText, encodeImage }
    public var version: Int = SemanticWorkerLimits.protocolVersion
    public let id: UUID
    public let operation: Operation
    public var text: String?
    public var title: String?
    public var chunk: SemanticPreparedTextChunk?
    public var imagePath: String?
    public var imageHash: String?
    public var width: Int?
    public var height: Int?

    public init(
        id: UUID = UUID(), operation: Operation, text: String? = nil, title: String? = nil,
        chunk: SemanticPreparedTextChunk? = nil, imagePath: String? = nil,
        imageHash: String? = nil, width: Int? = nil, height: Int? = nil
    ) {
        self.id = id
        self.operation = operation
        self.text = text
        self.title = title
        self.chunk = chunk
        self.imagePath = imagePath
        self.imageHash = imageHash
        self.width = width
        self.height = height
    }
}

public struct SemanticWorkerResponse: Codable, Sendable {
    public var version: Int = SemanticWorkerLimits.protocolVersion
    public let id: UUID
    public var vector: [Float]?
    public var chunks: [SemanticPreparedTextChunk]?
    public var error: String?

    public init(id: UUID, vector: [Float]? = nil, chunks: [SemanticPreparedTextChunk]? = nil, error: String? = nil) {
        self.id = id
        self.vector = vector
        self.chunks = chunks
        self.error = error
    }
}
