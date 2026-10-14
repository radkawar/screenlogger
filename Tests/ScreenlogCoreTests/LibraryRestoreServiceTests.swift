import Foundation
import XCTest

@testable import ScreenlogCore

final class LibraryRestoreServiceTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlogger-restore-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
    }

    func testRestoreReplacesOnlyManagedLibraryAndRewritesPortableMediaPaths() throws {
        let liveRoot = temporaryRoot.appendingPathComponent("live", isDirectory: true)
        let archive = try makeArchive(named: "Replacement", foreground: "replacement")
        let live = try Store(root: liveRoot)
        let oldID = try live.insertSeedFrame(timestampMs: 1, foreground: "old")
        let unrelated = liveRoot.appendingPathComponent("keep-me.txt")
        try Data("unrelated".utf8).write(to: unrelated)
        try live.db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
        try live.db.close()

        let result = try LibraryRestoreService().restore(from: archive, replacing: liveRoot)

        XCTAssertGreaterThan(result.restoredBytes, 0)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("unrelated".utf8))
        let restored = try Store(root: liveRoot)
        let rows = try restored.recentFrames(limit: 10)
        XCTAssertEqual(rows.map(\.foreground), ["replacement"])
        XCTAssertNotEqual(try restored.frame(id: oldID)?.foreground, "old")
        let imagePath = try XCTUnwrap(rows.first?.imagePath)
        XCTAssertEqual(URL(fileURLWithPath: imagePath).deletingLastPathComponent(), ScreenlogPaths.framesDirectory(root: liveRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))
        try restored.db.close()
        XCTAssertEqual(try LibraryRestoreService().recoverInterruptedRestore(at: liveRoot), .nothingToRecover)
    }

    func testInterruptionAfterMovingLiveRollsBackExactPreviousLibrary() throws {
        let liveRoot = temporaryRoot.appendingPathComponent("live", isDirectory: true)
        let archive = try makeArchive(named: "Replacement", foreground: "replacement")
        let live = try Store(root: liveRoot)
        let oldID = try live.insertSeedFrame(timestampMs: 1, foreground: "old")
        try live.db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
        try live.db.close()

        let interrupted = LibraryRestoreService(interruptAfter: .liveMoved)
        XCTAssertThrowsError(try interrupted.restore(from: archive, replacing: liveRoot)) { error in
            XCTAssertEqual(error as? LibraryRestoreError, .activationFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ScreenlogPaths.databaseURL(root: liveRoot).path))

        XCTAssertEqual(try LibraryRestoreService().recoverInterruptedRestore(at: liveRoot), .rolledBack)
        let recovered = try Store(root: liveRoot)
        XCTAssertEqual(try recovered.frame(id: oldID)?.foreground, "old")
        XCTAssertEqual(try recovered.recentFrames(limit: 10).count, 1)
        try recovered.db.close()
    }

    func testInterruptionAfterInstalledLibraryFinishesVerifiedActivation() throws {
        let liveRoot = temporaryRoot.appendingPathComponent("live", isDirectory: true)
        let archive = try makeArchive(named: "Replacement", foreground: "replacement")
        let live = try Store(root: liveRoot)
        _ = try live.insertSeedFrame(timestampMs: 1, foreground: "old")
        try live.db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
        try live.db.close()

        let interrupted = LibraryRestoreService(interruptAfter: .installed)
        XCTAssertThrowsError(try interrupted.restore(from: archive, replacing: liveRoot))

        XCTAssertEqual(try LibraryRestoreService().recoverInterruptedRestore(at: liveRoot), .completed)
        let recovered = try Store(root: liveRoot)
        XCTAssertEqual(try recovered.recentFrames(limit: 10).map(\.foreground), ["replacement"])
        try recovered.db.close()
    }

    func testRecoveryRollsBackInstalledLibraryThatNoLongerValidates() throws {
        let liveRoot = temporaryRoot.appendingPathComponent("live", isDirectory: true)
        let archive = try makeArchive(named: "Replacement", foreground: "replacement")
        let live = try Store(root: liveRoot)
        let oldID = try live.insertSeedFrame(timestampMs: 1, foreground: "old")
        try live.db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
        try live.db.close()

        XCTAssertThrowsError(
            try LibraryRestoreService(interruptAfter: .installed)
                .restore(from: archive, replacing: liveRoot)
        )
        try Data("damaged".utf8).write(to: ScreenlogPaths.databaseURL(root: liveRoot))

        XCTAssertEqual(try LibraryRestoreService().recoverInterruptedRestore(at: liveRoot), .rolledBack)
        let recovered = try Store(root: liveRoot)
        XCTAssertEqual(try recovered.frame(id: oldID)?.foreground, "old")
        try recovered.db.close()
    }

    func testRestoreRejectsArchiveInsideLiveLibraryWithoutCreatingJournal() throws {
        let liveRoot = temporaryRoot.appendingPathComponent("live", isDirectory: true)
        let live = try Store(root: liveRoot)
        let externalArchive = try makeArchive(named: "External", foreground: "replacement")
        let nestedArchive = liveRoot.appendingPathComponent("Nested.screenloggerbackup", isDirectory: true)
        try FileManager.default.copyItem(at: externalArchive, to: nestedArchive)
        try live.db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
        try live.db.close()

        XCTAssertThrowsError(try LibraryRestoreService().restore(from: nestedArchive, replacing: liveRoot)) { error in
            XCTAssertEqual(error as? LibraryRestoreError, .unsafeArchive)
        }
        let journals = try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)
            .filter { $0.hasPrefix(".live.restore-") }
        XCTAssertTrue(journals.isEmpty)
    }

    private func makeArchive(named name: String, foreground: String) throws -> URL {
        let sourceRoot = temporaryRoot.appendingPathComponent("\(name)-source", isDirectory: true)
        let source = try Store(root: sourceRoot)
        _ = try source.insertSeedFrame(timestampMs: 10, foreground: foreground)
        let archive = temporaryRoot.appendingPathComponent("\(name).screenloggerbackup", isDirectory: true)
        _ = try LibraryExportService().export(store: source, to: archive)
        try source.db.close()
        return archive
    }
}
