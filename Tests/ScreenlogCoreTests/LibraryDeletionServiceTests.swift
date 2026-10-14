import Foundation
import SQLite3
import XCTest

@testable import ScreenlogCore

final class LibraryDeletionServiceTests: XCTestCase {
    private var root: URL!
    private var store: Store!
    private var service: LibraryDeletionService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-deletion-\(UUID().uuidString)", isDirectory: true)
        store = try Store(root: root)
        service = LibraryDeletionService()
    }

    override func tearDownWithError() throws {
        store = nil
        service = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testMomentRequiresMatchingReviewedConfirmation() throws {
        let id = try seed(timestamp: 100, text: "keep until confirmed")
        let path = try XCTUnwrap(try store.frame(id: id)?.imagePath)
        let plan = try service.prepare(selection: .moment(frameID: id), store: store)

        XCTAssertThrowsError(
            try service.delete(
                plan,
                confirmation: .userConfirmed(reviewID: UUID()),
                store: store
            )
        ) { error in
            XCTAssertEqual(error as? LibraryDeletionError, .confirmationDoesNotMatchReview)
        }
        XCTAssertNotNil(try store.frame(id: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testConfirmedMomentDeletesDatabaseFTSAndManagedStill() throws {
        let id = try seed(timestamp: 100, text: "private deletion phrase")
        let path = try XCTUnwrap(try store.frame(id: id)?.imagePath)
        let plan = try service.prepare(selection: .moment(frameID: id), store: store)

        let report = try service.delete(
            plan,
            confirmation: .userConfirmed(reviewID: plan.reviewID),
            store: store
        )

        XCTAssertEqual(report.deletedMomentCount, 1)
        XCTAssertEqual(report.deletedManagedFileCount, 1)
        XCTAssertFalse(report.cleanupPending)
        XCTAssertNil(try store.frame(id: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(try store.ftsSearch(query: "private deletion phrase", limit: 10).isEmpty)
    }

    func testDeletingSynchronizedMomentRemovesEveryCapturedDisplay() throws {
        let first = try seed(timestamp: 100, text: "main display")
        let second = try seed(timestamp: 100, text: "second display")
        let later = try seed(timestamp: 200, text: "later moment")
        let plan = try service.prepare(selection: .moment(frameID: second), store: store)

        XCTAssertEqual(plan.requestedMomentCount, 1)
        XCTAssertEqual(plan.affectedMomentCount, 1)

        let report = try service.delete(
            plan,
            confirmation: .userConfirmed(reviewID: plan.reviewID),
            store: store
        )

        XCTAssertEqual(report.deletedMomentCount, 1)
        XCTAssertNil(try store.frame(id: first))
        XCTAssertNil(try store.frame(id: second))
        XCTAssertNotNil(try store.frame(id: later))
    }

    func testRangeIsHalfOpenAndReviewExpiresWhenSelectionChanges() throws {
        let first = try seed(timestamp: 100, text: "first")
        _ = try seed(timestamp: 199, text: "inside")
        let boundary = try seed(timestamp: 200, text: "boundary")
        let plan = try service.prepare(selection: .timeRange(startMs: 100, endMs: 200), store: store)
        XCTAssertEqual(plan.requestedMomentCount, 2)

        _ = try seed(timestamp: 150, text: "arrived while sheet was open")
        XCTAssertThrowsError(
            try service.delete(
                plan,
                confirmation: .userConfirmed(reviewID: plan.reviewID),
                store: store
            )
        ) { error in
            XCTAssertEqual(error as? LibraryDeletionError, .reviewExpired)
        }
        XCTAssertNotNil(try store.frame(id: first))
        XCTAssertNotNil(try store.frame(id: boundary))
    }

    func testCompactedVideoExpandsReviewAndDeletesWholeVideo() throws {
        let videoPath = ScreenlogPaths.videosDirectory(root: root).appendingPathComponent("shared.mp4")
        try Data(repeating: 0x44, count: 2_048).write(to: videoPath)
        let videoID = try store.insertVideo(path: videoPath.path, numFrames: 2, sizeBytes: 2_048)
        let selected = try seed(timestamp: 100, text: "selected")
        let neighbor = try seed(timestamp: 300, text: "same encoded file")
        try store.attachFrame(id: selected, videoID: videoID, videoIndex: 0)
        try store.attachFrame(id: neighbor, videoID: videoID, videoIndex: 1)

        let plan = try service.prepare(selection: .moment(frameID: selected), store: store)
        XCTAssertEqual(plan.requestedMomentCount, 1)
        XCTAssertEqual(plan.affectedMomentCount, 2)
        XCTAssertEqual(plan.affectedVideoCount, 1)

        _ = try service.delete(
            plan,
            confirmation: .userConfirmed(reviewID: plan.reviewID),
            store: store
        )
        XCTAssertNil(try store.frame(id: selected))
        XCTAssertNil(try store.frame(id: neighbor))
        XCTAssertFalse(FileManager.default.fileExists(atPath: videoPath.path))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM video WHERE id = \(videoID)"), 0)
    }

    func testUnmanagedPathIsNeverRemoved() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-user-file-\(UUID().uuidString).bin")
        try Data([1, 2, 3]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let id = try store.insertSeedFrame(
            timestampMs: 100,
            foreground: "external",
            imagePath: outside.path
        )
        let plan = try service.prepare(selection: .moment(frameID: id), store: store)
        XCTAssertEqual(plan.unmanagedFileCount, 1)

        let report = try service.delete(
            plan,
            confirmation: .userConfirmed(reviewID: plan.reviewID),
            store: store
        )
        XCTAssertEqual(report.skippedUnmanagedFileCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertNil(try store.frame(id: id))
    }

    func testDatabaseFailureRestoresCanonicalFileAndRows() throws {
        let id = try seed(timestamp: 100, text: "rollback")
        let path = try XCTUnwrap(try store.frame(id: id)?.imagePath)
        let plan = try service.prepare(selection: .moment(frameID: id), store: store)
        try store.db.exec(
            """
            CREATE TRIGGER reject_library_deletion
            BEFORE DELETE ON frame WHEN OLD.id = \(id)
            BEGIN SELECT RAISE(ABORT, 'forced deletion failure'); END;
            """
        )

        XCTAssertThrowsError(
            try service.delete(
                plan,
                confirmation: .userConfirmed(reviewID: plan.reviewID),
                store: store
            )
        )
        XCTAssertNotNil(try store.frame(id: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(try store.ftsSearch(query: "rollback", limit: 10).contains { $0.frameID == id })
    }

    func testEntireLibraryDeletesAllCaptureRowsAndFiles() throws {
        let first = try store.insertSeedFrame(
            timestampMs: 100,
            foreground: "one",
            bundleID: "dev.screenlog.private-catalog",
            displayName: "Private Catalog",
            domain: "private.example",
            url: "https://private.example/one"
        )
        let second = try store.insertSeedFrame(
            timestampMs: 200,
            foreground: "two",
            bundleID: "dev.screenlog.private-catalog",
            displayName: "Private Catalog",
            domain: "private.example",
            url: "https://private.example/two"
        )
        let paths = try [first, second].compactMap { try store.frame(id: $0)?.imagePath }
        let plan = try service.prepare(selection: .entireLibrary, store: store)

        let report = try service.delete(
            plan,
            confirmation: .userConfirmed(reviewID: plan.reviewID),
            store: store
        )
        XCTAssertEqual(report.deletedMomentCount, 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM frame"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM segment"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM ocr_fts"), 0)
        XCTAssertTrue(try store.listApplications().isEmpty)
        XCTAssertTrue(try store.listDomains().isEmpty)
        XCTAssertTrue(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    func testPartialDeletionKeepsCatalogEntriesReferencedByRemainingFrames() throws {
        let deleted = try store.insertSeedFrame(
            timestampMs: 100,
            foreground: "delete this moment",
            bundleID: "dev.screenlog.shared-catalog",
            displayName: "Shared Catalog",
            domain: "shared.example",
            url: "https://shared.example/first"
        )
        let remaining = try store.insertSeedFrame(
            timestampMs: 200,
            foreground: "keep this moment",
            bundleID: "dev.screenlog.shared-catalog",
            displayName: "Shared Catalog",
            domain: "shared.example",
            url: "https://shared.example/second"
        )
        let plan = try service.prepare(selection: .moment(frameID: deleted), store: store)

        _ = try service.delete(
            plan,
            confirmation: .userConfirmed(reviewID: plan.reviewID),
            store: store
        )

        XCTAssertNotNil(try store.frame(id: remaining))
        XCTAssertEqual(try store.listApplications().map(\.bundleID), ["dev.screenlog.shared-catalog"])
        XCTAssertEqual(try store.listDomains().map(\.normalizedDomain), ["shared.example"])
    }

    func testEntireLibraryAlsoDeletesOrphanedManagedVideoRows() throws {
        let path = ScreenlogPaths.videosDirectory(root: root).appendingPathComponent("orphan.mp4")
        try Data(repeating: 0x22, count: 512).write(to: path)
        let videoID = try store.insertVideo(path: path.path, numFrames: 0, sizeBytes: 512)

        let plan = try service.prepare(selection: .entireLibrary, store: store)
        XCTAssertEqual(plan.requestedMomentCount, 0)
        XCTAssertEqual(plan.affectedVideoCount, 1)
        _ = try service.delete(
            plan,
            confirmation: .userConfirmed(reviewID: plan.reviewID),
            store: store
        )

        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM video WHERE id = \(videoID)"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testTodayResolvesCalendarBoundsAtReviewTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let formatter = ISO8601DateFormatter()
        let date = try XCTUnwrap(formatter.date(from: "2025-01-10T20:00:00Z"))
        let selection = LibraryDeletionSelection.today(containing: date, calendar: calendar)
        guard case .today(let start, let end) = selection else { return XCTFail("Expected today") }
        _ = try seed(timestamp: start, text: "today")
        _ = try seed(timestamp: end, text: "tomorrow")

        let plan = try service.prepare(selection: selection, store: store)
        XCTAssertEqual(plan.requestedMomentCount, 1)
    }

    func testStoreOpenRestoresInterruptedUncommittedDeletion() throws {
        let id = try seed(timestamp: 100, text: "recover after interruption")
        let originalPath = try XCTUnwrap(try store.frame(id: id)?.imagePath)
        let original = URL(fileURLWithPath: originalPath)
        let operationID = UUID()
        let operationDirectory =
            root
            .appendingPathComponent(".deletion-recovery", isDirectory: true)
            .appendingPathComponent(operationID.uuidString.lowercased(), isDirectory: true)
        let filesDirectory = operationDirectory.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        let backup = filesDirectory.appendingPathComponent("0")
        try FileManager.default.moveItem(at: original, to: backup)
        let markerKey = "library_deletion_committed_\(operationID.uuidString.lowercased())"
        let manifest: [String: Any] = [
            "operationID": operationID.uuidString,
            "markerKey": markerKey,
            "entries": [["originalPath": original.path, "backupPath": backup.path]],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: operationDirectory.appendingPathComponent("manifest.json"), options: .atomic)

        store = nil
        store = try Store(root: root)

        XCTAssertNotNil(try store.frame(id: id), "uncommitted SQLite rows survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "managed bytes are restored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: operationDirectory.path))
    }

    func testRecoveryManifestCannotTargetUnmanagedPath() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-recovery-must-not-touch-\(UUID().uuidString)")
        try Data([7, 8, 9]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let operationID = UUID()
        let operationDirectory =
            root
            .appendingPathComponent(".deletion-recovery", isDirectory: true)
            .appendingPathComponent(operationID.uuidString.lowercased(), isDirectory: true)
        let filesDirectory = operationDirectory.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        let backup = filesDirectory.appendingPathComponent("0")
        try Data([1]).write(to: backup)
        let manifest: [String: Any] = [
            "operationID": operationID.uuidString,
            "markerKey": "library_deletion_committed_\(operationID.uuidString.lowercased())",
            "entries": [["originalPath": outside.path, "backupPath": backup.path]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(
            to: operationDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        store = nil
        XCTAssertThrowsError(try Store(root: root)) { error in
            guard case LibraryDeletionError.recoveryFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data([7, 8, 9]))
    }

    private func seed(timestamp: Int64, text: String) throws -> Int64 {
        try store.insertSeedFrame(timestampMs: timestamp, foreground: text)
    }

    private func scalar(_ sql: String) throws -> Int64 {
        let stmt = try store.db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw SQLiteError.notFound }
        return SQLiteColumn.int64(stmt, 0)
    }
}
