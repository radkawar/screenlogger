import CryptoKit
import Foundation
import MLX
import ScreenlogCore
import Tokenizers

/// One local tokenizer and one reusable model per isolated worker.
actor EmbeddingEncoder {
    private let directory: URL
    private let tokenizer: any Tokenizer
    private var textModel: EmbeddingTextModel?
    private var visionModel: EmbeddingVisionModel?
    private let mediaTokenIDs: Set<Int>
    private let wrappers: [Int]

    init(directory: URL) async throws {
        self.directory = directory
        let tokenizer = try await AutoTokenizer.from(
            modelFolder: directory.appendingPathComponent("text-q8")
        )
        self.tokenizer = tokenizer
        wrappers = tokenizer.encode(text: "", addSpecialTokens: true)
        mediaTokenIDs = Set(
            ["<|image|>", "<|audio|>", "<|video|>"].compactMap {
                let tokens = tokenizer.encode(text: $0, addSpecialTokens: false)
                return tokens.count == 1 ? tokens[0] : nil
            })
        guard wrappers.count == 2 else {
            throw SemanticSearchError.unavailable("The tokenizer has an unsupported document format.")
        }
    }

    func queryVector(_ query: String) throws -> [Float] {
        let tokens = try plainTokens("task: search result | query: " + query)
        guard tokens.count <= SemanticPipeline.textChunkTokens else {
            throw SemanticSearchError.invalidRequest("The query exceeds 512 tokens. Use a shorter query.")
        }
        return try backbone().embed(tokenIDs: tokens)
    }

    func prepareText(title: String?, text: String) throws -> [SemanticPreparedTextChunk] {
        let title = title ?? "none"
        guard title.utf8.count <= 4096 else {
            throw SemanticSearchError.invalidRequest("The document title is too long.")
        }
        let prefix = "title: \(title) | text:"
        let document = try plainTokens(prefix + " " + text)
        if document.count <= SemanticPipeline.textChunkTokens {
            return [SemanticPreparedTextChunk(hash: Self.tokenHash(document), tokenIDs: document)]
        }

        // Keep the separator space with the body. The first chunk then uses
        // the same token boundaries as the complete, titled document.
        let header = Array(try plainTokens(prefix).dropLast())
        guard document.starts(with: header), document.last == wrappers.last else {
            throw SemanticSearchError.invalidRequest("The document cannot be split at a safe token boundary.")
        }
        let capacity = SemanticPipeline.textChunkTokens - header.count - 1
        guard capacity > SemanticPipeline.textChunkOverlap else {
            throw SemanticSearchError.invalidRequest("The document title leaves too little space for text.")
        }
        let body = document[header.count..<(document.count - 1)]
        var result: [SemanticPreparedTextChunk] = []
        var start = body.startIndex
        while start < body.endIndex {
            let end = min(body.endIndex, start + capacity)
            var tokens = header
            tokens.reserveCapacity(header.count + end - start + 1)
            tokens.append(contentsOf: body[start..<end])
            tokens.append(wrappers[1])
            result.append(SemanticPreparedTextChunk(hash: Self.tokenHash(tokens), tokenIDs: tokens))
            guard result.count <= SemanticWorkerLimits.maximumChunks else {
                throw SemanticSearchError.invalidRequest("The document needs too many semantic chunks.")
            }
            if end == body.endIndex { break }
            start = end - SemanticPipeline.textChunkOverlap
        }
        return result
    }

    func textVector(_ chunk: SemanticPreparedTextChunk) throws -> [Float] {
        guard !chunk.tokenIDs.isEmpty,
            chunk.tokenIDs.count <= SemanticPipeline.textChunkTokens,
            chunk.tokenIDs.allSatisfy({ (0..<262_144).contains($0) }),
            chunk.hash == Self.tokenHash(chunk.tokenIDs)
        else {
            throw SemanticSearchError.invalidRequest("The prepared text chunk is invalid.")
        }
        return try backbone().embed(tokenIDs: chunk.tokenIDs)
    }

    func imageVector(rgb: Data, width: Int, height: Int) throws -> [Float] {
        let image = try EmbeddingImageProcessor.prepare(
            rgb: rgb, width: width, height: height,
            maxSoftTokens: SemanticPipeline.imageTokenBudget
        )
        let vision: EmbeddingVisionModel
        if let visionModel {
            vision = visionModel
        } else {
            vision = try EmbeddingVisionModel(directory: directory.appendingPathComponent("vision-q8"))
            visionModel = vision
        }
        // Google processor framing: begin-image, one placeholder per soft
        // feature, end-image. The tokenizer adds the outer BOS/EOS tokens.
        let framed = "<|image>" + String(repeating: "<|image|>", count: image.softTokenCount) + "<image|>"
        let tokens = tokenizer.encode(text: framed, addSpecialTokens: true)
        let model = try backbone()
        guard tokens.filter({ $0 == model.imageTokenID }).count == image.softTokenCount else {
            throw SemanticSearchError.unavailable("The tokenizer has an unsupported image format.")
        }
        return try model.embed(tokenIDs: tokens, imageFeatures: vision.encode(image))
    }

    private func backbone() throws -> EmbeddingTextModel {
        if let textModel { return textModel }
        let model = try EmbeddingTextModel(directory: directory.appendingPathComponent("text-q8"))
        textModel = model
        return model
    }

    private func plainTokens(_ text: String) throws -> [Int] {
        let tokens = tokenizer.encode(text: text, addSpecialTokens: true)
        guard !tokens.isEmpty else {
            throw SemanticSearchError.invalidRequest("The text has no tokens.")
        }
        guard !tokens.contains(where: mediaTokenIDs.contains) else {
            throw SemanticSearchError.invalidRequest("The text contains model media tokens. Use exact search for this text.")
        }
        return tokens
    }

    private nonisolated static func tokenHash(_ tokens: [Int]) -> String {
        var digest = SHA256()
        digest.update(data: Data(SemanticPipeline.identity.utf8))
        for token in tokens {
            var value = UInt32(token).littleEndian
            withUnsafeBytes(of: &value) { digest.update(bufferPointer: $0) }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
