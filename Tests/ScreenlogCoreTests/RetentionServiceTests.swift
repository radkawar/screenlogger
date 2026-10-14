import SQLite3
import XCTest

@testable import ScreenlogCore

final class RetentionServiceTests: XCTestCase {
    var tempRoot: URL!
    var store: Store!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = try Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testRunNotifiesVisiblePreviewConsumersAfterPurgingMedia() throws {
        _ = try insertStill(timestampMs: 1_600_000_000_000, foreground: "old", byteCount: 64)
        let notified = expectation(description: "retained preview media changed")
        let token = NotificationCenter.default.addObserver(
            forName: .screenlogRetentionDidPurgeMedia,
            object: store,
            queue: nil
        ) { _ in
            notified.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let report = try RetentionService(
            policy: RetentionPolicy(retentionDays: 30, storageCapMB: 0)
        ).runDetailed(store: store)

        XCTAssertEqual(report.purgedStillCount, 1)
        wait(for: [notified], timeout: 0.2)
    }

    func testRunStillNotifiesWhenBookkeepingFailsAfterCommittedPurge() throws {
        let frameID = try insertStill(
            timestampMs: 1_600_000_000_000,
            foreground: "old",
            byteCount: 64
        )
        let notified = expectation(description: "committed purge remains visible")
        let token = NotificationCenter.default.addObserver(
            forName: .screenlogRetentionDidPurgeMedia,
            object: store,
            queue: nil
        ) { _ in
            notified.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try store.db.exec(
            """
            CREATE TRIGGER fail_retention_report
            BEFORE INSERT ON metadata
            WHEN NEW.key = 'last_retention_report'
            BEGIN
                SELECT RAISE(ABORT, 'forced bookkeeping failure');
            END;
            """
        )

        XCTAssertThrowsError(
            try RetentionService(
                policy: RetentionPolicy(retentionDays: 30, storageCapMB: 0)
            ).runDetailed(store: store)
        )
        wait(for: [notified], timeout: 0.2)
        XCTAssertNil(try imagePathOptional(frameID: frameID))
    }

    /// Retention must delete on-disk video files (not only mark DB status).
    func testRunDeletesAgedVideoFilesFromDisk() throws {
        let videosDir = tempRoot.appendingPathComponent("videos", isDirectory: true)
        try FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)

        // Old video file that should be purged (frame max ts older than retention window).
        let oldPath = videosDir.appendingPathComponent("old-clip.mp4").path
        let oldBytes = Data(repeating: 0xAB, count: 4_096)
        try oldBytes.write(to: URL(fileURLWithPath: oldPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldPath))

        let oldVideoID = try store.insertVideo(path: oldPath, numFrames: 2, sizeBytes: Int64(oldBytes.count))
        // Frame timestamps far in the past (2020).
        let oldFrameID = try store.insertSeedFrame(
            timestampMs: 1_600_000_000_000,
            foreground: "old retained content"
        )
        try store.attachFrame(id: oldFrameID, videoID: oldVideoID, videoIndex: 0)

        // Recent video that must survive (within retention days).
        let recentPath = videosDir.appendingPathComponent("recent-clip.mp4").path
        let recentBytes = Data(repeating: 0xCD, count: 2_048)
        try recentBytes.write(to: URL(fileURLWithPath: recentPath))
        let recentVideoID = try store.insertVideo(
            path: recentPath,
            numFrames: 1,
            sizeBytes: Int64(recentBytes.count)
        )
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let recentFrameID = try store.insertSeedFrame(
            timestampMs: nowMs - 3_600_000,
            foreground: "recent content"
        )
        try store.attachFrame(id: recentFrameID, videoID: recentVideoID, videoIndex: 0)

        let policy = RetentionPolicy(
            retentionDays: 30,
            storageCapMB: 0,  // disable cap path - age only
            deleteOldestWhenOverCap: false
        )
        let report = try RetentionService(policy: policy).run(store: store)

        XCTAssertTrue(report.contains("purged_videos=1"), "report: \(report)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldPath),
            "aged video file must be removed from disk"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recentPath),
            "recent video must remain on disk"
        )

        // DB: old marked purged (status 2), recent still active (status 0).
        let stmt = try store.db.prepare("SELECT id, status FROM video ORDER BY id ASC")
        defer { sqlite3_finalize(stmt) }
        var statuses: [Int64: Int64] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            statuses[SQLiteColumn.int64(stmt, 0)] = SQLiteColumn.int64(stmt, 1)
        }
        XCTAssertEqual(statuses[oldVideoID], 2, "purged status")
        XCTAssertEqual(statuses[recentVideoID], 0, "active status")

        // Timeline keeps the moment searchable but must not advertise purged
        // media as decodable. Active compacted media remains available.
        let timeline = try store.recentTimeline(limit: 10)
        let oldMoment = try XCTUnwrap(timeline.first(where: { $0.id == oldFrameID }))
        let recentMoment = try XCTUnwrap(timeline.first(where: { $0.id == recentFrameID }))
        XCTAssertNil(oldMoment.videoID)
        XCTAssertEqual(oldMoment.foreground, "old retained content")
        XCTAssertEqual(recentMoment.videoID, recentVideoID)
    }

    func testStorageCapDeletesOldestFiles() throws {
        let videosDir = tempRoot.appendingPathComponent("videos", isDirectory: true)
        try FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)

        // Two large videos; cap is smaller than the whole library with both, but
        // comfortably fits the database and the newer video after one eviction.
        let pathA = videosDir.appendingPathComponent("a.mp4").path
        let pathB = videosDir.appendingPathComponent("b.mp4").path
        let chunk = Data(repeating: 0x11, count: 6_000_000)
        try chunk.write(to: URL(fileURLWithPath: pathA))
        try chunk.write(to: URL(fileURLWithPath: pathB))

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let idA = try store.insertVideo(path: pathA, numFrames: 1, sizeBytes: Int64(chunk.count))
        let idB = try store.insertVideo(path: pathB, numFrames: 1, sizeBytes: Int64(chunk.count))
        let fA = try store.insertSeedFrame(timestampMs: nowMs - 10_000, foreground: "a")
        let fB = try store.insertSeedFrame(timestampMs: nowMs - 5_000, foreground: "b")
        try store.attachFrame(id: fA, videoID: idA, videoIndex: 0)
        try store.attachFrame(id: fB, videoID: idB, videoIndex: 0)

        // Cap at 8 MB to one video must be deleted after accounting for DB overhead.
        let policy = RetentionPolicy(
            retentionDays: 3650,  // age path won't hit
            storageCapMB: 8,
            deleteOldestWhenOverCap: true
        )
        let report = try RetentionService(policy: policy).run(store: store)
        XCTAssertTrue(report.contains("purged_videos="), report)

        let aExists = FileManager.default.fileExists(atPath: pathA)
        let bExists = FileManager.default.fileExists(atPath: pathB)
        // Oldest (A) should be removed first.
        XCTAssertFalse(aExists, "oldest over-cap video deleted")
        XCTAssertTrue(bExists, "newer video kept under cap")
        XCTAssertTrue(report.contains("cap_satisfied=true"), report)
    }

    func testStorageCapDeletesOldestStillAndKeepsFrameMetadata() throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let oldID = try insertStill(
            timestampMs: nowMs - 10_000,
            foreground: "searchable old text",
            byteCount: 10_000_000
        )
        let newID = try insertStill(
            timestampMs: nowMs - 5_000,
            foreground: "new text",
            byteCount: 1_024
        )
        let oldPath = try imagePath(frameID: oldID)
        let newPath = try imagePath(frameID: newID)

        let report = try RetentionService(
            policy: RetentionPolicy(retentionDays: 3_650, storageCapMB: 8)
        ).run(store: store)

        XCTAssertTrue(report.contains("purged_stills=1"), report)
        XCTAssertTrue(report.contains("cap_satisfied=true"), report)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newPath))
        XCTAssertNil(try imagePathOptional(frameID: oldID))
        XCTAssertEqual(try imagePathOptional(frameID: newID), newPath)
        XCTAssertEqual(try frameForeground(frameID: oldID), "searchable old text")
    }

    func testAgeLimitAlsoPurgesUnfinalizedStills() throws {
        let oldID = try insertStill(
            timestampMs: 1_600_000_000_000,
            foreground: "aged still",
            byteCount: 2_048
        )
        let oldPath = try imagePath(frameID: oldID)

        let report = try RetentionService(policy: ageOnlyPolicy).run(store: store)

        XCTAssertTrue(report.contains("purged_stills=1"), report)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath))
        XCTAssertNil(try imagePathOptional(frameID: oldID))
        XCTAssertEqual(try frameForeground(frameID: oldID), "aged still")
    }

    func testMaximumRetentionAgeDoesNotOverflowOrPurgeMedia() throws {
        let frameID = try insertStill(
            timestampMs: 1_600_000_000_000,
            foreground: "long retention",
            byteCount: 2_048
        )
        let path = try imagePath(frameID: frameID)
        let service = RetentionService(
            policy: RetentionPolicy(retentionDays: Int.max, storageCapMB: 0)
        )

        let preview = try service.preflight(store: store)
        let report = try service.runDetailed(store: store)

        XCTAssertEqual(preview.cutoffMs, Int64.min)
        XCTAssertEqual(report.cutoffMs, preview.cutoffMs)
        XCTAssertEqual(preview.selectedMediaCount, 0)
        XCTAssertEqual(report.purgedStillCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try imagePathOptional(frameID: frameID), path)
    }

    func testStillDeletionFailureKeepsCanonicalFileAndCanRetry() throws {
        let id = try insertStill(
            timestampMs: 1_600_000_000_000,
            foreground: "retry still",
            byteCount: 2_048
        )
        let path = URL(fileURLWithPath: try imagePath(frameID: id))
        let service = RetentionService(
            policy: ageOnlyPolicy,
            fileSystem: FailingRetentionFileSystem(failRemovalAt: path, times: 1)
        )

        let failed = try service.run(store: store)
        XCTAssertTrue(failed.contains("failed_stills=1"), failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try imagePathOptional(frameID: id), path.path)

        let retried = try service.run(store: store)
        XCTAssertTrue(retried.contains("purged_stills=1"), retried)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertNil(try imagePathOptional(frameID: id))
    }

    func testManagedLibrarySizeIncludesHiddenRecoveryAndDatabaseFiles() throws {
        let hidden = tempRoot.appendingPathComponent("frames/.recovery-test", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let payload = Data(repeating: 0xAA, count: 12_345)
        try payload.write(to: hidden.appendingPathComponent("capture.bin"))

        let measured = try ManagedLibraryStorage.byteSize(root: tempRoot)
        let databaseSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: ScreenlogPaths.databaseURL(root: tempRoot).path)[.size]
                as? NSNumber
        ).int64Value

        XCTAssertGreaterThanOrEqual(measured, databaseSize + Int64(payload.count))
    }

    func testPreflightEstimatesAgedMediaWithoutChangingLibrary() throws {
        let oldID = try insertStill(
            timestampMs: 1_600_000_000_000,
            foreground: "aged preflight fixture",
            byteCount: 4_096
        )
        _ = try insertStill(
            timestampMs: Int64(Date().timeIntervalSince1970 * 1_000),
            foreground: "recent preflight fixture",
            byteCount: 2_048
        )
        let oldPath = try imagePath(frameID: oldID)
        let service = RetentionService(policy: ageOnlyPolicy)

        let report = try service.preflight(store: store)

        XCTAssertEqual(report.selectedMediaCount, 1)
        XCTAssertEqual(report.unavailableMediaCount, 0)
        XCTAssertEqual(report.estimatedReclaimableBytes, 4_096)
        XCTAssertEqual(report.projectedLibraryBytes, report.libraryBytes - 4_096)
        XCTAssertNil(report.capBytes)
        XCTAssertNil(report.capSatisfiedAfterEstimate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldPath))
        XCTAssertEqual(try imagePathOptional(frameID: oldID), oldPath)
    }

    func testPreflightUsesOldestFirstForStorageCapWithoutDeleting() throws {
        let videosDirectory = ScreenlogPaths.videosDirectory(root: tempRoot)
        let oldURL = videosDirectory.appendingPathComponent("preflight-old.mp4")
        let newURL = videosDirectory.appendingPathComponent("preflight-new.mp4")
        let bytes = Data(repeating: 0x6B, count: 6_000_000)
        try bytes.write(to: oldURL)
        try bytes.write(to: newURL)

        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let oldVideoID = try store.insertVideo(
            path: oldURL.path,
            numFrames: 1,
            sizeBytes: Int64(bytes.count)
        )
        let newVideoID = try store.insertVideo(
            path: newURL.path,
            numFrames: 1,
            sizeBytes: Int64(bytes.count)
        )
        let oldFrameID = try store.insertSeedFrame(timestampMs: nowMs - 10_000, foreground: "old")
        let newFrameID = try store.insertSeedFrame(timestampMs: nowMs - 5_000, foreground: "new")
        try store.attachFrame(id: oldFrameID, videoID: oldVideoID, videoIndex: 0)
        try store.attachFrame(id: newFrameID, videoID: newVideoID, videoIndex: 0)
        let oldStillBytes = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: try imagePath(frameID: oldFrameID))[.size]
                as? NSNumber
        ).int64Value

        let report = try RetentionService(
            policy: RetentionPolicy(retentionDays: 3_650, storageCapMB: 8)
        ).preflight(store: store, now: now)

        XCTAssertEqual(report.selectedMediaCount, 2)
        XCTAssertEqual(report.estimatedReclaimableBytes, Int64(bytes.count) + oldStillBytes)
        XCTAssertEqual(report.capBytes, 8_000_000)
        XCTAssertEqual(report.capSatisfiedAfterEstimate, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertEqual(try videoState(id: oldVideoID).status, 0)
        XCTAssertEqual(try videoState(id: newVideoID).status, 0)
    }

    func testPreflightReportsSelectedUnmanagedMediaAsUnavailable() throws {
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-preflight-external-\(UUID().uuidString).bin")
        try Data(repeating: 0x4A, count: 1_024).write(to: externalURL)
        defer { try? FileManager.default.removeItem(at: externalURL) }
        _ = try store.insertSeedFrame(
            timestampMs: 1_600_000_000_000,
            foreground: "outside managed root",
            imagePath: externalURL.path
        )

        let report = try RetentionService(policy: ageOnlyPolicy).preflight(store: store)

        XCTAssertEqual(report.selectedMediaCount, 1)
        XCTAssertEqual(report.unavailableMediaCount, 1)
        XCTAssertEqual(report.estimatedReclaimableBytes, 0)
        XCTAssertEqual(report.projectedLibraryBytes, report.libraryBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalURL.path))
    }

    func testDeletionFailureKeepsVideoActiveAndIsRetryable() throws {
        let videosDir = ScreenlogPaths.videosDirectory(root: tempRoot)
        let path = videosDir.appendingPathComponent("retry-delete.mp4")
        let bytes = Data(repeating: 0x44, count: 8_192)
        try bytes.write(to: path)
        let videoID = try insertAgedVideo(path: path, sizeBytes: Int64(bytes.count))

        let fileSystem = FailingRetentionFileSystem(failRemovalAt: path, times: 1)
        let service = RetentionService(policy: ageOnlyPolicy, fileSystem: fileSystem)
        let failedReport = try service.run(store: store)

        XCTAssertTrue(failedReport.contains("purged_videos=0"), failedReport)
        XCTAssertTrue(failedReport.contains("failed_videos=1"), failedReport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try videoState(id: videoID).status, 0)
        XCTAssertEqual(try videoState(id: videoID).sizeBytes, Int64(bytes.count))
        XCTAssertTrue(
            try XCTUnwrap(store.getMeta(key: "last_retention_errors"))
                .contains("operation=delete_transaction")
        )

        let retryReport = try service.run(store: store)
        XCTAssertTrue(retryReport.contains("purged_videos=1"), retryReport)
        XCTAssertTrue(retryReport.contains("failed_videos=0"), retryReport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try videoState(id: videoID).status, 2)
        XCTAssertEqual(try store.getMeta(key: "last_retention_errors"), "")
    }

    func testMissingFileReconcilesDatabaseWithoutClaimingFreedBytes() throws {
        let missingPath = ScreenlogPaths.videosDirectory(root: tempRoot)
            .appendingPathComponent("already-missing.mp4")
        let videoID = try insertAgedVideo(path: missingPath, sizeBytes: 65_536)

        let report = try RetentionService(policy: ageOnlyPolicy).run(store: store)

        XCTAssertTrue(report.contains("purged_videos=1"), report)
        XCTAssertTrue(report.contains("failed_videos=0"), report)
        XCTAssertTrue(report.contains("missing_files=1"), report)
        XCTAssertTrue(report.contains("freed_bytes=0"), report)
        XCTAssertEqual(try videoState(id: videoID).status, 2)
        XCTAssertEqual(try videoState(id: videoID).sizeBytes, 0)
    }

    func testAgedVideoOutsideManagedDirectoryIsRejectedWithoutMutation() throws {
        let externalPath =
            tempRoot
            .deletingLastPathComponent()
            .appendingPathComponent("screenlog-external-\(UUID().uuidString).mp4")
        let bytes = Data(repeating: 0x77, count: 3_072)
        try bytes.write(to: externalPath)
        defer { try? FileManager.default.removeItem(at: externalPath) }
        let videoID = try insertAgedVideo(path: externalPath, sizeBytes: Int64(bytes.count))

        let report = try RetentionService(policy: ageOnlyPolicy).run(store: store)

        XCTAssertTrue(report.contains("purged_videos=0"), report)
        XCTAssertTrue(report.contains("failed_videos=1"), report)
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalPath.path))
        XCTAssertEqual(try Data(contentsOf: externalPath), bytes)
        let state = try videoState(id: videoID)
        XCTAssertEqual(state.status, 0)
        XCTAssertEqual(state.path, externalPath.path)
        XCTAssertEqual(state.sizeBytes, Int64(bytes.count))
        XCTAssertTrue(
            try XCTUnwrap(store.getMeta(key: "last_retention_errors"))
                .contains("reason=outside_videos_directory")
        )
    }

    func testDatabaseFailureKeepsCanonicalFileAndCanRetry() throws {
        let videosDir = ScreenlogPaths.videosDirectory(root: tempRoot)
        let path = videosDir.appendingPathComponent("database-retry.mp4")
        let bytes = Data(repeating: 0x55, count: 4_096)
        try bytes.write(to: path)
        let videoID = try insertAgedVideo(path: path, sizeBytes: Int64(bytes.count))
        try store.db.exec(
            """
            CREATE TRIGGER reject_retention_purge
            BEFORE UPDATE OF status ON video
            WHEN NEW.id = \(videoID) AND NEW.status = 2
            BEGIN
                SELECT RAISE(ABORT, 'forced retention database failure');
            END;
            """
        )

        let service = RetentionService(policy: ageOnlyPolicy)
        let failedReport = try service.run(store: store)

        XCTAssertTrue(failedReport.contains("purged_videos=0"), failedReport)
        XCTAssertTrue(failedReport.contains("failed_videos=1"), failedReport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try videoState(id: videoID).status, 0)
        XCTAssertEqual(try videoState(id: videoID).path, path.path)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    videosDir
                    .appendingPathComponent(".retention-recovery/video-\(videoID).mp4")
                    .path
            )
        )

        try store.db.exec("DROP TRIGGER reject_retention_purge;")
        let retryReport = try service.run(store: store)
        XCTAssertTrue(retryReport.contains("purged_videos=1"), retryReport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try videoState(id: videoID).status, 2)
    }

    func testRecoveryCleanupFailureRepointsActiveRowToExistingBytes() throws {
        let videosDir = ScreenlogPaths.videosDirectory(root: tempRoot)
        let path = videosDir.appendingPathComponent("cleanup-retry.mp4")
        let bytes = Data(repeating: 0x66, count: 2_048)
        try bytes.write(to: path)
        let videoID = try insertAgedVideo(path: path, sizeBytes: Int64(bytes.count))
        let recoveryPath =
            videosDir
            .appendingPathComponent(".retention-recovery/video-\(videoID).mp4")
        let fileSystem = FailingRetentionFileSystem(failRemovalAt: recoveryPath, times: 1)
        let service = RetentionService(policy: ageOnlyPolicy, fileSystem: fileSystem)

        let failedReport = try service.run(store: store)

        XCTAssertTrue(failedReport.contains("purged_videos=0"), failedReport)
        XCTAssertTrue(failedReport.contains("failed_videos=1"), failedReport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryPath.path))
        let activeState = try videoState(id: videoID)
        XCTAssertEqual(activeState.status, 0)
        XCTAssertEqual(activeState.path, recoveryPath.path)
        XCTAssertEqual(activeState.sizeBytes, Int64(bytes.count))

        let retryReport = try service.run(store: store)
        XCTAssertTrue(retryReport.contains("purged_videos=1"), retryReport)
        XCTAssertTrue(retryReport.contains("failed_videos=0"), retryReport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryPath.path))
        XCTAssertEqual(try videoState(id: videoID).status, 2)
    }

    func testCommittedPurgeNotifiesWhenRecoveryCleanupAndReactivationBothFail() throws {
        let videosDirectory = ScreenlogPaths.videosDirectory(root: tempRoot)
        let path = videosDirectory.appendingPathComponent("double-failure.mp4")
        let bytes = Data(repeating: 0x71, count: 2_048)
        try bytes.write(to: path)
        let videoID = try insertAgedVideo(path: path, sizeBytes: Int64(bytes.count))
        let recoveryPath =
            videosDirectory
            .appendingPathComponent(".retention-recovery/video-\(videoID).mp4")
        let fileSystem = FailingRetentionFileSystem(failRemovalAt: recoveryPath, times: 1)
        try store.db.exec(
            """
            CREATE TRIGGER reject_retention_reactivation
            BEFORE UPDATE OF status ON video
            WHEN OLD.id = \(videoID) AND OLD.status = 2 AND NEW.status = 0
            BEGIN
                SELECT RAISE(ABORT, 'forced retention reactivation failure');
            END;
            """
        )
        let notified = expectation(description: "durably unavailable media changed")
        let token = NotificationCenter.default.addObserver(
            forName: .screenlogRetentionDidPurgeMedia,
            object: store,
            queue: nil
        ) { _ in
            notified.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let report = try RetentionService(
            policy: ageOnlyPolicy,
            fileSystem: fileSystem
        ).runDetailed(store: store)

        XCTAssertEqual(report.failedVideoCount, 1)
        XCTAssertEqual(report.purgedVideoCount, 0)
        wait(for: [notified], timeout: 0.2)
        XCTAssertEqual(try videoState(id: videoID).status, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryPath.path))
        let frameStatement = try store.db.prepare("SELECT id FROM frame WHERE video = ? LIMIT 1")
        defer { sqlite3_finalize(frameStatement) }
        SQLiteBind.int64(frameStatement, 1, videoID)
        guard sqlite3_step(frameStatement) == SQLITE_ROW else {
            return XCTFail("Expected a frame attached to the failed video purge")
        }
        let descriptor = try XCTUnwrap(
            store.framePreviewDescriptor(id: SQLiteColumn.int64(frameStatement, 0))
        )
        XCTAssertEqual(descriptor.source, .unavailable)
    }

    private var ageOnlyPolicy: RetentionPolicy {
        RetentionPolicy(
            retentionDays: 30,
            storageCapMB: 0,
            deleteOldestWhenOverCap: false
        )
    }

    @discardableResult
    private func insertAgedVideo(path: URL, sizeBytes: Int64) throws -> Int64 {
        let videoID = try store.insertVideo(path: path.path, numFrames: 1, sizeBytes: sizeBytes)
        let frameID = try store.insertSeedFrame(
            timestampMs: 1_600_000_000_000,
            foreground: "aged retention fixture"
        )
        try store.attachFrame(id: frameID, videoID: videoID, videoIndex: 0)
        if let stillPath = try imagePathOptional(frameID: frameID) {
            try? FileManager.default.removeItem(atPath: stillPath)
        }
        try store.db.exec("UPDATE frame SET image_path = NULL WHERE id = \(frameID)")
        return videoID
    }

    private func videoState(id: Int64) throws -> (status: Int64, path: String, sizeBytes: Int64) {
        let stmt = try store.db.prepare(
            "SELECT status, path, COALESCE(size_bytes, 0) FROM video WHERE id = ?"
        )
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw SQLiteError.notFound
        }
        return (
            SQLiteColumn.int64(stmt, 0),
            SQLiteColumn.text(stmt, 1) ?? "",
            SQLiteColumn.int64(stmt, 2)
        )
    }

    @discardableResult
    private func insertStill(timestampMs: Int64, foreground: String, byteCount: Int) throws -> Int64 {
        try store.store(
            payload: CapturePayload(
                imageData: Data(repeating: 0x5A, count: byteCount),
                timestampMs: timestampMs,
                width: 100,
                height: 100,
                foreground: foreground,
                background: "",
                title: "",
                imageFileExtension: "bin"
            )
        )
    }

    private func imagePath(frameID: Int64) throws -> String {
        try XCTUnwrap(imagePathOptional(frameID: frameID))
    }

    private func imagePathOptional(frameID: Int64) throws -> String? {
        let stmt = try store.db.prepare("SELECT image_path FROM frame WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, frameID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw SQLiteError.notFound }
        return SQLiteColumn.text(stmt, 0)
    }

    private func frameForeground(frameID: Int64) throws -> String? {
        let stmt = try store.db.prepare("SELECT foreground FROM frame WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, frameID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw SQLiteError.notFound }
        return SQLiteColumn.text(stmt, 0)
    }
}

private final class FailingRetentionFileSystem: RetentionFileSystem, @unchecked Sendable {
    private let failingPath: String
    private var remainingFailures: Int

    init(failRemovalAt url: URL, times: Int) {
        self.failingPath = url.standardizedFileURL.path
        self.remainingFailures = times
    }

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
        if url.standardizedFileURL.path == failingPath, remainingFailures > 0 {
            remainingFailures -= 1
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: url)
    }
}
