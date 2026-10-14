import Foundation
import SQLite3

/// The user-visible unit to remove from the local capture library.
///
/// Time ranges are half-open (`startMs <= timestamp < endMs`). `today` stores the
/// resolved bounds so a confirmation cannot silently move across midnight.
public enum LibraryDeletionSelection: Sendable, Equatable {
    case moment(frameID: Int64)
    case timeRange(startMs: Int64, endMs: Int64)
    case today(startMs: Int64, endMs: Int64)
    case entireLibrary

    public static func today(
        containing date: Date = Date(),
        calendar: Calendar = .current
    ) -> LibraryDeletionSelection {
        let interval =
            calendar.dateInterval(of: .day, for: date)
            ?? DateInterval(start: date, duration: 86_400)
        return .today(
            startMs: Int64(interval.start.timeIntervalSince1970 * 1_000),
            endMs: Int64(interval.end.timeIntervalSince1970 * 1_000)
        )
    }
}

/// Explicit proof that the caller showed and accepted a particular deletion review.
public enum LibraryDeletionConfirmation: Sendable, Equatable {
    case userConfirmed(reviewID: UUID)
}

/// Immutable review returned before a destructive operation can be requested.
public struct LibraryDeletionPlan: Sendable {
    public let reviewID: UUID
    public let selection: LibraryDeletionSelection
    /// Synchronized moments matching the request before compacted-video expansion.
    public let requestedMomentCount: Int
    /// Actual number removed. May be larger when a compacted video crosses the range.
    public let affectedMomentCount: Int
    public let affectedVideoCount: Int
    public let managedFileCount: Int
    public let missingFileCount: Int
    /// Paths outside Screenlogger's frames/videos folders are detached but never removed.
    public let unmanagedFileCount: Int
    public let estimatedManagedBytes: Int64

    fileprivate let frameIDs: [Int64]
    fileprivate let videoIDs: [Int64]
    fileprivate let resources: [DeletionResource]
}

public struct LibraryDeletionReport: Sendable, Equatable {
    public let deletedMomentCount: Int
    public let deletedVideoCount: Int
    public let deletedManagedFileCount: Int
    public let skippedMissingFileCount: Int
    public let skippedUnmanagedFileCount: Int
    public let freedBytes: Int64
    /// True only when committed bytes remain in the private recovery folder for retry.
    public let cleanupPending: Bool
}

public enum LibraryDeletionError: Error, LocalizedError, Equatable {
    case invalidRange
    case nothingToDelete
    case confirmationRequired
    case confirmationDoesNotMatchReview
    case reviewExpired
    case unsafeManagedPath(String)
    case recoveryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRange:
            return "The selected time range is invalid."
        case .nothingToDelete:
            return "There are no moments in that selection."
        case .confirmationRequired:
            return "Review this deletion. Confirm it before you continue."
        case .confirmationDoesNotMatchReview:
            return "This confirmation belongs to a different deletion review."
        case .reviewExpired:
            return "The Library changed after your deletion review. Review it again."
        case .unsafeManagedPath:
            return "Screenlogger refused to remove a file outside its managed Library."
        case .recoveryFailed:
            return "Screenlogger could not safely recover an interrupted deletion."
        }
    }
}

protocol LibraryDeletionFileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func attributes(at url: URL) throws -> [FileAttributeKey: Any]
    func createDirectory(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func linkItem(at source: URL, to destination: URL) throws
    func copyItem(at source: URL, to destination: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func readData(at url: URL) throws -> Data
    func writeDataAtomically(_ data: Data, to url: URL) throws
}

private struct LocalLibraryDeletionFileSystem: LibraryDeletionFileSystem {
    func fileExists(at url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: url.path)
    }
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }
    func linkItem(at source: URL, to destination: URL) throws {
        try FileManager.default.linkItem(at: source, to: destination)
    }
    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }
    func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }
    func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }
    func readData(at url: URL) throws -> Data { try Data(contentsOf: url) }
    func writeDataAtomically(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}

private enum DeletionResourceKind: String, Sendable, Codable {
    case frame
    case video
}

private struct DeletionResource: Sendable, Equatable {
    var path: String
    var kind: DeletionResourceKind
    var isManaged: Bool
    var exists: Bool
    var sizeBytes: Int64
}

private struct DeletionManifest: Codable {
    struct Entry: Codable {
        var originalPath: String
        var backupPath: String
    }

    var operationID: UUID
    var markerKey: String
    var entries: [Entry]
}

/// Reviewed, recoverable deletion of local moments.
///
/// Files are first copied or hard-linked into a private recovery directory. Database
/// changes and canonical file removals then occur as one SQLite transaction. A durable
/// marker distinguishes a committed transaction from an interrupted/rolled-back one,
/// allowing the next call (or Store open) to finish cleanup or restore the originals.
public final class LibraryDeletionService: @unchecked Sendable {
    private let fileSystem: any LibraryDeletionFileSystem

    public init() {
        self.fileSystem = LocalLibraryDeletionFileSystem()
    }

    init(fileSystem: any LibraryDeletionFileSystem) {
        self.fileSystem = fileSystem
    }

    public func prepare(selection: LibraryDeletionSelection, store: Store) throws -> LibraryDeletionPlan {
        try store.withExclusiveMaintenance {
            try recoverPendingOperations(store: store)
            // Keep selection, video expansion, and resource discovery on one SQLite
            // snapshot so compaction cannot produce a mixed review.
            return try store.db.transaction {
                try buildPlan(selection: selection, store: store)
            }
        }
    }

    @discardableResult
    public func delete(
        _ plan: LibraryDeletionPlan,
        confirmation: LibraryDeletionConfirmation,
        store: Store
    ) throws -> LibraryDeletionReport {
        try store.withExclusiveMaintenance {
            try deleteExclusively(plan, confirmation: confirmation, store: store)
        }
    }

    private func deleteExclusively(
        _ plan: LibraryDeletionPlan,
        confirmation: LibraryDeletionConfirmation,
        store: Store
    ) throws -> LibraryDeletionReport {
        try recoverPendingOperations(store: store)

        guard case .userConfirmed(let reviewID) = confirmation else {
            throw LibraryDeletionError.confirmationRequired
        }
        guard reviewID == plan.reviewID else {
            throw LibraryDeletionError.confirmationDoesNotMatchReview
        }

        let operationID = UUID()
        let markerKey = "library_deletion_committed_\(operationID.uuidString.lowercased())"
        let operationDirectory = recoveryRoot(store: store)
            .appendingPathComponent(operationID.uuidString.lowercased(), isDirectory: true)
        let filesDirectory = operationDirectory.appendingPathComponent("files", isDirectory: true)
        try fileSystem.createDirectory(at: filesDirectory)

        let managedExisting = plan.resources.filter { $0.isManaged && $0.exists }
        let entries = managedExisting.enumerated().map { index, resource in
            DeletionManifest.Entry(
                originalPath: resource.path,
                backupPath: filesDirectory.appendingPathComponent(String(index), isDirectory: false).path
            )
        }
        let manifest = DeletionManifest(operationID: operationID, markerKey: markerKey, entries: entries)
        let manifestURL = operationDirectory.appendingPathComponent("manifest.json", isDirectory: false)
        try fileSystem.writeDataAtomically(try JSONEncoder().encode(manifest), to: manifestURL)

        do {
            try store.db.transaction {
                // Hold the SQLite write lock from stale-review validation through commit.
                // Recording and compaction therefore cannot change the reviewed rows in
                // the gap between validation and deletion.
                let current = try buildPlan(selection: plan.selection, store: store)
                guard current.frameIDs == plan.frameIDs,
                    current.videoIDs == plan.videoIDs,
                    current.resources == plan.resources
                else {
                    throw LibraryDeletionError.reviewExpired
                }

                for entry in entries {
                    let original = URL(fileURLWithPath: entry.originalPath)
                    let backup = URL(fileURLWithPath: entry.backupPath)
                    do {
                        try fileSystem.linkItem(at: original, to: backup)
                    } catch {
                        try fileSystem.copyItem(at: original, to: backup)
                    }
                }

                // Remove canonical bytes while recovery copies exist. If anything below
                // fails, SQLite rolls back and the catch restores every missing original.
                for entry in entries {
                    let original = URL(fileURLWithPath: entry.originalPath)
                    if fileSystem.fileExists(at: original) {
                        try fileSystem.removeItem(at: original)
                    }
                }
                try installFrameIDs(plan.frameIDs, store: store)
                try store.db.exec("DELETE FROM frame WHERE id IN (SELECT id FROM deletion_frame_ids)")
                try deleteVideos(plan.videoIDs, store: store)
                try repairSegments(store: store)
                try pruneCatalogOrphans(store: store)
                try pruneAXOrphans(store: store)
                try store.setMeta(key: markerKey, value: "1")
            }
        } catch {
            do {
                try restore(manifest: manifest, committed: false)
                try? fileSystem.removeItem(at: operationDirectory)
            } catch let recoveryError {
                throw LibraryDeletionError.recoveryFailed(String(describing: recoveryError))
            }
            throw error
        }

        var cleanupPending = false
        do {
            try restore(manifest: manifest, committed: true)
            try fileSystem.removeItem(at: operationDirectory)
            try store.setMeta(key: markerKey, value: "")
        } catch {
            // The DB commit is authoritative. Leave the manifest + marker so the next
            // Store open or deletion request retries removal of the recovery bytes.
            cleanupPending = true
        }

        return LibraryDeletionReport(
            deletedMomentCount: plan.affectedMomentCount,
            deletedVideoCount: plan.affectedVideoCount,
            deletedManagedFileCount: managedExisting.count,
            skippedMissingFileCount: plan.missingFileCount,
            skippedUnmanagedFileCount: plan.unmanagedFileCount,
            // Recovery links/copies still consume the allocation until cleanup succeeds.
            freedBytes: cleanupPending ? 0 : managedExisting.reduce(0) { $0 + $1.sizeBytes },
            cleanupPending: cleanupPending
        )
    }

    /// Repairs any deletion interrupted between SQLite and filesystem completion.
    public func recoverPendingOperations(store: Store) throws {
        try store.withExclusiveMaintenance {
            try recoverPendingOperationsExclusively(store: store)
        }
    }

    private func recoverPendingOperationsExclusively(store: Store) throws {
        let root = recoveryRoot(store: store)
        guard fileSystem.fileExists(at: root) else { return }
        for directory in try fileSystem.contentsOfDirectory(at: root) {
            guard isDescendant(directory, of: root) else {
                throw LibraryDeletionError.recoveryFailed("Recovery entry escaped the managed directory")
            }
            let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
            guard fileSystem.fileExists(at: manifestURL) else { continue }
            let manifest: DeletionManifest
            do {
                manifest = try JSONDecoder().decode(
                    DeletionManifest.self,
                    from: fileSystem.readData(at: manifestURL)
                )
            } catch {
                throw LibraryDeletionError.recoveryFailed("Unreadable deletion manifest at \(manifestURL.path)")
            }
            try validateRecoveryManifest(manifest, operationDirectory: directory, store: store)
            let committed = try store.getMeta(key: manifest.markerKey) == "1"
            do {
                try restore(manifest: manifest, committed: committed)
                try fileSystem.removeItem(at: directory)
                if committed { try store.setMeta(key: manifest.markerKey, value: "") }
            } catch {
                throw LibraryDeletionError.recoveryFailed(String(describing: error))
            }
        }
    }

    private func buildPlan(
        selection: LibraryDeletionSelection,
        store: Store
    ) throws -> LibraryDeletionPlan {
        let requested = try selectedFrames(selection: selection, store: store)
        let videoIDs: [Int64]
        if case .entireLibrary = selection {
            videoIDs = try allVideoIDs(store: store)
        } else {
            videoIDs = Array(Set(requested.compactMap(\.videoID))).sorted()
        }
        guard !requested.isEmpty || !videoIDs.isEmpty else {
            throw LibraryDeletionError.nothingToDelete
        }
        var affected = requested
        if !videoIDs.isEmpty {
            let expanded = try frames(videoIDs: videoIDs, store: store)
            let existing = Set(affected.map(\.id))
            affected.append(contentsOf: expanded.filter { !existing.contains($0.id) })
        }
        affected.sort { $0.id < $1.id }

        var resources: [DeletionResource] = []
        var seenPaths = Set<String>()
        for frame in affected {
            if let path = frame.imagePath, !path.isEmpty {
                let candidate = try resource(path: path, kind: .frame, store: store)
                if seenPaths.insert(candidate.path).inserted { resources.append(candidate) }
            }
        }
        for video in try videos(ids: videoIDs, store: store) {
            let candidate = try resource(path: video.path, kind: .video, store: store)
            if seenPaths.insert(candidate.path).inserted { resources.append(candidate) }
        }
        resources.sort { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.path < rhs.path
        }

        return LibraryDeletionPlan(
            reviewID: UUID(),
            selection: selection,
            requestedMomentCount: Set(requested.map(\.timestampMs)).count,
            affectedMomentCount: Set(affected.map(\.timestampMs)).count,
            affectedVideoCount: videoIDs.count,
            managedFileCount: resources.filter { $0.isManaged && $0.exists }.count,
            missingFileCount: resources.filter { $0.isManaged && !$0.exists }.count,
            unmanagedFileCount: resources.filter { !$0.isManaged }.count,
            estimatedManagedBytes: resources.filter { $0.isManaged && $0.exists }.reduce(0) { $0 + $1.sizeBytes },
            frameIDs: affected.map(\.id),
            videoIDs: videoIDs,
            resources: resources
        )
    }

    private struct FrameFileRow {
        var id: Int64
        var timestampMs: Int64
        var imagePath: String?
        var videoID: Int64?
    }

    private func selectedFrames(
        selection: LibraryDeletionSelection,
        store: Store
    ) throws -> [FrameFileRow] {
        let sql: String
        let bounds: (Int64, Int64)?
        let frameID: Int64?
        switch selection {
        case .moment(let id):
            sql = """
                SELECT id, timestamp, image_path, video
                FROM frame
                WHERE timestamp = (SELECT timestamp FROM frame WHERE id = ?)
                ORDER BY id
                """
            bounds = nil
            frameID = id
        case .timeRange(let start, let end), .today(let start, let end):
            guard start < end else { throw LibraryDeletionError.invalidRange }
            sql = "SELECT id, timestamp, image_path, video FROM frame WHERE timestamp >= ? AND timestamp < ? ORDER BY id"
            bounds = (start, end)
            frameID = nil
        case .entireLibrary:
            sql = "SELECT id, timestamp, image_path, video FROM frame ORDER BY id"
            bounds = nil
            frameID = nil
        }
        let stmt = try store.db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        if let frameID { SQLiteBind.int64(stmt, 1, frameID) }
        if let bounds {
            SQLiteBind.int64(stmt, 1, bounds.0)
            SQLiteBind.int64(stmt, 2, bounds.1)
        }
        return readFrames(stmt)
    }

    private func frames(videoIDs: [Int64], store: Store) throws -> [FrameFileRow] {
        var result: [FrameFileRow] = []
        for ids in videoIDs.chunked(maxCount: 400) {
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let stmt = try store.db.prepare(
                "SELECT id, timestamp, image_path, video FROM frame WHERE video IN (\(placeholders)) ORDER BY id"
            )
            defer { sqlite3_finalize(stmt) }
            for (index, id) in ids.enumerated() { SQLiteBind.int64(stmt, Int32(index + 1), id) }
            result.append(contentsOf: readFrames(stmt))
        }
        return result
    }

    private func readFrames(_ stmt: OpaquePointer) -> [FrameFileRow] {
        var result: [FrameFileRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(
                FrameFileRow(
                    id: SQLiteColumn.int64(stmt, 0),
                    timestampMs: SQLiteColumn.int64(stmt, 1),
                    imagePath: SQLiteColumn.text(stmt, 2),
                    videoID: SQLiteColumn.int64Optional(stmt, 3)
                )
            )
        }
        return result
    }

    private struct VideoFileRow { var path: String }

    private func allVideoIDs(store: Store) throws -> [Int64] {
        let stmt = try store.db.prepare("SELECT id FROM video ORDER BY id")
        defer { sqlite3_finalize(stmt) }
        var result: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { result.append(SQLiteColumn.int64(stmt, 0)) }
        return result
    }

    private func videos(ids: [Int64], store: Store) throws -> [VideoFileRow] {
        guard !ids.isEmpty else { return [] }
        var result: [VideoFileRow] = []
        for chunk in ids.chunked(maxCount: 400) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try store.db.prepare("SELECT path FROM video WHERE id IN (\(placeholders)) ORDER BY id")
            defer { sqlite3_finalize(stmt) }
            for (index, id) in chunk.enumerated() { SQLiteBind.int64(stmt, Int32(index + 1), id) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let path = SQLiteColumn.text(stmt, 0) { result.append(VideoFileRow(path: path)) }
            }
        }
        return result
    }

    private func resource(
        path: String,
        kind: DeletionResourceKind,
        store: Store
    ) throws -> DeletionResource {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let managedRoot = (kind == .frame ? store.framesDirectory : ScreenlogPaths.videosDirectory(root: store.root))
            .resolvingSymlinksInPath().standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let prefix = managedRoot.path.hasSuffix("/") ? managedRoot.path : managedRoot.path + "/"
        let isManaged = resolved.path.hasPrefix(prefix)
        guard isManaged else {
            return DeletionResource(path: url.path, kind: kind, isManaged: false, exists: fileSystem.fileExists(at: url), sizeBytes: 0)
        }
        let exists = fileSystem.fileExists(at: url)
        guard exists else {
            return DeletionResource(path: url.path, kind: kind, isManaged: true, exists: false, sizeBytes: 0)
        }
        let attributes = try fileSystem.attributes(at: url)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LibraryDeletionError.unsafeManagedPath(path)
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return DeletionResource(path: url.path, kind: kind, isManaged: true, exists: true, sizeBytes: size)
    }

    private func installFrameIDs(_ ids: [Int64], store: Store) throws {
        try store.db.exec("CREATE TEMP TABLE IF NOT EXISTS deletion_frame_ids (id INTEGER PRIMARY KEY)")
        try store.db.exec("DELETE FROM deletion_frame_ids")
        let stmt = try store.db.prepare("INSERT INTO deletion_frame_ids(id) VALUES(?)")
        defer { sqlite3_finalize(stmt) }
        for id in ids {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            SQLiteBind.int64(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw SQLiteError.step("install deletion frame ids failed")
            }
        }
    }

    private func deleteVideos(_ ids: [Int64], store: Store) throws {
        for chunk in ids.chunked(maxCount: 400) {
            let list = chunk.map(String.init).joined(separator: ",")
            try store.db.exec("DELETE FROM video WHERE id IN (\(list))")
        }
    }

    private func repairSegments(store: Store) throws {
        try store.db.exec(
            """
            UPDATE segment
            SET start_frame_id = (SELECT MIN(frame.id) FROM frame WHERE frame.segment = segment.id)
            WHERE EXISTS (SELECT 1 FROM frame WHERE frame.segment = segment.id)
              AND NOT EXISTS (SELECT 1 FROM frame WHERE frame.segment = segment.id AND frame.id = segment.start_frame_id)
            """
        )
        try store.db.exec("DELETE FROM segment WHERE NOT EXISTS (SELECT 1 FROM frame WHERE frame.segment = segment.id)")
    }

    private func pruneAXOrphans(store: Store) throws {
        try store.db.exec("UPDATE ax_node SET first_seen_frame_id = NULL WHERE first_seen_frame_id NOT IN (SELECT id FROM frame)")
        try store.db.exec(
            """
            WITH RECURSIVE reachable(hash) AS (
                SELECT root_hash FROM ax_snapshot
                UNION
                SELECT edge.child_hash
                FROM ax_node_edge AS edge JOIN reachable ON edge.parent_hash = reachable.hash
            )
            DELETE FROM ax_node_edge
            WHERE parent_hash NOT IN (SELECT hash FROM reachable)
               OR child_hash NOT IN (SELECT hash FROM reachable)
            """
        )
        try store.db.exec(
            """
            DELETE FROM ax_node
            WHERE hash NOT IN (SELECT root_hash FROM ax_snapshot)
              AND hash NOT IN (SELECT parent_hash FROM ax_node_edge)
              AND hash NOT IN (SELECT child_hash FROM ax_node_edge)
            """
        )
    }

    private func pruneCatalogOrphans(store: Store) throws {
        try store.db.exec(
            """
            DELETE FROM application
            WHERE NOT EXISTS (
                SELECT 1 FROM segment WHERE segment.application = application.id
            )
              AND NOT EXISTS (
                SELECT 1 FROM window_bound WHERE window_bound.application = application.id
            )
            """
        )
        try store.db.exec(
            """
            DELETE FROM domain
            WHERE NOT EXISTS (
                SELECT 1 FROM segment WHERE segment.domain = domain.id
            )
            """
        )
    }

    private func restore(manifest: DeletionManifest, committed: Bool) throws {
        for entry in manifest.entries {
            let original = URL(fileURLWithPath: entry.originalPath)
            let backup = URL(fileURLWithPath: entry.backupPath)
            if committed {
                if fileSystem.fileExists(at: backup) { try fileSystem.removeItem(at: backup) }
            } else if !fileSystem.fileExists(at: original), fileSystem.fileExists(at: backup) {
                try fileSystem.moveItem(at: backup, to: original)
            } else if fileSystem.fileExists(at: backup) {
                try fileSystem.removeItem(at: backup)
            }
        }
    }

    private func recoveryRoot(store: Store) -> URL {
        store.root.appendingPathComponent(".deletion-recovery", isDirectory: true)
    }

    private func validateRecoveryManifest(
        _ manifest: DeletionManifest,
        operationDirectory: URL,
        store: Store
    ) throws {
        let frames = store.framesDirectory
        let videos = ScreenlogPaths.videosDirectory(root: store.root)
        let files = operationDirectory.appendingPathComponent("files", isDirectory: true)
        for entry in manifest.entries {
            let original = URL(fileURLWithPath: entry.originalPath)
            let backup = URL(fileURLWithPath: entry.backupPath)
            guard isDescendant(original, of: frames) || isDescendant(original, of: videos),
                isDescendant(backup, of: files)
            else {
                throw LibraryDeletionError.recoveryFailed("Manifest contains an unmanaged path")
            }
        }
    }

    private func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
        let resolvedChild = child.resolvingSymlinksInPath().standardizedFileURL
        let prefix = resolvedParent.path.hasSuffix("/") ? resolvedParent.path : resolvedParent.path + "/"
        return resolvedChild.path.hasPrefix(prefix)
    }
}

extension Array {
    fileprivate func chunked(maxCount: Int) -> [ArraySlice<Element>] {
        guard !isEmpty else { return [] }
        var result: [ArraySlice<Element>] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: maxCount, limitedBy: endIndex) ?? endIndex
            result.append(self[index..<end])
            index = end
        }
        return result
    }
}
