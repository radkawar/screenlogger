import Foundation
import SQLite3

public struct LibraryRestoreResult: Equatable, Sendable {
    public let manifest: LibraryExportManifest
    public let restoredBytes: Int64

    public init(manifest: LibraryExportManifest, restoredBytes: Int64) {
        self.manifest = manifest
        self.restoredBytes = restoredBytes
    }
}

public enum LibraryRestoreRecoveryOutcome: Equatable, Sendable {
    case nothingToRecover
    case rolledBack
    case completed
}

public enum LibraryRestoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidBackup(LibraryBackupIssue)
    case newerSchema(found: Int, supported: Int)
    case unsafeArchive
    case unsafeLiveLibrary
    case liveLibraryUnavailable
    case anotherRestoreNeedsRecovery
    case stagingFailed
    case activationFailed
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .invalidBackup(let issue):
            return "Screenlogger cannot restore this Library copy. \(issue.localizedDescription)"
        case .newerSchema:
            return "A newer Screenlogger version made this Library copy. Update Screenlogger before you restore it."
        case .unsafeArchive:
            return "Choose a Library copy outside your current Screenlogger Library."
        case .unsafeLiveLibrary:
            return "Screenlogger refused an unsafe Library location."
        case .liveLibraryUnavailable:
            return "Your current Library is unavailable, so Screenlogger left it unchanged."
        case .anotherRestoreNeedsRecovery:
            return "Screenlogger found more than one unfinished restore and left every Library unchanged."
        case .stagingFailed:
            return "Screenlogger could not prepare and verify the replacement Library. It did not change your current Library."
        case .activationFailed:
            return "Screenlogger could not activate the replacement Library. It restored your previous Library."
        case .rollbackFailed:
            return "Screenlogger could not safely complete or undo an interrupted restore. Capture must remain off."
        }
    }
}

/// Activates a verified Library export with a same-volume, journaled swap.
///
/// The caller must stop capture, IPC hosts, maintenance, and reads, then release
/// every `Store` connected to `liveRoot` before calling `restore`. This explicit
/// boundary prevents an open SQLite handle from continuing to write to the
/// previous database inode after activation. Staging and verification happen
/// before any live bytes move. Once mutation begins, an atomically replaced state marker lets
/// the next launch deterministically finish or roll back every interruption point.
public final class LibraryRestoreService: @unchecked Sendable {
    static let transactionVersion = 1
    static let markerName = "restore-state.json"

    enum TransactionState: String, Codable, Sendable {
        case staging
        case prepared
        case movingLive
        case liveMoved
        case installing
        case installed
    }

    private struct TransactionMarker: Codable, Equatable, Sendable {
        let version: Int
        let liveRootName: String
        var state: TransactionState
    }

    private let fileManager: FileManager
    private let interruptAfter: TransactionState?

    public init() {
        fileManager = .default
        interruptAfter = nil
    }

    init(fileManager: FileManager = .default, interruptAfter: TransactionState? = nil) {
        self.fileManager = fileManager
        self.interruptAfter = interruptAfter
    }

    @discardableResult
    public func restore(from archive: URL, replacing liveRoot: URL) throws -> LibraryRestoreResult {
        _ = try recoverInterruptedRestore(at: liveRoot)
        let (sourceManifest, canonicalArchive, canonicalLiveRoot) = try validateInputs(
            archive: archive,
            liveRoot: liveRoot
        )
        let transaction = canonicalLiveRoot.deletingLastPathComponent().appendingPathComponent(
            ".\(canonicalLiveRoot.lastPathComponent).restore-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(
                at: transaction,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            var marker = TransactionMarker(
                version: Self.transactionVersion,
                liveRootName: canonicalLiveRoot.lastPathComponent,
                state: .staging
            )
            try write(marker, in: transaction)
            let stagedArchive = transaction.appendingPathComponent("incoming", isDirectory: true)
            try fileManager.copyItem(at: canonicalArchive, to: stagedArchive)

            let stagedManifest: LibraryExportManifest
            switch LibraryExportService().preflightRestore(at: stagedArchive) {
            case .ready(let manifest): stagedManifest = manifest
            case .newerSchema(let found, let supported, _):
                throw LibraryRestoreError.newerSchema(found: found, supported: supported)
            case .invalid(let issue): throw LibraryRestoreError.invalidBackup(issue)
            }
            guard stagedManifest == sourceManifest else {
                throw LibraryRestoreError.stagingFailed
            }

            let incomingRoot = stagedArchive.appendingPathComponent(
                LibraryExportService.libraryDirectoryName,
                isDirectory: true
            )
            // Point the staged database at staged media while Store performs
            // migrations/startup recovery, then make paths portable to the
            // final live root only after that validation is complete.
            try rewriteManagedPaths(in: incomingRoot, for: incomingRoot)
            try validatePreparedLibrary(at: incomingRoot)
            try rewriteManagedPaths(in: incomingRoot, for: canonicalLiveRoot)
            try validateActivatedLibrary(at: incomingRoot)

            marker.state = .prepared
            try write(marker, in: transaction)
            try interruptIfRequested(after: .prepared)

            try activatePreparedTransaction(transaction, liveRoot: canonicalLiveRoot, marker: &marker)
            try fileManager.removeItem(at: transaction)
            return LibraryRestoreResult(manifest: stagedManifest, restoredBytes: stagedManifest.totalBytes)
        } catch is SimulatedInterruption {
            throw LibraryRestoreError.activationFailed
        } catch let error as LibraryRestoreError {
            if nodeExists(transaction), markerExists(in: transaction) {
                do { try reconcileFailedTransaction(transaction, liveRoot: canonicalLiveRoot) } catch {
                    throw LibraryRestoreError.rollbackFailed
                }
            } else if nodeExists(transaction) {
                try? fileManager.removeItem(at: transaction)
            }
            throw error
        } catch {
            if nodeExists(transaction), markerExists(in: transaction) {
                do { try reconcileFailedTransaction(transaction, liveRoot: canonicalLiveRoot) } catch {
                    throw LibraryRestoreError.rollbackFailed
                }
                throw LibraryRestoreError.activationFailed
            }
            try? fileManager.removeItem(at: transaction)
            throw LibraryRestoreError.stagingFailed
        }
    }

    /// Reconciles the single restore transaction belonging to `liveRoot`.
    /// Prepared work is discarded, mutations in progress are rolled back, and
    /// a fully installed/valid Library is finalized. Ambiguous multiple journals
    /// are never guessed at.
    @discardableResult
    public func recoverInterruptedRestore(at liveRoot: URL) throws -> LibraryRestoreRecoveryOutcome {
        let canonicalLiveRoot = try validatedLiveRootLocation(liveRoot)
        let transactions = try restoreTransactions(for: canonicalLiveRoot)
        guard !transactions.isEmpty else { return .nothingToRecover }
        guard transactions.count == 1 else { throw LibraryRestoreError.anotherRestoreNeedsRecovery }
        let transaction = transactions[0]
        let marker = try readMarker(in: transaction, liveRoot: canonicalLiveRoot)

        switch marker.state {
        case .staging, .prepared:
            try fileManager.removeItem(at: transaction)
            return .rolledBack
        case .movingLive, .liveMoved, .installing:
            do { try rollBack(transaction: transaction, liveRoot: canonicalLiveRoot) } catch { throw LibraryRestoreError.rollbackFailed }
            return .rolledBack
        case .installed:
            do {
                try validateActivatedLibrary(at: canonicalLiveRoot)
                try fileManager.removeItem(at: transaction)
                return .completed
            } catch {
                do { try rollBack(transaction: transaction, liveRoot: canonicalLiveRoot) } catch {
                    throw LibraryRestoreError.rollbackFailed
                }
                return .rolledBack
            }
        }
    }

    private func validateInputs(
        archive: URL,
        liveRoot: URL
    ) throws -> (LibraryExportManifest, URL, URL) {
        let canonicalLiveRoot = try validatedLiveRoot(liveRoot)
        let canonicalArchive = archive.resolvingSymlinksInPath().standardizedFileURL
        guard isDirectory(canonicalArchive), !isSymbolicLink(archive),
            !isSameOrDescendant(canonicalArchive, of: canonicalLiveRoot),
            !isSameOrDescendant(canonicalLiveRoot, of: canonicalArchive)
        else { throw LibraryRestoreError.unsafeArchive }

        switch LibraryExportService().preflightRestore(at: canonicalArchive) {
        case .ready(let manifest): return (manifest, canonicalArchive, canonicalLiveRoot)
        case .newerSchema(let found, let supported, _):
            throw LibraryRestoreError.newerSchema(found: found, supported: supported)
        case .invalid(let issue): throw LibraryRestoreError.invalidBackup(issue)
        }
    }

    private func validatedLiveRoot(_ requested: URL) throws -> URL {
        let canonical = try validatedLiveRootLocation(requested)
        guard isRegularFile(ScreenlogPaths.databaseURL(root: canonical)),
            !isSymbolicLink(ScreenlogPaths.databaseURL(root: canonical)),
            isDirectory(ScreenlogPaths.framesDirectory(root: canonical)),
            !isSymbolicLink(ScreenlogPaths.framesDirectory(root: canonical)),
            isDirectory(ScreenlogPaths.videosDirectory(root: canonical)),
            !isSymbolicLink(ScreenlogPaths.videosDirectory(root: canonical))
        else { throw LibraryRestoreError.liveLibraryUnavailable }
        return canonical
    }

    private func validatedLiveRootLocation(_ requested: URL) throws -> URL {
        guard !requested.lastPathComponent.isEmpty,
            requested.lastPathComponent != ".",
            isDirectory(requested),
            !isSymbolicLink(requested)
        else { throw LibraryRestoreError.unsafeLiveLibrary }
        let canonical = requested.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.path != "/" else { throw LibraryRestoreError.unsafeLiveLibrary }
        return canonical
    }

    private func activatePreparedTransaction(
        _ transaction: URL,
        liveRoot: URL,
        marker: inout TransactionMarker
    ) throws {
        let previous = transaction.appendingPathComponent("previous", isDirectory: true)
        try fileManager.createDirectory(
            at: previous,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )

        marker.state = .movingLive
        try write(marker, in: transaction)
        try interruptIfRequested(after: .movingLive)
        for name in managedNodeNamesIncludingSidecars {
            let source = liveRoot.appendingPathComponent(name)
            if nodeExists(source) {
                try fileManager.moveItem(at: source, to: previous.appendingPathComponent(name))
            }
        }

        marker.state = .liveMoved
        try write(marker, in: transaction)
        try interruptIfRequested(after: .liveMoved)
        marker.state = .installing
        try write(marker, in: transaction)
        try interruptIfRequested(after: .installing)

        let incoming =
            transaction
            .appendingPathComponent("incoming", isDirectory: true)
            .appendingPathComponent(LibraryExportService.libraryDirectoryName, isDirectory: true)
        for name in managedNodeNames {
            try fileManager.moveItem(
                at: incoming.appendingPathComponent(name),
                to: liveRoot.appendingPathComponent(name)
            )
        }

        marker.state = .installed
        try write(marker, in: transaction)
        try interruptIfRequested(after: .installed)
        try validateActivatedLibrary(at: liveRoot)
    }

    private func rollBack(transaction: URL, liveRoot: URL) throws {
        let previous = transaction.appendingPathComponent("previous", isDirectory: true)
        guard isDirectory(previous), !isSymbolicLink(previous) else {
            throw LibraryRestoreError.rollbackFailed
        }
        for name in managedNodeNamesIncludingSidecars {
            let backup = previous.appendingPathComponent(name)
            guard nodeExists(backup) else { continue }
            let live = liveRoot.appendingPathComponent(name)
            if nodeExists(live) { try fileManager.removeItem(at: live) }
            try fileManager.moveItem(at: backup, to: live)
        }
        guard isRegularFile(ScreenlogPaths.databaseURL(root: liveRoot)),
            isDirectory(ScreenlogPaths.framesDirectory(root: liveRoot)),
            isDirectory(ScreenlogPaths.videosDirectory(root: liveRoot))
        else { throw LibraryRestoreError.rollbackFailed }
        try fileManager.removeItem(at: transaction)
    }

    private func reconcileFailedTransaction(_ transaction: URL, liveRoot: URL) throws {
        let marker = try readMarker(in: transaction, liveRoot: liveRoot)
        switch marker.state {
        case .staging, .prepared:
            try fileManager.removeItem(at: transaction)
        case .movingLive, .liveMoved, .installing, .installed:
            try rollBack(transaction: transaction, liveRoot: liveRoot)
        }
    }

    private func rewriteManagedPaths(in stagedRoot: URL, for liveRoot: URL) throws {
        let database = try SQLiteDatabase(path: ScreenlogPaths.databaseURL(root: stagedRoot).path)
        do {
            try database.transaction {
                try rewritePaths(
                    database: database,
                    table: "frame",
                    column: "image_path",
                    stagedDirectory: ScreenlogPaths.framesDirectory(root: stagedRoot),
                    liveDirectory: ScreenlogPaths.framesDirectory(root: liveRoot)
                )
                try rewritePaths(
                    database: database,
                    table: "video",
                    column: "path",
                    stagedDirectory: ScreenlogPaths.videosDirectory(root: stagedRoot),
                    liveDirectory: ScreenlogPaths.videosDirectory(root: liveRoot)
                )
            }
            try database.exec("PRAGMA wal_checkpoint(TRUNCATE);")
            try database.close()
        } catch {
            try? database.close()
            throw error
        }
        removeSQLiteSidecars(at: ScreenlogPaths.databaseURL(root: stagedRoot))
    }

    private func rewritePaths(
        database: SQLiteDatabase,
        table: String,
        column: String,
        stagedDirectory: URL,
        liveDirectory: URL
    ) throws {
        let query = try database.prepare("SELECT id, \(column) FROM \(table) WHERE \(column) IS NOT NULL AND \(column) != ''")
        defer { sqlite3_finalize(query) }
        var replacements: [(Int64, String)] = []
        var rc = sqlite3_step(query)
        while rc == SQLITE_ROW {
            let identifier = sqlite3_column_int64(query, 0)
            guard let raw = sqlite3_column_text(query, 1) else { throw LibraryRestoreError.stagingFailed }
            let oldPath = String(cString: raw)
            let filename = URL(fileURLWithPath: oldPath).lastPathComponent
            guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"),
                isRegularFile(stagedDirectory.appendingPathComponent(filename)),
                !isSymbolicLink(stagedDirectory.appendingPathComponent(filename))
            else { throw LibraryRestoreError.stagingFailed }
            replacements.append((identifier, liveDirectory.appendingPathComponent(filename).path))
            rc = sqlite3_step(query)
        }
        guard rc == SQLITE_DONE else { throw LibraryRestoreError.stagingFailed }

        let update = try database.prepare("UPDATE \(table) SET \(column) = ? WHERE id = ?")
        defer { sqlite3_finalize(update) }
        for (identifier, path) in replacements {
            sqlite3_reset(update)
            sqlite3_clear_bindings(update)
            SQLiteBind.text(update, 1, path)
            SQLiteBind.int64(update, 2, identifier)
            guard sqlite3_step(update) == SQLITE_DONE else { throw LibraryRestoreError.stagingFailed }
        }
    }

    private func validatePreparedLibrary(at root: URL) throws {
        do {
            let store = try Store(root: root)
            try store.db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
            try store.db.close()
            removeSQLiteSidecars(at: ScreenlogPaths.databaseURL(root: root))
            try validateActivatedLibrary(at: root)
        } catch let error as LibraryRestoreError {
            throw error
        } catch {
            throw LibraryRestoreError.stagingFailed
        }
    }

    private func validateActivatedLibrary(at root: URL) throws {
        let validation = try SQLiteDatabase.validateReadOnly(at: ScreenlogPaths.databaseURL(root: root))
        guard validation.isValid, validation.schemaVersion == Schema.currentVersion,
            isDirectory(ScreenlogPaths.framesDirectory(root: root)),
            isDirectory(ScreenlogPaths.videosDirectory(root: root))
        else { throw LibraryRestoreError.activationFailed }
    }

    private func restoreTransactions(for liveRoot: URL) throws -> [URL] {
        let parent = liveRoot.deletingLastPathComponent()
        let prefix = ".\(liveRoot.lastPathComponent).restore-"
        return try fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants]
        ).filter { candidate in
            candidate.lastPathComponent.hasPrefix(prefix)
                && isDirectory(candidate)
                && !isSymbolicLink(candidate)
                && markerExists(in: candidate)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func readMarker(in transaction: URL, liveRoot: URL) throws -> TransactionMarker {
        do {
            let markerURL = transaction.appendingPathComponent(Self.markerName)
            guard isRegularFile(markerURL), !isSymbolicLink(markerURL) else {
                throw LibraryRestoreError.rollbackFailed
            }
            let marker = try JSONDecoder().decode(TransactionMarker.self, from: Data(contentsOf: markerURL))
            guard marker.version == Self.transactionVersion,
                marker.liveRootName == liveRoot.lastPathComponent
            else { throw LibraryRestoreError.rollbackFailed }
            return marker
        } catch let error as LibraryRestoreError { throw error } catch { throw LibraryRestoreError.rollbackFailed }
    }

    private func write(_ marker: TransactionMarker, in transaction: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(marker).write(
            to: transaction.appendingPathComponent(Self.markerName),
            options: .atomic
        )
    }

    private var managedNodeNames: [String] { ["db.sqlite3", "frames", "videos"] }
    private var managedNodeNamesIncludingSidecars: [String] {
        ["db.sqlite3", "db.sqlite3-wal", "db.sqlite3-shm", "frames", "videos"]
    }

    private func markerExists(in transaction: URL) -> Bool {
        nodeExists(transaction.appendingPathComponent(Self.markerName))
    }

    private func removeSQLiteSidecars(at database: URL) {
        try? fileManager.removeItem(atPath: database.path + "-wal")
        try? fileManager.removeItem(atPath: database.path + "-shm")
    }

    private func nodeExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func isSameOrDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let ancestorComponents = ancestor.standardizedFileURL.pathComponents
        return candidateComponents.count >= ancestorComponents.count
            && Array(candidateComponents.prefix(ancestorComponents.count)) == ancestorComponents
    }

    private struct SimulatedInterruption: Error {}

    private func interruptIfRequested(after state: TransactionState) throws {
        if interruptAfter == state { throw SimulatedInterruption() }
    }
}
