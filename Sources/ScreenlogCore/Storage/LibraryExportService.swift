import CryptoKit
import Foundation

public struct LibraryExportManifest: Codable, Equatable, Sendable {
    public struct FileEntry: Codable, Equatable, Sendable {
        public let relativePath: String
        public let sizeBytes: Int64
        public let sha256: String

        public init(relativePath: String, sizeBytes: Int64, sha256: String) {
            self.relativePath = relativePath
            self.sizeBytes = sizeBytes
            self.sha256 = sha256
        }
    }

    public let formatVersion: Int
    public let productIdentifier: String
    public let createdAt: Date
    public let schemaVersion: Int
    public let totalBytes: Int64
    public let files: [FileEntry]

    public init(
        formatVersion: Int,
        productIdentifier: String,
        createdAt: Date,
        schemaVersion: Int,
        totalBytes: Int64,
        files: [FileEntry]
    ) {
        self.formatVersion = formatVersion
        self.productIdentifier = productIdentifier
        self.createdAt = createdAt
        self.schemaVersion = schemaVersion
        self.totalBytes = totalBytes
        self.files = files
    }
}

public struct LibraryExportResult: Equatable, Sendable {
    public let destination: URL
    public let manifest: LibraryExportManifest
}

public enum LibraryBackupIssue: Error, LocalizedError, Equatable, Sendable {
    case missingManifest
    case invalidManifest
    case wrongProduct(String)
    case unsupportedFormat(found: Int, supported: Int)
    case unsafeRelativePath(String)
    case duplicateManifestPath(String)
    case missingFile(String)
    case unexpectedFile(String)
    case unsupportedNode(String)
    case sizeMismatch(String)
    case checksumMismatch(String)
    case databaseInvalid(String)
    case schemaMismatch(manifest: Int, database: Int)

    public var errorDescription: String? {
        switch self {
        case .missingManifest: return "This folder is not a Screenlogger Library export."
        case .invalidManifest: return "The Screenlogger Library manifest is unreadable."
        case .wrongProduct: return "This export belongs to a different application."
        case .unsupportedFormat(let found, let supported):
            return "This export uses format \(found), but this version supports format \(supported)."
        case .unsafeRelativePath(let path): return "The export contains an unsafe path: \(path)"
        case .duplicateManifestPath(let path): return "The export lists \(path) more than once."
        case .missingFile(let path): return "The export is missing \(path)."
        case .unexpectedFile(let path): return "The export contains an unexpected file: \(path)"
        case .unsupportedNode(let path): return "The export contains an unsupported link or file type: \(path)"
        case .sizeMismatch(let path): return "The exported size does not match for \(path)."
        case .checksumMismatch(let path): return "The exported checksum does not match for \(path)."
        case .databaseInvalid: return "The exported Screenlogger database did not pass verification."
        case .schemaMismatch: return "The export manifest and database versions do not match."
        }
    }
}

public enum LibraryRestorePreflight: Equatable, Sendable {
    case ready(LibraryExportManifest)
    case newerSchema(found: Int, supported: Int, manifest: LibraryExportManifest)
    case invalid(LibraryBackupIssue)
}

public enum LibraryExportError: Error, LocalizedError, Equatable, Sendable {
    case sourceUnavailable(String)
    case unsafeDestination(String)
    case destinationExists(String)
    case snapshotFailed(String)
    case verificationFailed(LibraryBackupIssue)
    case publishFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable: return "The Screenlogger Library is unavailable."
        case .unsafeDestination: return "Choose a location outside the live Screenlogger Library."
        case .destinationExists: return "A file or folder already exists at that location. Choose another name."
        case .snapshotFailed: return "Screenlogger could not create a complete Library snapshot. It did not change your current Library."
        case .verificationFailed(let issue): return "Screenlogger could not verify the Library export. \(issue.localizedDescription)"
        case .publishFailed: return "Screenlogger could not finish saving the verified Library export."
        }
    }
}

public enum LibraryExportOperationState: Equatable, Sendable {
    case idle
    case exporting
    case completed(URL)
    case failed(LibraryExportError)

    public var isExporting: Bool { self == .exporting }
}

/// Creates portable, verified directory exports without modifying the live Store.
/// Restore activation is intentionally separate: preflight performs complete archive
/// validation, but does not swap databases or rewrite media paths.
public final class LibraryExportService: @unchecked Sendable {
    public static let formatVersion = 1
    public static let productIdentifier = "dev.screenlog.library-export"
    public static let manifestName = "manifest.json"
    public static let libraryDirectoryName = "Library"
    public static let preferredExtension = "screenloggerbackup"

    private static let maximumManifestBytes = 128 * 1_024 * 1_024
    private static let maximumFileCount = 2_000_000
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let didAcquireSnapshotLock: (@Sendable () -> Void)?

    public init() {
        self.fileManager = .default
        self.now = { Date() }
        self.didAcquireSnapshotLock = nil
    }

    init(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        didAcquireSnapshotLock: (@Sendable () -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.now = now
        self.didAcquireSnapshotLock = didAcquireSnapshotLock
    }

    @discardableResult
    public func export(store: Store, to requestedDestination: URL) throws -> LibraryExportResult {
        let destination = try validatedDestination(requestedDestination, liveRoot: store.root)
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).exporting-\(UUID().uuidString)",
            isDirectory: true
        )
        guard !nodeExists(staging) else {
            throw LibraryExportError.destinationExists(staging.path)
        }
        defer { if nodeExists(staging) { try? fileManager.removeItem(at: staging) } }

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            let stagedLibrary = staging.appendingPathComponent(Self.libraryDirectoryName, isDirectory: true)
            try fileManager.createDirectory(at: stagedLibrary, withIntermediateDirectories: false)

            try store.withSerializedMutation {
                didAcquireSnapshotLock?()
                try store.db.backup(to: stagedLibrary.appendingPathComponent("db.sqlite3"))
                try copyManagedDirectory(
                    from: ScreenlogPaths.framesDirectory(root: store.root),
                    to: stagedLibrary.appendingPathComponent("frames", isDirectory: true)
                )
                try copyManagedDirectory(
                    from: ScreenlogPaths.videosDirectory(root: store.root),
                    to: stagedLibrary.appendingPathComponent("videos", isDirectory: true)
                )
            }

            let entries = try fileEntries(in: stagedLibrary, archiveRoot: staging)
            let totalBytes = try entries.reduce(Int64(0)) { total, entry in
                let next = total.addingReportingOverflow(entry.sizeBytes)
                guard !next.overflow else { throw LibraryExportError.snapshotFailed("export size overflow") }
                return next.partialValue
            }
            let manifest = LibraryExportManifest(
                formatVersion: Self.formatVersion,
                productIdentifier: Self.productIdentifier,
                createdAt: now(),
                schemaVersion: Schema.currentVersion,
                totalBytes: totalBytes,
                files: entries
            )
            try Self.manifestEncoder.encode(manifest).write(
                to: staging.appendingPathComponent(Self.manifestName),
                options: .atomic
            )

            let verifiedManifest: LibraryExportManifest
            switch preflightRestore(at: staging) {
            case .ready(let verified):
                verifiedManifest = verified
            case .invalid(let issue):
                throw LibraryExportError.verificationFailed(issue)
            case .newerSchema(let found, let supported, _):
                throw LibraryExportError.verificationFailed(
                    .databaseInvalid("schema \(found) is newer than \(supported)")
                )
            }

            do {
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                throw LibraryExportError.publishFailed(error.localizedDescription)
            }
            return LibraryExportResult(destination: destination, manifest: verifiedManifest)
        } catch let error as LibraryExportError {
            throw error
        } catch {
            throw LibraryExportError.snapshotFailed(error.localizedDescription)
        }
    }

    public func preflightRestore(at archive: URL) -> LibraryRestorePreflight {
        do {
            guard isDirectory(archive), !isSymbolicLink(archive) else {
                return .invalid(.missingManifest)
            }
            let manifestURL = archive.appendingPathComponent(Self.manifestName)
            guard isRegularFile(manifestURL), !isSymbolicLink(manifestURL) else {
                return .invalid(.missingManifest)
            }
            let manifestSize = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard manifestSize > 0, manifestSize <= Self.maximumManifestBytes else {
                return .invalid(.invalidManifest)
            }
            let manifest: LibraryExportManifest
            do {
                manifest = try Self.manifestDecoder.decode(
                    LibraryExportManifest.self,
                    from: Data(contentsOf: manifestURL)
                )
            } catch {
                return .invalid(.invalidManifest)
            }
            guard manifest.productIdentifier == Self.productIdentifier else {
                return .invalid(.wrongProduct(manifest.productIdentifier))
            }
            guard manifest.formatVersion == Self.formatVersion else {
                return .invalid(
                    .unsupportedFormat(
                        found: manifest.formatVersion,
                        supported: Self.formatVersion
                    ))
            }
            guard manifest.files.count <= Self.maximumFileCount else {
                return .invalid(.invalidManifest)
            }
            if let issue = try validateManifestFiles(manifest, archive: archive) {
                return .invalid(issue)
            }
            let database =
                archive
                .appendingPathComponent(Self.libraryDirectoryName, isDirectory: true)
                .appendingPathComponent("db.sqlite3")
            let validation: SQLiteReadOnlyValidation
            do {
                validation = try SQLiteDatabase.validateReadOnly(at: database)
            } catch {
                return .invalid(.databaseInvalid(error.localizedDescription))
            }
            guard validation.isValid else {
                let detail =
                    (validation.integrityFailures
                    + [
                        validation.foreignKeyViolationCount > 0
                            ? "\(validation.foreignKeyViolationCount) foreign-key violations"
                            : nil
                    ].compactMap { $0 }).joined(separator: "; ")
                return .invalid(.databaseInvalid(detail))
            }
            guard validation.schemaVersion == manifest.schemaVersion else {
                return .invalid(
                    .schemaMismatch(
                        manifest: manifest.schemaVersion,
                        database: validation.schemaVersion
                    ))
            }
            if validation.schemaVersion > Schema.currentVersion {
                return .newerSchema(
                    found: validation.schemaVersion,
                    supported: Schema.currentVersion,
                    manifest: manifest
                )
            }
            return .ready(manifest)
        } catch let issue as LibraryBackupIssue {
            return .invalid(issue)
        } catch {
            return .invalid(.invalidManifest)
        }
    }

    private func validatedDestination(_ requested: URL, liveRoot: URL) throws -> URL {
        guard !requested.lastPathComponent.isEmpty, requested.lastPathComponent != "." else {
            throw LibraryExportError.unsafeDestination(requested.path)
        }
        let parent = requested.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LibraryExportError.unsafeDestination(requested.path)
        }
        let destination = parent.resolvingSymlinksInPath()
            .appendingPathComponent(requested.lastPathComponent, isDirectory: true)
            .standardizedFileURL
        let source = liveRoot.resolvingSymlinksInPath().standardizedFileURL
        guard !isSameOrDescendant(destination, of: source) else {
            throw LibraryExportError.unsafeDestination(destination.path)
        }
        guard !nodeExists(destination) else {
            throw LibraryExportError.destinationExists(destination.path)
        }
        guard fileManager.fileExists(atPath: ScreenlogPaths.databaseURL(root: liveRoot).path) else {
            throw LibraryExportError.sourceUnavailable(liveRoot.path)
        }
        return destination
    }

    private func copyManagedDirectory(from source: URL, to destination: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue,
            !isSymbolicLink(source)
        else {
            throw LibraryExportError.sourceUnavailable(source.path)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func fileEntries(in directory: URL, archiveRoot: URL) throws -> [LibraryExportManifest.FileEntry] {
        let urls = try regularFilesRecursively(in: directory)
        guard urls.count <= Self.maximumFileCount else {
            throw LibraryExportError.snapshotFailed("too many managed files")
        }
        return try urls.map { url in
            let relativePath = try relativePath(of: url, within: archiveRoot)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return LibraryExportManifest.FileEntry(
                relativePath: relativePath,
                sizeBytes: Int64(size),
                sha256: try sha256(of: url)
            )
        }.sorted { $0.relativePath < $1.relativePath }
    }

    private func validateManifestFiles(
        _ manifest: LibraryExportManifest,
        archive: URL
    ) throws -> LibraryBackupIssue? {
        var expected = Set<String>()
        var computedTotal: Int64 = 0
        for entry in manifest.files {
            guard isSafeRelativePath(entry.relativePath) else {
                return .unsafeRelativePath(entry.relativePath)
            }
            guard expected.insert(entry.relativePath).inserted else {
                return .duplicateManifestPath(entry.relativePath)
            }
            let file = archive.appendingPathComponent(entry.relativePath)
            guard isRegularFile(file), !isSymbolicLink(file) else {
                return nodeExists(file) ? .unsupportedNode(entry.relativePath) : .missingFile(entry.relativePath)
            }
            let size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard size == entry.sizeBytes else { return .sizeMismatch(entry.relativePath) }
            guard try sha256(of: file) == entry.sha256 else { return .checksumMismatch(entry.relativePath) }
            let next = computedTotal.addingReportingOverflow(size)
            guard !next.overflow else { return .invalidManifest }
            computedTotal = next.partialValue
        }
        guard computedTotal == manifest.totalBytes else { return .invalidManifest }
        let databasePath = "\(Self.libraryDirectoryName)/db.sqlite3"
        guard expected.contains(databasePath) else { return .missingFile(databasePath) }

        let nodes = try archiveNodes(in: archive)
        let expectedFiles = expected.union([Self.manifestName])
        if let missing = expectedFiles.subtracting(nodes.files).sorted().first { return .missingFile(missing) }
        if let extra = nodes.files.subtracting(expectedFiles).sorted().first { return .unexpectedFile(extra) }

        var expectedDirectories: Set<String> = [
            Self.libraryDirectoryName,
            "\(Self.libraryDirectoryName)/frames",
            "\(Self.libraryDirectoryName)/videos",
        ]
        for path in expected {
            var components = path.split(separator: "/").map(String.init)
            _ = components.popLast()
            while !components.isEmpty {
                expectedDirectories.insert(components.joined(separator: "/"))
                _ = components.popLast()
            }
        }
        if let missing = expectedDirectories.subtracting(nodes.directories).sorted().first {
            return .missingFile(missing)
        }
        if let extra = nodes.directories.subtracting(expectedDirectories).sorted().first {
            return .unexpectedFile(extra)
        }
        return nil
    }

    private struct ArchiveNodes {
        var files: Set<String> = []
        var directories: Set<String> = []
    }

    /// Inventory the complete package, including empty directories, so an
    /// archive cannot smuggle unlisted content alongside a valid manifest.
    private func archiveNodes(in root: URL) throws -> ArchiveNodes {
        var enumerationError: Error?
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            )
        else { throw LibraryBackupIssue.unsupportedNode(root.path) }
        var result = ArchiveNodes()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            let relative = try relativePath(of: url, within: root)
            if values.isSymbolicLink == true {
                throw LibraryBackupIssue.unsupportedNode(relative)
            } else if values.isRegularFile == true {
                result.files.insert(relative)
            } else if values.isDirectory == true {
                result.directories.insert(relative)
            } else {
                throw LibraryBackupIssue.unsupportedNode(relative)
            }
            if result.files.count + result.directories.count > Self.maximumFileCount {
                throw LibraryBackupIssue.invalidManifest
            }
        }
        if let enumerationError { throw enumerationError }
        return result
    }

    private func regularFilesRecursively(in root: URL) throws -> [URL] {
        var enumerationError: Error?
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            )
        else { throw LibraryBackupIssue.unsupportedNode(root.path) }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw LibraryBackupIssue.unsupportedNode(url.path)
            } else if values.isRegularFile == true {
                files.append(url)
            } else if values.isDirectory != true {
                throw LibraryBackupIssue.unsupportedNode(url.path)
            }
            if files.count > Self.maximumFileCount { throw LibraryBackupIssue.invalidManifest }
        }
        if let enumerationError { throw enumerationError }
        return files.sorted { $0.path < $1.path }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func relativePath(of url: URL, within root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { throw LibraryBackupIssue.unsafeRelativePath(path) }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return false
        }
        return path == "\(Self.libraryDirectoryName)/db.sqlite3"
            || path.hasPrefix("\(Self.libraryDirectoryName)/frames/")
            || path.hasPrefix("\(Self.libraryDirectoryName)/videos/")
    }

    private func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private func nodeExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static var manifestEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var manifestDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
