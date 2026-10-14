import CryptoKit
import Darwin
import Foundation
import ScreenlogCore

public actor SemanticModelManager {
    public nonisolated let directory: URL
    private var installing = false

    private struct ModelFile: Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    private static let baseURL = URL(
        string: "https://huggingface.co/Nurymanau/EmbeddingGemma-2-MLX-Swift/resolve/06b4e075e6b3772e3c29df9f2a2ace7bd4950bdd/")!
    private static let files: [ModelFile] = [
        .init(
            path: "text-q8/model.safetensors", bytes: 288_118_885,
            sha256: "eb8a067456a3cff750bebadc7b985420444e673508a2da5bcf56e726e52d62c9"),
        .init(path: "text-q8/config.json", bytes: 2359, sha256: "e090bf087c627155c55b481fca9d216461bdaf44d5a980e018ed3deb92fc7664"),
        .init(
            path: "text-q8/tokenizer.json", bytes: 32_170_510, sha256: "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4"),
        .init(
            path: "text-q8/tokenizer_config.json", bytes: 1599, sha256: "17bd5d6e9364ca49a534e1502076593317c298d4a663623091ed45388f004874"),
        .init(
            path: "text-q8/config_sentence_transformers.json", bytes: 1565,
            sha256: "031e56a498d33c349ab489a21885bcfe25b4fcba841149dc99e1e90d4a7c28f5"),
        .init(path: "text-q8/quantization.json", bytes: 16288, sha256: "9de7e788a89f36a07387c9758dd187b596675bfe9e0dbf9e56c3a09f1f410965"),
        .init(path: "text-q8/manifest.json", bytes: 379, sha256: "d9cdb30351293694b7343078970c72b3696eb12034ff06bff2af663fdc3c5cd8"),
        .init(
            path: "vision-q8/vision.safetensors", bytes: 193_095_171,
            sha256: "9b18ee38272989696737fe3a0c4302dfa06f47cc37192b1b8f7583f8447da173"),
        .init(path: "vision-q8/config.json", bytes: 3453, sha256: "6ece510cf4df3d5370011ea0e856486f971dbd8019f5587c6a059977d61571d4"),
        .init(
            path: "vision-q8/quantization.json", bytes: 11258, sha256: "19c4f4d59a942f0829b4c5b6d8da12e24c5a5306434a22f0705e10ff2ced1186"),
        .init(path: "vision-q8/manifest.json", bytes: 380, sha256: "db92014f981b36cde052bc4759929d343d30b22f7888c623375b50427ffa11a4"),
    ]

    public init(directory: URL = SemanticModelManager.defaultDirectory()) {
        let normalized = directory.standardizedFileURL
        self.directory = normalized.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(normalized.lastPathComponent, isDirectory: true)
    }

    public nonisolated static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["SCREENLOG_SEMANTIC_MODELS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.screenlog.models", isDirectory: true)
    }

    public nonisolated static func downloadBytes(for mode: SemanticSearchMode) -> Int64 {
        profile(mode).reduce(0) { $0 + $1.bytes }
    }

    public func isInstalled(for mode: SemanticSearchMode) async throws -> Bool {
        // Each readiness check verifies immutable contents, not merely a marker or directory.
        let directory = directory
        let verification = Task.detached(priority: .utility) {
            for file in Self.profile(mode) {
                try Task.checkCancellation()
                if try !Self.verified(file, in: directory) { return false }
            }
            return true
        }
        return try await withTaskCancellationHandler {
            try await verification.value
        } onCancel: {
            verification.cancel()
        }
    }

    public func install(mode: SemanticSearchMode, progress: @escaping @Sendable (Int64, Int64, Bool) -> Void) async throws {
        guard !installing else { throw SemanticSearchError.unavailable("A model download is already in progress.") }
        installing = true
        defer { installing = false }
        try prepareDirectory()
        let lock = try acquireLock()
        defer {
            _ = flock(lock, LOCK_UN)
            close(lock)
        }
        try removeInterruptedStaging()
        let staging = directory.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let total = Self.downloadBytes(for: mode)
        var completed: Int64 = 0
        for file in Self.profile(mode) {
            try Task.checkCancellation()
            let root = directory
            progress(completed, total, true)
            let exists = try await Task.detached(priority: .utility) { try Self.verified(file, in: root) }.value
            if exists {
                completed += file.bytes
                progress(completed, total, false)
                continue
            }
            let target = directory.appendingPathComponent(file.path)
            let parent = target.deletingLastPathComponent()
            try ensurePrivateDirectory(parent)
            let partial = staging.appendingPathComponent(UUID().uuidString)
            let offset = completed
            let download = SemanticModelDownload(destination: partial, expectedBytes: file.bytes) { received in
                progress(offset + received, total, false)
            }
            try await download.fetch(Self.baseURL.appendingPathComponent(file.path))
            try Task.checkCancellation()
            progress(completed + file.bytes, total, true)
            let valid = try await Task.detached(priority: .utility) {
                try Self.verifyURL(partial, bytes: file.bytes, sha256: file.sha256)
            }.value
            guard valid else {
                throw SemanticSearchError.unavailable("A model file failed its size or SHA-256 check. Download the models again.")
            }
            try Task.checkCancellation()
            // Only this process holds the installation lock. A verified complete file is reusable
            // after cancellation; no partially downloaded file can be considered installed.
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: partial, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
            completed += file.bytes
            progress(completed, total, false)
        }
        guard try await isInstalled(for: mode) else {
            throw SemanticSearchError.unavailable("The complete model profile could not be verified.")
        }
        try Task.checkCancellation()
        progress(total, total, false)
    }

    public func removeModels() async throws {
        guard !installing else { throw SemanticSearchError.unavailable("Stop the model download before removing models.") }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try prepareDirectory()
        let lock = try acquireLock()
        defer {
            _ = flock(lock, LOCK_UN)
            close(lock)
        }
        try removeInterruptedStaging()
        // Keep the lock inode and user-supplied override root. Remove only our pinned profiles.
        for profile in ["text-q8", "vision-q8"] {
            let target = directory.appendingPathComponent(profile)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
    }

    private func prepareDirectory() throws {
        try ensurePrivateDirectory(directory)
    }

    /// The caller holds the cross-process lock. Completed files remain in their
    /// pinned profile; only abandoned private staging directories are reclaimed.
    private func removeInterruptedStaging() throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            guard name.hasPrefix(".install-"), UUID(uuidString: String(name.dropFirst(9))) != nil else { continue }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                url.resolvingSymlinksInPath() == url.standardizedFileURL
            else {
                throw SemanticSearchError.unavailable("The model directory must be a private local directory.")
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard url.resolvingSymlinksInPath() == url.standardizedFileURL else {
                throw SemanticSearchError.unavailable("The model directory must not use symbolic links.")
            }
        }
    }

    private func acquireLock() throws -> Int32 {
        let fd = open(directory.appendingPathComponent(".install.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SemanticSearchError.unavailable("The model installation lock could not be opened.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw SemanticSearchError.unavailable("Another process is changing the model files.")
        }
        return fd
    }

    nonisolated private static func profile(_ mode: SemanticSearchMode) -> [ModelFile] {
        mode.includesImages ? files : files.filter { $0.path.hasPrefix("text-q8/") }
    }

    nonisolated private static func verified(_ file: ModelFile, in directory: URL) throws -> Bool {
        let url = directory.appendingPathComponent(file.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return try verifyURL(url, bytes: file.bytes, sha256: file.sha256)
    }

    nonisolated private static func verifyURL(_ url: URL, bytes: Int64, sha256: String) throws -> Bool {
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL else { return false }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.size] as? NSNumber)?.int64Value == bytes
        else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var count: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            count += Int64(data.count)
            guard count <= bytes else { return false }
            digest.update(data: data)
        }
        return count == bytes && digest.finalize().map { String(format: "%02x", $0) }.joined() == sha256
    }
}

/// URLSession streams the large file to disk. Only bounded hash buffers enter app memory.
private final class SemanticModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedBytes: Int64
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var moveError: Error?
    private var moved = false

    init(destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func fetch(_ url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 3600
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: url)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let task = session.downloadTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten <= expectedBytes else {
            downloadTask.cancel()
            return
        }
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                response.url?.scheme == "https"
            else {
                throw SemanticSearchError.unavailable("The model server did not return a complete HTTPS download.")
            }
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            moved = true
        } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        self.session = nil
        let cancelled = self.cancelled
        lock.unlock()
        session.finishTasksAndInvalidate()
        if cancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let error = error ?? moveError {
            continuation?.resume(throwing: error)
        } else if moved {
            continuation?.resume()
        } else {
            continuation?.resume(throwing: SemanticSearchError.unavailable("The model download did not produce a file."))
        }
    }
}
