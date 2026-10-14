import Foundation
import XCTest

@testable import ScreenlogCore

final class LibraryExportServiceTests: XCTestCase {
    private var temporaryRoot: URL!
    private var store: Store!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlogger-export-tests-\(UUID().uuidString)", isDirectory: true)
        store = try Store(root: temporaryRoot.appendingPathComponent("live", isDirectory: true))
    }

    override func tearDownWithError() throws {
        store = nil
        if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
    }

    func testExportCreatesVerifiedStandaloneCopyAndPreservesLiveLibrary() throws {
        let frameBytes = Data("frame payload".utf8)
        let videoBytes = Data("video payload".utf8)
        let frameURL = ScreenlogPaths.framesDirectory(root: store.root).appendingPathComponent("sample.webp")
        let videoURL = ScreenlogPaths.videosDirectory(root: store.root).appendingPathComponent("sample.mp4")
        try frameBytes.write(to: frameURL)
        try videoBytes.write(to: videoURL)
        _ = try store.insertSeedFrame(timestampMs: 123, foreground: "Exported frame", imagePath: frameURL.path)

        let destination = temporaryRoot.appendingPathComponent("My Library.screenloggerbackup", isDirectory: true)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let service = LibraryExportService(now: { fixedDate })
        let result = try service.export(store: store, to: destination)

        XCTAssertEqual(result.destination, destination)
        XCTAssertEqual(result.manifest.createdAt, fixedDate)
        XCTAssertEqual(result.manifest.schemaVersion, Schema.currentVersion)
        XCTAssertEqual(
            result.manifest.files.map(\.relativePath),
            [
                "Library/db.sqlite3",
                "Library/frames/0000000000000001.bin",
                "Library/frames/sample.webp",
                "Library/videos/sample.mp4",
            ])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Library/frames/0000000000000001.bin").path
            ))
        XCTAssertEqual(try Data(contentsOf: frameURL), frameBytes)
        XCTAssertEqual(try Data(contentsOf: videoURL), videoBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Library/db.sqlite3-wal").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Library/db.sqlite3-shm").path))
        XCTAssertEqual(service.preflightRestore(at: destination), .ready(result.manifest))
    }

    func testExportRefusesExistingDestinationWithoutChangingIt() throws {
        let destination = temporaryRoot.appendingPathComponent("Existing.screenloggerbackup")
        let sentinel = Data("leave this alone".utf8)
        try sentinel.write(to: destination)

        XCTAssertThrowsError(try LibraryExportService().export(store: store, to: destination)) { error in
            guard case .destinationExists = error as? LibraryExportError else {
                return XCTFail("Expected destinationExists, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
    }

    func testExportRefusesDestinationInsideLiveLibrary() throws {
        let destination = store.root.appendingPathComponent("unsafe.screenloggerbackup", isDirectory: true)

        XCTAssertThrowsError(try LibraryExportService().export(store: store, to: destination)) { error in
            guard case .unsafeDestination = error as? LibraryExportError else {
                return XCTFail("Expected unsafeDestination, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPreflightDetectsTamperedManagedFile() throws {
        let frameURL = ScreenlogPaths.framesDirectory(root: store.root).appendingPathComponent("sample.webp")
        try Data("original".utf8).write(to: frameURL)
        let destination = temporaryRoot.appendingPathComponent("Tamper.screenloggerbackup", isDirectory: true)
        let service = LibraryExportService()
        _ = try service.export(store: store, to: destination)

        try Data("different length".utf8).write(
            to: destination.appendingPathComponent("Library/frames/sample.webp")
        )

        XCTAssertEqual(
            service.preflightRestore(at: destination),
            .invalid(.sizeMismatch("Library/frames/sample.webp"))
        )
    }

    func testPreflightRejectsTraversalPathBeforeReadingIt() throws {
        let destination = temporaryRoot.appendingPathComponent("Unsafe.screenloggerbackup", isDirectory: true)
        let service = LibraryExportService()
        let result = try service.export(store: store, to: destination)
        var files = result.manifest.files
        files[0] = .init(relativePath: "../outside", sizeBytes: files[0].sizeBytes, sha256: files[0].sha256)
        let unsafe = LibraryExportManifest(
            formatVersion: result.manifest.formatVersion,
            productIdentifier: result.manifest.productIdentifier,
            createdAt: result.manifest.createdAt,
            schemaVersion: result.manifest.schemaVersion,
            totalBytes: result.manifest.totalBytes,
            files: files
        )
        try encodeManifest(unsafe).write(
            to: destination.appendingPathComponent(LibraryExportService.manifestName),
            options: .atomic
        )

        XCTAssertEqual(service.preflightRestore(at: destination), .invalid(.unsafeRelativePath("../outside")))
    }

    func testPreflightRejectsUnlistedFilesAndEmptyDirectories() throws {
        let destination = temporaryRoot.appendingPathComponent("Shape.screenloggerbackup", isDirectory: true)
        let service = LibraryExportService()
        _ = try service.export(store: store, to: destination)
        let extra = destination.appendingPathComponent("Library/frames/unlisted.bin")
        try Data([1]).write(to: extra)

        XCTAssertEqual(
            service.preflightRestore(at: destination),
            .invalid(.unexpectedFile("Library/frames/unlisted.bin"))
        )

        try FileManager.default.removeItem(at: extra)
        let empty = destination.appendingPathComponent("Library/frames/unlisted", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        XCTAssertEqual(
            service.preflightRestore(at: destination),
            .invalid(.unexpectedFile("Library/frames/unlisted"))
        )
    }

    func testExportSerializesSnapshotAgainstStoreWriters() throws {
        let acquired = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let exportFinished = expectation(description: "export finished")
        let writerFinished = DispatchSemaphore(value: 0)
        let destination = temporaryRoot.appendingPathComponent("Coordinated.screenloggerbackup", isDirectory: true)
        let service = LibraryExportService(didAcquireSnapshotLock: {
            acquired.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        })

        DispatchQueue.global(qos: .utility).async {
            defer { exportFinished.fulfill() }
            do {
                _ = try service.export(store: self.store, to: destination)
            } catch {
                XCTFail("Export failed: \(error)")
            }
        }
        XCTAssertEqual(acquired.wait(timeout: .now() + 5), .success)
        DispatchQueue.global(qos: .utility).async {
            defer { writerFinished.signal() }
            do {
                _ = try self.store.insertSeedFrame(timestampMs: 456, foreground: "after snapshot")
            } catch {
                XCTFail("Writer failed: \(error)")
            }
        }
        XCTAssertEqual(writerFinished.wait(timeout: .now() + 0.15), .timedOut)
        release.signal()
        wait(for: [exportFinished], timeout: 10)
        XCTAssertEqual(writerFinished.wait(timeout: .now() + 5), .success)
        XCTAssertNotEqual(service.preflightRestore(at: destination), .invalid(.invalidManifest))
    }

    private func encodeManifest(_ manifest: LibraryExportManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }
}
