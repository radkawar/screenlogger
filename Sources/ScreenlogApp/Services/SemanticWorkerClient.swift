import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ScreenlogCore

struct SemanticPreparedImage: Sendable {
    let hash: String
    fileprivate let url: URL
    let width: Int
    let height: Int
}

actor SemanticWorkerClient {
    private struct Job {
        let request: SemanticWorkerRequest
        let continuation: CheckedContinuation<SemanticWorkerResponse, Error>
    }

    private let modelDirectory: URL
    private let executableURL: URL
    private var inputDirectory: URL?
    private var images: Set<URL> = []
    private var preparations: [UUID: Task<SemanticPreparedImage, Error>] = [:]
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var transport: SemanticWorkerTransport?
    private var pending: [Job] = []
    private var activeID: UUID?
    private var runner: Task<Void, Never>?
    private var stopping = false
    private var generation: UInt64 = 0

    init(modelDirectory: URL, executableURL: URL? = nil) {
        self.modelDirectory = modelDirectory
        self.executableURL =
            executableURL
            ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/screenlog-semantic-worker")
    }

    func queryVector(_ query: String) async throws -> [Float] {
        try vector(await submit(SemanticWorkerRequest(operation: .query, text: query)))
    }

    func prepareText(title: String?, text: String) async throws -> [SemanticPreparedTextChunk] {
        let response = try await submit(SemanticWorkerRequest(operation: .prepareText, text: text, title: title))
        guard let chunks = response.chunks, !chunks.isEmpty,
            chunks.count <= SemanticWorkerLimits.maximumChunks,
            chunks.allSatisfy({ !$0.tokenIDs.isEmpty && $0.tokenIDs.count <= SemanticPipeline.textChunkTokens })
        else {
            throw SemanticSearchError.unavailable("The semantic worker returned invalid text chunks.")
        }
        return chunks
    }

    func encodeTextChunk(_ chunk: SemanticPreparedTextChunk) async throws -> SemanticVectorChunk {
        let response = try await submit(SemanticWorkerRequest(operation: .encodeText, chunk: chunk))
        return SemanticVectorChunk(hash: chunk.hash, values: try vector(response))
    }

    func prepareImage(_ descriptor: FramePreviewDescriptor) async throws -> SemanticPreparedImage {
        try Task.checkCancellation()
        guard !stopping else { throw CancellationError() }
        let epoch = generation
        let directory = try privateInputDirectory()
        let preparationID = UUID()
        guard preparations.count < SemanticWorkerLimits.maximumPendingJobs else {
            throw SemanticSearchError.unavailable("The image preparation queue is full.")
        }
        let preparation = Task.detached(priority: .utility) {
            let cgImage = try await FrameExtractor.previewCGImage(for: descriptor, maxPixelSize: SemanticPipeline.maximumImageSide)
            let width = cgImage.width
            let height = cgImage.height
            guard (1...SemanticPipeline.maximumImageSide).contains(width),
                (1...SemanticPipeline.maximumImageSide).contains(height),
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            else {
                throw SemanticSearchError.unavailable("The source image has invalid dimensions.")
            }
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
                guard
                    let context = CGContext(
                        data: bytes.baseAddress, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
                else { return false }
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { throw SemanticSearchError.unavailable("The source image could not be prepared.") }
            var rgb = Data(count: width * height * 3)
            rgb.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                for pixel in 0..<(width * height) {
                    bytes[pixel * 3] = rgba[pixel * 4]
                    bytes[pixel * 3 + 1] = rgba[pixel * 4 + 1]
                    bytes[pixel * 3 + 2] = rgba[pixel * 4 + 2]
                }
            }
            var digest = SHA256()
            digest.update(data: Data("screenlog-rgb8-srgb-white-v1:\(width)x\(height):".utf8))
            digest.update(data: rgb)
            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            let url = directory.appendingPathComponent(UUID().uuidString + ".rgb")
            guard FileManager.default.createFile(atPath: url.path, contents: rgb, attributes: [.posixPermissions: 0o600]) else {
                throw SemanticSearchError.unavailable("The private image input could not be written.")
            }
            return SemanticPreparedImage(hash: hash, url: url, width: width, height: height)
        }
        preparations[preparationID] = preparation
        defer { preparations.removeValue(forKey: preparationID) }
        let prepared = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
        guard epoch == generation, !stopping, !Task.isCancelled else {
            try? FileManager.default.removeItem(at: prepared.url)
            throw CancellationError()
        }
        images.insert(prepared.url)
        return prepared
    }

    func encodeImage(_ image: SemanticPreparedImage) async throws -> SemanticVectorChunk {
        guard images.contains(image.url) else { throw SemanticSearchError.invalidRequest("The prepared image is no longer available.") }
        let response = try await submit(
            SemanticWorkerRequest(
                operation: .encodeImage, imagePath: image.url.path,
                imageHash: image.hash, width: image.width, height: image.height))
        return SemanticVectorChunk(hash: image.hash, values: try vector(response))
    }

    func discardImage(_ image: SemanticPreparedImage) async {
        if images.remove(image.url) != nil { try? FileManager.default.removeItem(at: image.url) }
    }

    func stop() async {
        if stopping {
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        }
        stopping = true
        generation &+= 1
        let jobs = pending
        pending.removeAll()
        for job in jobs { job.continuation.resume(throwing: CancellationError()) }
        let oldTransport = transport
        transport = nil
        await oldTransport?.stop()
        await runner?.value
        let outstanding = Array(preparations.values)
        for task in outstanding { task.cancel() }
        for task in outstanding {
            if let image = try? await task.value { try? FileManager.default.removeItem(at: image.url) }
        }
        preparations.removeAll()
        runner = nil
        activeID = nil
        for url in images { try? FileManager.default.removeItem(at: url) }
        images.removeAll()
        if let inputDirectory { try? FileManager.default.removeItem(at: inputDirectory) }
        inputDirectory = nil
        stopping = false
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func privateInputDirectory() throws -> URL {
        if let inputDirectory { return inputDirectory }
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("screenlog-semantic-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        inputDirectory = directory
        return directory
    }

    private func submit(_ request: SemanticWorkerRequest) async throws -> SemanticWorkerResponse {
        #if !arch(arm64)
            throw SemanticSearchError.unavailable("Semantic search requires Apple silicon.")
        #else
            try Task.checkCancellation()
            guard !stopping else { throw CancellationError() }
            if let text = request.text, text.utf8.count > SemanticWorkerLimits.maximumTextBytes {
                throw SemanticSearchError.invalidRequest("The semantic input exceeds 128 KiB.")
            }
            guard pending.count < SemanticWorkerLimits.maximumPendingJobs else {
                throw SemanticSearchError.unavailable("The semantic worker queue is full. Try again.")
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let job = Job(request: request, continuation: continuation)
                    if request.operation == .query {
                        let insertion = pending.firstIndex { $0.request.operation != .query } ?? pending.endIndex
                        pending.insert(job, at: insertion)
                    } else {
                        pending.append(job)
                    }
                    if runner == nil { runner = Task { await drain() } }
                }
            } onCancel: {
                Task { await self.cancel(request.id) }
            }
        #endif
    }

    private func cancel(_ id: UUID) async {
        if let index = pending.firstIndex(where: { $0.request.id == id }) {
            pending.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if activeID == id {
            // Native GPU calls do not cooperate with Swift task cancellation.
            await transport?.stop()
        }
    }

    private func drain() async {
        while !pending.isEmpty && !stopping {
            let job = pending.removeFirst()
            activeID = job.request.id
            do {
                if transport == nil {
                    transport = try SemanticWorkerTransport(
                        executable: executableURL, models: modelDirectory,
                        inputs: privateInputDirectory())
                }
                guard let current = transport else { throw CancellationError() }
                let response = try await current.exchange(job.request)
                guard !stopping else { throw CancellationError() }
                if let error = response.error { throw SemanticSearchError.unavailable(error) }
                job.continuation.resume(returning: response)
            } catch {
                let failed = transport
                transport = nil
                await failed?.stop()
                job.continuation.resume(throwing: error)
            }
            activeID = nil
        }
        runner = nil
    }

    private func vector(_ response: SemanticWorkerResponse) throws -> [Float] {
        guard let values = response.vector, values.count == SemanticPipeline.dimensions,
            values.allSatisfy(\.isFinite)
        else {
            throw SemanticSearchError.unavailable("The semantic worker returned an invalid vector.")
        }
        let norm = values.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard abs(norm - 1) < 0.01 else { throw SemanticSearchError.unavailable("The semantic vector is not normalized.") }
        return values
    }
}

/// All pipe waits run on a dedicated GCD queue, never MainActor or a cooperative executor.
private final class SemanticWorkerTransport: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let queue = DispatchQueue(label: "dev.screenlog.semantic.ipc", qos: .userInitiated)
    private let stopLock = NSLock()
    private var killed = false

    init(executable: URL, models: URL, inputs: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SemanticSearchError.unavailable("The semantic worker is not installed in this app.")
        }
        process.executableURL = executable
        process.arguments = [models.path, inputs.path]
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(),
            "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_XET": "1",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        for fd in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        }
    }

    func exchange(_ request: SemanticWorkerRequest) async throws -> SemanticWorkerResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.exchangeBlocking(request)) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.stopLock.lock()
                if !self.killed {
                    self.killed = true
                    if self.process.isRunning { _ = kill(self.process.processIdentifier, SIGKILL) }
                }
                self.stopLock.unlock()
                self.process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    private func exchangeBlocking(_ request: SemanticWorkerRequest) throws -> SemanticWorkerResponse {
        var data = try JSONEncoder().encode(request)
        guard data.count < SemanticWorkerLimits.maximumLineBytes else {
            throw SemanticSearchError.invalidRequest("The semantic request is too large.")
        }
        data.append(10)
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        try data.withUnsafeBytes { pointer in
            var offset = 0
            while offset < pointer.count {
                try ready(input.fileHandleForWriting.fileDescriptor, event: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(
                    input.fileHandleForWriting.fileDescriptor, pointer.baseAddress!.advanced(by: offset), pointer.count - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw workerFailure() }
                offset += count
            }
        }
        var response = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            try ready(output.fileHandleForReading.fileDescriptor, event: Int16(POLLIN), deadline: deadline)
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw workerFailure() }
            response.append(contentsOf: bytes.prefix(count))
            guard response.count <= SemanticWorkerLimits.maximumLineBytes else { throw workerFailure() }
            if let newline = response.firstIndex(of: 10) {
                guard newline == response.index(before: response.endIndex) else { throw workerFailure() }
                let decoded = try JSONDecoder().decode(SemanticWorkerResponse.self, from: response[..<newline])
                guard decoded.id == request.id, decoded.version == SemanticWorkerLimits.protocolVersion else { throw workerFailure() }
                return decoded
            }
        }
    }

    private func ready(_ fd: Int32, event: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw SemanticSearchError.unavailable("The semantic worker exceeded its 120-second deadline.") }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000)))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw workerFailure() }
            if descriptor.revents & event != 0 { return }
            if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw workerFailure() }
        }
    }

    private func workerFailure() -> SemanticSearchError {
        .unavailable("The isolated semantic worker stopped. Resume semantic search to try again.")
    }
}
