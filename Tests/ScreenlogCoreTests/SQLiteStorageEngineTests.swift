import SQLite3
import XCTest

@testable import ScreenlogCore

/// Covers the two promises the storage engine makes to the rest of the app:
/// deleting data eventually returns disk space, and a read never has to wait
/// for the writer.
final class SQLiteStorageEngineTests: XCTestCase {
    var tempRoot: URL!
    var store: Store!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-sqlite-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = try Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Free space

    func testNewLibraryIsCreatedWithIncrementalAutoVacuum() throws {
        XCTAssertEqual(try store.db.autoVacuumMode(), .incremental)
    }

    func testReclaimReturnsDeletedPagesToTheFilesystem() throws {
        try fillAndDeleteBulkPages()
        let pageSize = try integer("PRAGMA page_size")
        let pagesBefore = try integer("PRAGMA page_count")
        XCTAssertGreaterThan(try integer("PRAGMA freelist_count"), 0)

        let reclaim = try store.reclaimFreeDatabasePages()

        XCTAssertTrue(reclaim.isIncrementalVacuumAvailable)
        XCTAssertGreaterThan(reclaim.reclaimedBytes, 0)
        XCTAssertEqual(reclaim.remainingFreeBytes, 0)
        XCTAssertLessThan(try integer("PRAGMA page_count"), pagesBefore)
        // The bytes have to leave the filesystem, not just the free list.
        XCTAssertLessThan(try databaseFileSize(), pagesBefore * pageSize)
    }

    func testReclaimIsBoundedAndLeavesTheRestForALaterRun() throws {
        try fillAndDeleteBulkPages()
        let freeBefore = try integer("PRAGMA freelist_count")
        XCTAssertGreaterThan(freeBefore, 8)

        let reclaim = try store.reclaimFreeDatabasePages(maxPages: 8)

        XCTAssertGreaterThan(reclaim.remainingFreeBytes, 0)
        XCTAssertEqual(try integer("PRAGMA freelist_count"), freeBefore - 8)
    }

    /// A library created before Screenlogger enabled auto-vacuum has no pointer
    /// map, so bounded reclaiming cannot work until the file is rebuilt.
    func testLegacyLibraryReportsNoIncrementalVacuumUntilItIsCompacted() throws {
        let legacyRoot = try makeLegacyLibrary()
        defer { try? FileManager.default.removeItem(at: legacyRoot) }
        let legacy = try SQLiteDatabase(path: ScreenlogPaths.databaseURL(root: legacyRoot).path)
        XCTAssertEqual(try legacy.autoVacuumMode(), .none)

        let reclaim = try legacy.reclaimFreePages()
        XCTAssertFalse(reclaim.isIncrementalVacuumAvailable)
        XCTAssertEqual(reclaim.reclaimedBytes, 0)
        XCTAssertGreaterThan(reclaim.remainingFreeBytes, 0)

        let compaction = try legacy.compactDatabaseFile()

        XCTAssertGreaterThan(compaction.reclaimedBytes, 0)
        XCTAssertLessThan(compaction.bytesAfter, compaction.bytesBefore)
        XCTAssertEqual(try legacy.autoVacuumMode(), .incremental)
        XCTAssertTrue(try legacy.reclaimFreePages().isIncrementalVacuumAvailable)
    }

    func testCompactionRefusesWithoutRoomForATemporaryCopy() throws {
        XCTAssertThrowsError(try store.db.compactDatabaseFile(freeSpaceMarginBytes: Int64.max)) { error in
            guard case SQLiteMaintenanceError.insufficientFreeSpace = error else {
                return XCTFail("expected a free-space refusal, got \(error)")
            }
        }
    }

    func testRetentionRunReclaimsDatabaseSpaceItFreed() throws {
        try fillAndDeleteBulkPages()

        let report = try RetentionService(
            policy: RetentionPolicy(retentionDays: 30, storageCapMB: 0)
        ).runDetailed(store: store)

        XCTAssertGreaterThan(report.reclaimedDatabaseBytes, 0)
        XCTAssertEqual(try integer("PRAGMA freelist_count"), 0)
        XCTAssertTrue(report.description.contains("reclaimed_db_bytes="), report.description)
    }

    // MARK: - Read connections

    func testReadsRunOnTheirOwnConnectionWhileTheWriterHoldsATransaction() throws {
        let frameID = try store.insertSeedFrame(timestampMs: 1_000, foreground: "committed", title: "before")
        let writerIsHolding = expectation(description: "writer transaction open")
        let writerFinished = expectation(description: "writer transaction finished")
        let readFinished = expectation(description: "read finished during the write transaction")
        let releaseWriter = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            defer { writerFinished.fulfill() }
            do {
                try self.store.db.transaction {
                    try self.store.db.exec("UPDATE frame SET title = 'during' WHERE id = \(frameID)")
                    writerIsHolding.fulfill()
                    releaseWriter.wait()
                }
            } catch {
                XCTFail("writer transaction failed: \(error)")
            }
        }
        wait(for: [writerIsHolding], timeout: 5)

        DispatchQueue.global().async {
            do {
                let row = try self.store.withReadConnection { try self.store.frame(id: frameID) }
                // A separate connection sees the last commit, never the
                // writer's open transaction.
                XCTAssertEqual(row?.title, "before")
                readFinished.fulfill()
            } catch {
                XCTFail("read during write transaction failed: \(error)")
            }
        }
        wait(for: [readFinished], timeout: 5)

        releaseWriter.signal()
        wait(for: [writerFinished], timeout: 5)
        XCTAssertEqual(try store.frame(id: frameID)?.title, "during")
    }

    func testReadScopeSeesEveryCommittedRow() throws {
        let frameID = try store.insertSeedFrame(timestampMs: 2_000, foreground: "visible")
        let row = try store.withReadConnection { try self.store.frame(id: frameID) }
        XCTAssertEqual(row?.foreground, "visible")
    }

    /// The single-writer contract survives nesting: a mutation inside a read
    /// scope goes back to the writer, so it still reads its own uncommitted rows.
    func testMutationNestedInAReadScopeStaysOnTheWriter() throws {
        try store.withReadConnection {
            try store.withSerializedMutation {
                try store.db.transaction {
                    try store.db.exec(
                        "INSERT INTO metadata(key, value) VALUES ('read-scope-probe', 'uncommitted')"
                    )
                    XCTAssertEqual(try store.getMeta(key: "read-scope-probe"), "uncommitted")
                }
            }
        }
        XCTAssertEqual(try store.getMeta(key: "read-scope-probe"), "uncommitted")
    }

    func testReadAsyncServesReadsFromTheReadPath() async throws {
        let frameID = try store.insertSeedFrame(timestampMs: 3_000, foreground: "async")
        let row = try await store.readAsync { try $0.frame(id: frameID) }
        XCTAssertEqual(row?.foreground, "async")
    }

    /// A `:memory:` database belongs to the connection that opened it, so the
    /// read scope has to fall back to the writer instead of opening an empty one.
    func testMemoryDatabaseReadScopeStaysOnTheWriterConnection() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try db.exec("CREATE TABLE probe(id INTEGER PRIMARY KEY)")
        try db.exec("INSERT INTO probe(id) VALUES (7)")

        let value = try db.withReadConnection { () -> Int64 in
            let stmt = try db.prepare("SELECT id FROM probe")
            defer { sqlite3_finalize(stmt) }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            return SQLiteColumn.int64(stmt, 0)
        }

        XCTAssertEqual(value, 7)
    }

    func testNestedReadScopesFromDifferentDatabasesKeepTheirOwnHandles() throws {
        let otherRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-sqlite-other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherRoot) }

        let first = try SQLiteDatabase(path: tempRoot.appendingPathComponent("first.sqlite3").path)
        let second = try SQLiteDatabase(path: otherRoot.appendingPathComponent("second.sqlite3").path)
        try first.exec("CREATE TABLE probe(value TEXT NOT NULL)")
        try first.exec("INSERT INTO probe(value) VALUES ('first')")
        try second.exec("CREATE TABLE probe(value TEXT NOT NULL)")
        try second.exec("INSERT INTO probe(value) VALUES ('second')")

        let values = try first.withReadConnection { () -> (String, String) in
            let firstValue = try readProbeValue(from: first)
            let secondValue = try second.withReadConnection {
                try readProbeValue(from: second)
            }
            return (firstValue, secondValue)
        }

        XCTAssertEqual(values.0, "first")
        XCTAssertEqual(values.1, "second")
    }

    // MARK: - Helpers

    /// Leave a few hundred pages on the free list without touching capture rows.
    private func fillAndDeleteBulkPages() throws {
        try store.db.exec("CREATE TABLE bulk(id INTEGER PRIMARY KEY, payload BLOB)")
        try store.db.transaction {
            let stmt = try store.db.prepare("INSERT INTO bulk(payload) VALUES (?)")
            defer { sqlite3_finalize(stmt) }
            for _ in 0..<600 {
                sqlite3_reset(stmt)
                SQLiteBind.blob(stmt, 1, Data(repeating: 0xAB, count: 8_192))
                XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            }
        }
        try store.db.exec("DELETE FROM bulk")
    }

    private func makeLegacyLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-legacy-\(UUID().uuidString)", isDirectory: true)
        try ScreenlogPaths.ensureDirectories(root: root)
        let path = ScreenlogPaths.databaseURL(root: root).path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        XCTAssertEqual(sqlite3_open_v2(path, &handle, flags, nil), SQLITE_OK)
        let legacy = try XCTUnwrap(handle)
        defer { sqlite3_close(legacy) }
        // No auto_vacuum pragma: this is how every library created before the
        // storage-reclamation fix looks on disk.
        XCTAssertEqual(sqlite3_exec(legacy, "PRAGMA journal_mode = WAL;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(legacy, "CREATE TABLE bulk(id INTEGER PRIMARY KEY, payload BLOB);", nil, nil, nil),
            SQLITE_OK
        )
        let insert = "INSERT INTO bulk(payload) SELECT randomblob(8192) FROM generate_series(1, 600);"
        if sqlite3_exec(legacy, insert, nil, nil, nil) != SQLITE_OK {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(legacy, "INSERT INTO bulk(payload) VALUES (randomblob(8192))", -1, &statement, nil),
                SQLITE_OK
            )
            let prepared = try XCTUnwrap(statement)
            defer { sqlite3_finalize(prepared) }
            for _ in 0..<600 {
                sqlite3_reset(prepared)
                XCTAssertEqual(sqlite3_step(prepared), SQLITE_DONE)
            }
        }
        XCTAssertEqual(sqlite3_exec(legacy, "DELETE FROM bulk;", nil, nil, nil), SQLITE_OK)
        return root
    }

    private func integer(_ sql: String) throws -> Int64 {
        let stmt = try store.db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return SQLiteColumn.int64(stmt, 0)
    }

    private func databaseFileSize() throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: ScreenlogPaths.databaseURL(root: tempRoot).path
        )
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func readProbeValue(from database: SQLiteDatabase) throws -> String {
        let stmt = try database.prepare("SELECT value FROM probe LIMIT 1")
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return try XCTUnwrap(SQLiteColumn.text(stmt, 0))
    }
}
