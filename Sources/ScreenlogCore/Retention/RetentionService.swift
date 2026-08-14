import Foundation
import OSLog
import SQLite3

private let log = Logger(subsystem: "dev.screenlog", category: "retention")

extension Notification.Name {
    /// Posted in-process after a retention run has made captured pixels
    /// unavailable. Metadata remains searchable.
    public static let screenlogRetentionDidPurgeMedia = Notification.Name(
        "dev.screenlog.retention-did-purge-media"
    )
}

public struct RetentionPolicy: Sendable, Codable, Equatable {
    /// Remove capture media older than this many days while retaining searchable metadata.
    public var retentionDays: Int
    /// Soft cap on the entire managed library (MB). 0 = disabled.
    public var storageCapMB: Int64
    /// When over cap: remove the oldest capture pixels first.
    public var deleteOldestWhenOverCap: Bool

    public init(retentionDays: Int = 30, storageCapMB: Int64 = 50_000, deleteOldestWhenOverCap: Bool = true) {
        self.retentionDays = retentionDays
        self.storageCapMB = storageCapMB
        self.deleteOldestWhenOverCap = deleteOldestWhenOverCap
    }

    public static let `default` = RetentionPolicy()
}

public struct RetentionRunReport: Sendable, Equatable, CustomStringConvertible {
    public var purgedVideoCount: Int
    public var purgedStillCount: Int
    public var failedVideoCount: Int
    public var failedStillCount: Int
    public var missingFileCount: Int
    public var freedBytes: Int64
    public var libraryBytesBeforeCap: Int64
    public var libraryBytesAfterCap: Int64
    public var capBytes: Int64
    public var capSatisfied: Bool
    public var cutoffMs: Int64
    public var failureDetails: [String]

    public var hasFailures: Bool { failedVideoCount > 0 || failedStillCount > 0 }

    public var description: String {
        "retention purged_videos=\(purgedVideoCount) purged_stills=\(purgedStillCount) failed_videos=\(failedVideoCount) failed_stills=\(failedStillCount) missing_files=\(missingFileCount) freed_bytes=\(freedBytes) library_bytes_before=\(libraryBytesBeforeCap) library_bytes_after=\(libraryBytesAfterCap) cap_bytes=\(capBytes) cap_satisfied=\(capSatisfied) cutoff_ms=\(cutoffMs)"
    }
}

/// Read-only estimate of the media a retention run would remove for a policy.
///
/// The estimate measures current files rather than trusting database sizes. It
/// never changes Library files or metadata, and callers should still describe
/// its values as estimates because capture can continue while it is prepared.
public struct RetentionPreflightReport: Sendable, Equatable {
    public var policy: RetentionPolicy
    public var measuredAt: Date
    public var cutoffMs: Int64
    public var libraryBytes: Int64
    public var projectedLibraryBytes: Int64
    public var estimatedReclaimableBytes: Int64
    public var selectedMediaCount: Int
    /// Selected database records whose file is missing, outside the managed
    /// folders, or not a regular file. These contribute no reclaimable bytes.
    public var unavailableMediaCount: Int
    public var capBytes: Int64?
    public var capSatisfiedAfterEstimate: Bool?

    public init(
        policy: RetentionPolicy,
        measuredAt: Date,
        cutoffMs: Int64,
        libraryBytes: Int64,
        projectedLibraryBytes: Int64,
        estimatedReclaimableBytes: Int64,
        selectedMediaCount: Int,
        unavailableMediaCount: Int,
        capBytes: Int64?,
        capSatisfiedAfterEstimate: Bool?
    ) {
        self.policy = policy
        self.measuredAt = measuredAt
        self.cutoffMs = cutoffMs
        self.libraryBytes = libraryBytes
        self.projectedLibraryBytes = projectedLibraryBytes
        self.estimatedReclaimableBytes = estimatedReclaimableBytes
        self.selectedMediaCount = selectedMediaCount
        self.unavailableMediaCount = unavailableMediaCount
        self.capBytes = capBytes
        self.capSatisfiedAfterEstimate = capSatisfiedAfterEstimate
    }
}

/// Narrow filesystem surface used to make retention failures deterministic in tests.
protocol RetentionFileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func attributes(at url: URL) throws -> [FileAttributeKey: Any]
    func createDirectory(at url: URL) throws
    func linkItem(at source: URL, to destination: URL) throws
    func copyItem(at source: URL, to destination: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
}

private struct LocalRetentionFileSystem: RetentionFileSystem {
    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: url.path)
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

private enum RetentionPurgeError: Error, CustomStringConvertible {
    case invalidFramePath(frameID: Int64)
    case unmanagedFramePath(frameID: Int64)
    case nonRegularFrameFile(frameID: Int64)
    case frameRecoveryCreation(frameID: Int64, linkError: Error, copyError: Error)
    case frameOperation(frameID: Int64, operation: String, underlying: Error)
    case frameRollback(frameID: Int64, operationError: Error, rollbackError: Error)
    case invalidPath(videoID: Int64)
    case unmanagedPath(videoID: Int64)
    case notRegularFile(videoID: Int64)
    case recoveryCreation(videoID: Int64, linkError: Error, copyError: Error)
    case operation(videoID: Int64, operation: String, underlying: Error)
    case rollback(videoID: Int64, operationError: Error, rollbackError: Error)

    var description: String {
        switch self {
        case .invalidFramePath(let id):
            return "frame_id=\(id) operation=validate reason=missing_path"
        case .unmanagedFramePath(let id):
            return "frame_id=\(id) operation=validate reason=outside_frames_directory"
        case .nonRegularFrameFile(let id):
            return "frame_id=\(id) operation=validate reason=not_regular_file"
        case .frameRecoveryCreation(let id, let linkError, let copyError):
            return "frame_id=\(id) operation=create_recovery link_error=\(Self.clean(linkError)) copy_error=\(Self.clean(copyError))"
        case .frameOperation(let id, let operation, let error):
            return "frame_id=\(id) operation=\(operation) error=\(Self.clean(error))"
        case .frameRollback(let id, let operationError, let rollbackError):
            return
                "frame_id=\(id) operation=rollback original_error=\(Self.clean(operationError)) rollback_error=\(Self.clean(rollbackError))"
        case .invalidPath(let id):
            return "video_id=\(id) operation=validate reason=missing_path"
        case .unmanagedPath(let id):
            return "video_id=\(id) operation=validate reason=outside_videos_directory"
        case .notRegularFile(let id):
            return "video_id=\(id) operation=validate reason=not_regular_file"
        case .recoveryCreation(let id, let linkError, let copyError):
            return "video_id=\(id) operation=create_recovery link_error=\(Self.clean(linkError)) copy_error=\(Self.clean(copyError))"
        case .operation(let id, let operation, let error):
            return "video_id=\(id) operation=\(operation) error=\(Self.clean(error))"
        case .rollback(let id, let operationError, let rollbackError):
            return
                "video_id=\(id) operation=rollback original_error=\(Self.clean(operationError)) rollback_error=\(Self.clean(rollbackError))"
        }
    }

    private static func clean(_ error: Error) -> String {
        String(describing: error)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

private struct PurgeResult {
    var freedBytes: Int64
    var wasMissing: Bool
}

/// Logical bytes inside Screenlogger's managed data root. This deliberately includes
/// the database, stills, videos, and recovery data so the configured cap matches what
/// users see on disk. Only database-owned capture files are eligible for eviction.
public enum ManagedLibraryStorage {
    public static func byteSize(root: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants]
            )
        else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: keys)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            } catch {
                throw error
            }
            guard values.isRegularFile == true, let size = values.fileSize else { continue }
            let addition = total.addingReportingOverflow(Int64(size))
            total = addition.overflow ? Int64.max : addition.partialValue
        }
        return total
    }
}

/// Local age and whole-library storage-cap retention.
public final class RetentionService: @unchecked Sendable {
    public var policy: RetentionPolicy
    private let fileSystem: any RetentionFileSystem

    public init(policy: RetentionPolicy = .default) {
        self.policy = policy
        self.fileSystem = LocalRetentionFileSystem()
    }

    init(policy: RetentionPolicy = .default, fileSystem: any RetentionFileSystem) {
        self.policy = policy
        self.fileSystem = fileSystem
    }

    @discardableResult
    public func run(store: Store) throws -> String {
        try runDetailed(store: store).description
    }

    @discardableResult
    public func runDetailed(store: Store) throws -> RetentionRunReport {
        var didPurgeMedia = false
        defer {
            if didPurgeMedia {
                NotificationCenter.default.post(name: .screenlogRetentionDidPurgeMedia, object: store)
            }
        }

        return try store.withExclusiveMaintenance {
            try runExclusively(store: store) {
                didPurgeMedia = true
            }
        }
    }

    /// Calculates the current scope of a retention run without deleting or
    /// updating anything. The same age and oldest-first ordering as `run` is
    /// used so Settings can preview consequences before confirmation.
    public func preflight(store: Store, now: Date = Date()) throws -> RetentionPreflightReport {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let retentionDays = max(0, policy.retentionDays)
        let dayMilliseconds = Int64(retentionDays).multipliedReportingOverflow(by: 86_400_000)
        let cutoff = dayMilliseconds.overflow ? Int64.min : nowMs - dayMilliseconds.partialValue
        let libraryBytes = try ManagedLibraryStorage.byteSize(root: store.root)

        let allCandidates = try store.retentionCandidatesByOldestFrame()
        let agedStills = try store.stillRetentionCandidates(olderThan: cutoff)
        let agedVideos = try store.videosOlderThan(newestTimestampMs: cutoff).map {
            RetentionCandidate(
                kind: .video,
                id: $0.id,
                timestampMs: 0,
                path: $0.path,
                sizeBytes: $0.sizeBytes
            )
        }

        var selected = Set<RetentionCandidateIdentifier>()
        var selectedMediaCount = 0
        var unavailableMediaCount = 0
        var reclaimableBytes: Int64 = 0
        var projectedBytes = libraryBytes

        func select(_ candidate: RetentionCandidate) {
            let identifier = RetentionCandidateIdentifier(kind: candidate.kind, id: candidate.id)
            guard selected.insert(identifier).inserted else { return }
            selectedMediaCount += 1
            guard let bytes = reclaimableByteSize(for: candidate, store: store) else {
                unavailableMediaCount += 1
                return
            }
            let accumulated = reclaimableBytes.addingReportingOverflow(bytes)
            reclaimableBytes = accumulated.overflow ? Int64.max : accumulated.partialValue
            projectedBytes = max(0, projectedBytes - bytes)
        }

        for candidate in agedStills { select(candidate) }
        for candidate in agedVideos { select(candidate) }

        var capBytes: Int64?
        var capSatisfiedAfterEstimate: Bool?
        if policy.storageCapMB > 0, policy.deleteOldestWhenOverCap {
            let product = policy.storageCapMB.multipliedReportingOverflow(by: 1_000_000)
            let effectiveCap = product.overflow ? Int64.max : product.partialValue
            capBytes = effectiveCap
            if projectedBytes > effectiveCap {
                for candidate in allCandidates where projectedBytes > effectiveCap {
                    select(candidate)
                }
            }
            capSatisfiedAfterEstimate = projectedBytes <= effectiveCap
        }

        return RetentionPreflightReport(
            policy: policy,
            measuredAt: now,
            cutoffMs: cutoff,
            libraryBytes: libraryBytes,
            projectedLibraryBytes: projectedBytes,
            estimatedReclaimableBytes: reclaimableBytes,
            selectedMediaCount: selectedMediaCount,
            unavailableMediaCount: unavailableMediaCount,
            capBytes: capBytes,
            capSatisfiedAfterEstimate: capSatisfiedAfterEstimate
        )
    }

    private func runExclusively(
        store: Store,
        didPurgeMedia: () -> Void
    ) throws -> RetentionRunReport {
        var purgedVideos = 0
        var purgedStills = 0
        var failedVideos = 0
        var failedStills = 0
        var missingFiles = 0
        var freedBytes: Int64 = 0
        var attemptedVideoIDs = Set<Int64>()
        var attemptedStillIDs = Set<Int64>()
        var failures: [String] = []
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let retentionDays = max(0, policy.retentionDays)
        let cutoff = nowMs - Int64(retentionDays) * 86_400_000

        func attempt(_ video: VideoRow) -> Bool {
            guard attemptedVideoIDs.insert(video.id).inserted else { return false }
            do {
                let result = try purge(video: video, store: store, didCommitUnavailable: didPurgeMedia)
                purgedVideos += 1
                freedBytes += result.freedBytes
                if result.wasMissing { missingFiles += 1 }
                return true
            } catch {
                failedVideos += 1
                let detail = String(describing: error)
                failures.append(detail)
                log.error("Retention failed: \(detail, privacy: .private(mask: .hash))")
                return false
            }
        }

        func attempt(_ still: RetentionCandidate) -> Bool {
            guard attemptedStillIDs.insert(still.id).inserted else { return false }
            do {
                let result = try purge(still: still, store: store, didCommitUnavailable: didPurgeMedia)
                purgedStills += 1
                freedBytes += result.freedBytes
                if result.wasMissing { missingFiles += 1 }
                return true
            } catch {
                failedStills += 1
                let detail = String(describing: error)
                failures.append(detail)
                log.error("Retention failed: \(detail, privacy: .private(mask: .hash))")
                return false
            }
        }

        // Age-based purge applies to stills and compacted videos. Videos are only
        // eligible once every frame they contain is older than the cutoff.
        for still in try store.stillRetentionCandidates(olderThan: cutoff) {
            _ = attempt(still)
        }
        let aged = try store.videosOlderThan(newestTimestampMs: cutoff)
        for video in aged {
            _ = attempt(video)
        }

        var libraryBytesBefore: Int64 = 0
        var libraryBytesAfter: Int64 = 0
        var effectiveCap: Int64 = 0
        var capSatisfied = true

        // Storage-cap purge. The complete managed root is measured, while eviction is
        // restricted to DB-owned stills and videos in Screenlogger's managed folders.
        // Failed age attempts are not retried twice in one run.
        if policy.storageCapMB > 0, policy.deleteOldestWhenOverCap {
            let capBytes = policy.storageCapMB.multipliedReportingOverflow(by: 1_000_000)
            effectiveCap = capBytes.overflow ? Int64.max : capBytes.partialValue
            libraryBytesBefore = try ManagedLibraryStorage.byteSize(root: store.root)
            libraryBytesAfter = libraryBytesBefore
            if libraryBytesAfter > effectiveCap {
                let candidates = try store.retentionCandidatesByOldestFrame()
                for candidate in candidates {
                    if libraryBytesAfter <= effectiveCap { break }
                    switch candidate.kind {
                    case .still:
                        _ = attempt(candidate)
                    case .video:
                        _ = attempt(
                            VideoRow(
                                id: candidate.id,
                                path: candidate.path,
                                sizeBytes: candidate.sizeBytes,
                                status: 0
                            )
                        )
                    }
                    libraryBytesAfter = try ManagedLibraryStorage.byteSize(root: store.root)
                }
            }
            capSatisfied = libraryBytesAfter <= effectiveCap
        }

        let report = RetentionRunReport(
            purgedVideoCount: purgedVideos,
            purgedStillCount: purgedStills,
            failedVideoCount: failedVideos,
            failedStillCount: failedStills,
            missingFileCount: missingFiles,
            freedBytes: freedBytes,
            libraryBytesBeforeCap: libraryBytesBefore,
            libraryBytesAfterCap: libraryBytesAfter,
            capBytes: effectiveCap,
            capSatisfied: capSatisfied,
            cutoffMs: cutoff,
            failureDetails: failures
        )
        log.info("\(report.description, privacy: .public)")
        try store.setMeta(key: "last_retention_report", value: report.description)
        try store.setMeta(key: "last_retention_errors", value: failures.joined(separator: "\n"))
        return report
    }

    private func purge(
        still: RetentionCandidate,
        store: Store,
        didCommitUnavailable: () -> Void
    ) throws -> PurgeResult {
        guard let path = still.path, !path.isEmpty else {
            throw RetentionPurgeError.invalidFramePath(frameID: still.id)
        }

        let originalURL = URL(fileURLWithPath: path).standardizedFileURL
        try validateManagedFramePath(originalURL, frameID: still.id, store: store)
        let recoveryDirectory = store.framesDirectory
            .appendingPathComponent(".retention-recovery", isDirectory: true)
        let pathExtension = originalURL.pathExtension.isEmpty ? "capture" : originalURL.pathExtension
        let primaryRecoveryURL =
            recoveryDirectory
            .appendingPathComponent("frame-\(still.id).\(pathExtension)", isDirectory: false)
        let alternateRecoveryURL =
            recoveryDirectory
            .appendingPathComponent("frame-\(still.id)-retry.\(pathExtension)", isDirectory: false)
        let recoveryURL =
            originalURL == primaryRecoveryURL.standardizedFileURL
            ? alternateRecoveryURL
            : primaryRecoveryURL
        try fileSystem.createDirectory(at: recoveryDirectory)

        if !fileSystem.fileExists(at: originalURL), fileSystem.fileExists(at: recoveryURL) {
            do {
                try fileSystem.moveItem(at: recoveryURL, to: originalURL)
            } catch {
                throw RetentionPurgeError.frameOperation(
                    frameID: still.id,
                    operation: "restore_interrupted_delete",
                    underlying: error
                )
            }
        }

        guard fileSystem.fileExists(at: originalURL) else {
            do {
                try store.markFrameImagePurged(id: still.id, expectedPath: path)
                didCommitUnavailable()
            } catch {
                throw RetentionPurgeError.frameOperation(
                    frameID: still.id,
                    operation: "mark_missing_file_purged",
                    underlying: error
                )
            }
            return PurgeResult(freedBytes: 0, wasMissing: true)
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileSystem.attributes(at: originalURL)
        } catch {
            throw RetentionPurgeError.frameOperation(
                frameID: still.id,
                operation: "read_attributes",
                underlying: error
            )
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw RetentionPurgeError.nonRegularFrameFile(frameID: still.id)
        }
        let actualBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        if fileSystem.fileExists(at: recoveryURL) {
            do {
                try fileSystem.removeItem(at: recoveryURL)
            } catch {
                throw RetentionPurgeError.frameOperation(
                    frameID: still.id,
                    operation: "remove_stale_recovery",
                    underlying: error
                )
            }
        }
        do {
            try fileSystem.linkItem(at: originalURL, to: recoveryURL)
        } catch let linkError {
            do {
                try fileSystem.copyItem(at: originalURL, to: recoveryURL)
            } catch let copyError {
                throw RetentionPurgeError.frameRecoveryCreation(
                    frameID: still.id,
                    linkError: linkError,
                    copyError: copyError
                )
            }
        }

        do {
            try store.db.transaction {
                try store.markFrameImagePurged(id: still.id, expectedPath: path)
                try fileSystem.removeItem(at: originalURL)
            }
            didCommitUnavailable()
        } catch {
            do {
                try restoreAfterFailedTransaction(originalURL: originalURL, recoveryURL: recoveryURL)
            } catch let rollbackError {
                throw RetentionPurgeError.frameRollback(
                    frameID: still.id,
                    operationError: error,
                    rollbackError: rollbackError
                )
            }
            throw RetentionPurgeError.frameOperation(
                frameID: still.id,
                operation: "delete_transaction",
                underlying: error
            )
        }

        do {
            try fileSystem.removeItem(at: recoveryURL)
        } catch {
            do {
                try store.restoreFrameImageForRetentionRetry(id: still.id, path: recoveryURL.path)
            } catch let databaseError {
                throw RetentionPurgeError.frameRollback(
                    frameID: still.id,
                    operationError: error,
                    rollbackError: databaseError
                )
            }
            throw RetentionPurgeError.frameOperation(
                frameID: still.id,
                operation: "remove_recovery",
                underlying: error
            )
        }
        return PurgeResult(freedBytes: actualBytes, wasMissing: false)
    }

    private func purge(
        video: VideoRow,
        store: Store,
        didCommitUnavailable: () -> Void
    ) throws -> PurgeResult {
        guard let path = video.path, !path.isEmpty else {
            throw RetentionPurgeError.invalidPath(videoID: video.id)
        }

        let originalURL = URL(fileURLWithPath: path).standardizedFileURL
        try validateManagedPath(originalURL, videoID: video.id, store: store)

        let recoveryDirectory = ScreenlogPaths.videosDirectory(root: store.root)
            .appendingPathComponent(".retention-recovery", isDirectory: true)
        let primaryRecoveryURL =
            recoveryDirectory
            .appendingPathComponent("video-\(video.id).mp4", isDirectory: false)
        let alternateRecoveryURL =
            recoveryDirectory
            .appendingPathComponent("video-\(video.id)-retry.mp4", isDirectory: false)
        let recoveryURL =
            originalURL == primaryRecoveryURL.standardizedFileURL
            ? alternateRecoveryURL
            : primaryRecoveryURL
        try fileSystem.createDirectory(at: recoveryDirectory)

        // Recover a transaction interrupted after removing the canonical path.
        if !fileSystem.fileExists(at: originalURL), fileSystem.fileExists(at: recoveryURL) {
            do {
                try fileSystem.moveItem(at: recoveryURL, to: originalURL)
            } catch {
                throw RetentionPurgeError.operation(
                    videoID: video.id,
                    operation: "restore_interrupted_delete",
                    underlying: error
                )
            }
        }

        // A genuinely absent file is already gone. Reconcile the stale active DB row,
        // but do not claim that this run freed its recorded size.
        guard fileSystem.fileExists(at: originalURL) else {
            do {
                try store.markVideoPurged(id: video.id)
                didCommitUnavailable()
            } catch {
                throw RetentionPurgeError.operation(
                    videoID: video.id,
                    operation: "mark_missing_file_purged",
                    underlying: error
                )
            }
            return PurgeResult(freedBytes: 0, wasMissing: true)
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileSystem.attributes(at: originalURL)
        } catch {
            throw RetentionPurgeError.operation(
                videoID: video.id,
                operation: "read_attributes",
                underlying: error
            )
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw RetentionPurgeError.notRegularFile(videoID: video.id)
        }
        let actualBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        // Remove a stale recovery link only while the canonical file is known-good.
        if fileSystem.fileExists(at: recoveryURL) {
            do {
                try fileSystem.removeItem(at: recoveryURL)
            } catch {
                throw RetentionPurgeError.operation(
                    videoID: video.id,
                    operation: "remove_stale_recovery",
                    underlying: error
                )
            }
        }

        do {
            try fileSystem.linkItem(at: originalURL, to: recoveryURL)
        } catch let linkError {
            do {
                try fileSystem.copyItem(at: originalURL, to: recoveryURL)
            } catch let copyError {
                throw RetentionPurgeError.recoveryCreation(
                    videoID: video.id,
                    linkError: linkError,
                    copyError: copyError
                )
            }
        }

        do {
            try store.db.transaction {
                try store.markVideoPurged(id: video.id)
                try fileSystem.removeItem(at: originalURL)
            }
            didCommitUnavailable()
        } catch {
            do {
                try restoreAfterFailedTransaction(originalURL: originalURL, recoveryURL: recoveryURL)
            } catch let rollbackError {
                throw RetentionPurgeError.rollback(
                    videoID: video.id,
                    operationError: error,
                    rollbackError: rollbackError
                )
            }
            throw RetentionPurgeError.operation(
                videoID: video.id,
                operation: "delete_transaction",
                underlying: error
            )
        }

        do {
            try fileSystem.removeItem(at: recoveryURL)
        } catch {
            // The bytes still exist. Re-activate the row at the recovery path so the
            // next run can retry and frame extraction remains possible.
            do {
                try store.restoreVideoForRetentionRetry(
                    id: video.id,
                    path: recoveryURL.path,
                    sizeBytes: video.sizeBytes ?? actualBytes
                )
            } catch let databaseError {
                throw RetentionPurgeError.rollback(
                    videoID: video.id,
                    operationError: error,
                    rollbackError: databaseError
                )
            }
            throw RetentionPurgeError.operation(
                videoID: video.id,
                operation: "remove_recovery",
                underlying: error
            )
        }

        return PurgeResult(freedBytes: actualBytes, wasMissing: false)
    }

    private func restoreAfterFailedTransaction(originalURL: URL, recoveryURL: URL) throws {
        if fileSystem.fileExists(at: originalURL) {
            if fileSystem.fileExists(at: recoveryURL) {
                try fileSystem.removeItem(at: recoveryURL)
            }
        } else if fileSystem.fileExists(at: recoveryURL) {
            try fileSystem.moveItem(at: recoveryURL, to: originalURL)
        }
    }

    private func reclaimableByteSize(for candidate: RetentionCandidate, store: Store) -> Int64? {
        guard let path = candidate.path, !path.isEmpty else { return nil }
        let originalURL = URL(fileURLWithPath: path).standardizedFileURL
        let managedDirectory: URL
        switch candidate.kind {
        case .still:
            managedDirectory = store.framesDirectory
        case .video:
            managedDirectory = ScreenlogPaths.videosDirectory(root: store.root)
        }
        let resolvedDirectory = managedDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = originalURL.resolvingSymlinksInPath().standardizedFileURL
        let prefix =
            resolvedDirectory.path.hasSuffix("/")
            ? resolvedDirectory.path
            : resolvedDirectory.path + "/"
        guard resolvedURL.path.hasPrefix(prefix), fileSystem.fileExists(at: originalURL),
            let attributes = try? fileSystem.attributes(at: originalURL),
            attributes[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        return max(0, (attributes[.size] as? NSNumber)?.int64Value ?? 0)
    }

    private func validateManagedPath(_ url: URL, videoID: Int64, store: Store) throws {
        let videosDirectory = ScreenlogPaths.videosDirectory(root: store.root)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let prefix =
            videosDirectory.path.hasSuffix("/")
            ? videosDirectory.path
            : videosDirectory.path + "/"
        guard resolvedURL.path.hasPrefix(prefix) else {
            throw RetentionPurgeError.unmanagedPath(videoID: videoID)
        }
    }

    private func validateManagedFramePath(_ url: URL, frameID: Int64, store: Store) throws {
        let framesDirectory = store.framesDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let prefix =
            framesDirectory.path.hasSuffix("/")
            ? framesDirectory.path
            : framesDirectory.path + "/"
        guard resolvedURL.path.hasPrefix(prefix) else {
            throw RetentionPurgeError.unmanagedFramePath(frameID: frameID)
        }
    }
}

enum RetentionCandidateKind: Int, Sendable {
    case still = 0
    case video = 1
}

struct RetentionCandidate: Sendable {
    var kind: RetentionCandidateKind
    var id: Int64
    var timestampMs: Int64
    var path: String?
    var sizeBytes: Int64?
}

private struct RetentionCandidateIdentifier: Hashable {
    var kind: RetentionCandidateKind
    var id: Int64
}

public struct VideoRow: Sendable {
    public var id: Int64
    public var path: String?
    public var sizeBytes: Int64?
    public var status: Int
}
