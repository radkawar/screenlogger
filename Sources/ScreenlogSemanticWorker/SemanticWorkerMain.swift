import CryptoKit
import Darwin
import Foundation
import MLX
import ScreenlogCore

@main
struct SemanticWorkerMain {
    static func main() async {
        // Every tokenizer and weight load uses an explicit local directory.
        setenv("HF_HUB_OFFLINE", "1", 1)
        setenv("HF_HUB_DISABLE_XET", "1", 1)
        signal(SIGPIPE, SIG_IGN)
        guard CommandLine.arguments.count == 3 else { exit(64) }
        // EOF cannot interrupt a wedged native forward. The retained dispatch
        // source exits this isolated process when its app parent disappears.
        let parentPID = getppid()
        guard parentPID > 1 else { exit(64) }
        let parentExit = DispatchSource.makeProcessSource(
            identifier: parentPID, eventMask: .exit,
            queue: DispatchQueue.global(qos: .userInitiated))
        parentExit.setEventHandler { _exit(0) }
        parentExit.resume()
        defer { parentExit.cancel() }
        guard getppid() == parentPID else { exit(0) }
        Memory.cacheLimit = 64 * 1024 * 1024
        Memory.memoryLimit = min(2 * 1024 * 1024 * 1024, Int(ProcessInfo.processInfo.physicalMemory / 4))
        let runtime = Runtime(
            models: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true),
            inputs: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
        do {
            let reader = SemanticWorkerInput(maximumLineBytes: SemanticWorkerLimits.maximumLineBytes)
            while let line = try reader.next() {
                let request = try JSONDecoder().decode(SemanticWorkerRequest.self, from: line)
                var response: SemanticWorkerResponse
                do {
                    guard request.version == SemanticWorkerLimits.protocolVersion else {
                        throw SemanticSearchError.unavailable("The semantic worker protocol does not match.")
                    }
                    response = try await runtime.perform(request)
                } catch {
                    // Do not send source text, image paths, or third-party diagnostics over IPC.
                    let message =
                        (error as? SemanticSearchError)?.errorDescription
                        ?? "The local semantic model could not process this input."
                    response = SemanticWorkerResponse(id: request.id, error: message)
                }
                var data = try JSONEncoder().encode(response)
                guard data.count < SemanticWorkerLimits.maximumLineBytes else { exit(65) }
                data.append(10)
                try FileHandle.standardOutput.write(contentsOf: data)
            }
        } catch { exit(65) }
    }
}

private actor Runtime {
    let models: URL
    let inputs: URL
    var encoder: EmbeddingEncoder?

    init(models: URL, inputs: URL) {
        self.models = models
        self.inputs = inputs.resolvingSymlinksInPath().standardizedFileURL
    }

    func load() async throws -> EmbeddingEncoder {
        if let encoder { return encoder }
        let loaded = try await EmbeddingEncoder(directory: models)
        encoder = loaded
        return loaded
    }

    func perform(_ request: SemanticWorkerRequest) async throws -> SemanticWorkerResponse {
        switch request.operation {
        case .query:
            let text = try boundedText(request.text)
            let encoder = try await load()
            return SemanticWorkerResponse(id: request.id, vector: try await encoder.queryVector(text))
        case .prepareText:
            let text = try boundedText(request.text)
            let encoder = try await load()
            return SemanticWorkerResponse(id: request.id, chunks: try await encoder.prepareText(title: request.title, text: text))
        case .encodeText:
            guard let chunk = request.chunk else {
                throw SemanticSearchError.invalidRequest("The prepared text chunk is missing.")
            }
            let encoder = try await load()
            return SemanticWorkerResponse(id: request.id, vector: try await encoder.textVector(chunk))
        case .encodeImage:
            guard let path = request.imagePath, let width = request.width, let height = request.height,
                (1...SemanticPipeline.maximumImageSide).contains(width),
                (1...SemanticPipeline.maximumImageSide).contains(height)
            else {
                throw SemanticSearchError.invalidRequest("The prepared image dimensions are invalid.")
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.deletingLastPathComponent() == inputs,
                url.resolvingSymlinksInPath() == url
            else {
                throw SemanticSearchError.invalidRequest("The prepared image is outside the private input directory.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                (attributes[.size] as? NSNumber)?.intValue == width * height * 3
            else {
                throw SemanticSearchError.invalidRequest("The prepared image has an invalid size.")
            }
            let data = try Data(contentsOf: url)
            var digest = SHA256()
            digest.update(data: Data("screenlog-rgb8-srgb-white-v1:\(width)x\(height):".utf8))
            digest.update(data: data)
            guard request.imageHash == digest.finalize().map({ String(format: "%02x", $0) }).joined() else {
                throw SemanticSearchError.invalidRequest("The prepared image changed before inference.")
            }
            let encoder = try await load()
            return SemanticWorkerResponse(id: request.id, vector: try await encoder.imageVector(rgb: data, width: width, height: height))
        }
    }

    private func boundedText(_ text: String?) throws -> String {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            text.utf8.count <= SemanticWorkerLimits.maximumTextBytes
        else {
            throw SemanticSearchError.invalidRequest("Enter nonempty text of at most 128 KiB.")
        }
        return text
    }
}
