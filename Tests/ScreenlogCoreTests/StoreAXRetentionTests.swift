import SQLite3
@testable import ScreenlogCore
import XCTest

final class StoreAXRetentionTests: XCTestCase {
    var tempRoot: URL!
    var store: Store!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-ax-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = try Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testContentAddressedAXDeduplicatesNodes() throws {
        let xml = "<AccessibilityTree><Node role=\"AXWindow\" name=\"Shared\" /></AccessibilityTree>"
        let snap = AXTreeSnapshot(
            xml: xml,
            nodeCount: 1,
            bundleID: "dev.ax",
            applicationName: "AXApp",
            pid: 42,
            isPartial: false,
            extractionMode: "xml_full"
        )

        let f1 = try store.insertSeedFrame(timestampMs: 1, foreground: "frame1")
        let f2 = try store.insertSeedFrame(timestampMs: 2, foreground: "frame2")
        try store.storeAXSnapshot(frameID: f1, snapshot: snap)
        try store.storeAXSnapshot(frameID: f2, snapshot: snap)

        XCTAssertEqual(try countAXNodes(), 1, "identical payloads share one ax_node")
        XCTAssertEqual(try countAXSnapshots(), 2)

        let hash1 = try store.frame(id: f1)?.axRootHash
        let hash2 = try store.frame(id: f2)?.axRootHash
        XCTAssertEqual(hash1, hash2)
        XCTAssertEqual(hash1?.count, 32)

        XCTAssertEqual(try store.axTreeXML(frameID: f1), xml)
        XCTAssertEqual(try store.axTreeXML(frameID: f2), xml)
    }

    func testDistinctAXPayloadsCreateDistinctNodes() throws {
        let f1 = try store.insertSeedFrame(timestampMs: 1, foreground: "a")
        let f2 = try store.insertSeedFrame(timestampMs: 2, foreground: "b")
        try store.storeAXSnapshot(
            frameID: f1,
            snapshot: AXTreeSnapshot(xml: "<A/>", nodeCount: 1, pid: 1, isPartial: false)
        )
        try store.storeAXSnapshot(
            frameID: f2,
            snapshot: AXTreeSnapshot(xml: "<B/>", nodeCount: 1, pid: 1, isPartial: false)
        )
        XCTAssertEqual(try countAXNodes(), 2)
        XCTAssertNotEqual(
            try store.frame(id: f1)?.axRootHash,
            try store.frame(id: f2)?.axRootHash
        )
    }

    func testAXPayloadCodecCompressesAndRoundTripsLargeTrees() throws {
        let xml =
            "<AccessibilityTree>" + String(repeating: "<Node role=\"AXStaticText\" value=\"Repeated text\" />", count: 2_000)
            + "</AccessibilityTree>"
        let raw = Data(xml.utf8)
        let encoded = AXPayloadCodec.encode(raw)

        XCTAssertLessThan(encoded.count, raw.count / 2)
        XCTAssertEqual(AXPayloadCodec.decode(encoded), raw)
    }

    func testAXPayloadCodecReadsLegacyRawPayloads() {
        let legacy = Data("<AccessibilityTree />".utf8)
        XCTAssertEqual(AXPayloadCodec.decode(legacy), legacy)
    }

    func testAXPayloadCodecRejectsTruncatedCompressedPayload() throws {
        let raw = Data(String(repeating: "repeated accessibility text ", count: 4_000).utf8)
        var encoded = AXPayloadCodec.encode(raw)
        XCTAssertLessThan(encoded.count, raw.count)
        encoded.removeLast()
        XCTAssertNil(AXPayloadCodec.decode(encoded))
    }

    func testStoredAXPayloadIsCompressedWithoutChangingContentHash() throws {
        let xml =
            "<AccessibilityTree>" + String(repeating: "<Node role=\"AXButton\" title=\"Save\" />", count: 500)
            + "</AccessibilityTree>"
        let frameID = try store.insertSeedFrame(timestampMs: 20, foreground: "compressed")
        try store.storeAXSnapshot(
            frameID: frameID,
            snapshot: AXTreeSnapshot(xml: xml, nodeCount: 500, pid: 7, isPartial: false)
        )

        let payload = try XCTUnwrap(storedPayload(frameID: frameID))
        XCTAssertLessThan(payload.count, Data(xml.utf8).count)
        XCTAssertEqual(try store.axTreeXML(frameID: frameID), xml)
        XCTAssertEqual(try store.frame(id: frameID)?.axRootHash, ContentHash.sha256(Data(xml.utf8)))
    }

    func testAXSnapshotUpsertAndEdges() throws {
        let frameID = try store.insertSeedFrame(timestampMs: 9, foreground: "edge")
        try store.storeAXSnapshot(
            frameID: frameID,
            snapshot: AXTreeSnapshot(
                xml: "<root/>",
                nodeCount: 1,
                bundleID: "dev.edge",
                applicationName: "Edge",
                pid: 7,
                isPartial: true,
                extractionMode: "partial"
            )
        )
        // Upsert same frame with fuller tree
        try store.storeAXSnapshot(
            frameID: frameID,
            snapshot: AXTreeSnapshot(
                xml: "<root><child/></root>",
                nodeCount: 2,
                bundleID: "dev.edge",
                applicationName: "Edge",
                pid: 7,
                isPartial: false,
                extractionMode: "xml_full"
            )
        )
        XCTAssertEqual(try store.axTreeXML(frameID: frameID), "<root><child/></root>")
        XCTAssertEqual(try countAXSnapshots(), 1)

        let parent = ContentHash.sha256(Data("<parent/>".utf8))
        let child = ContentHash.sha256(Data("<child/>".utf8))
        // Insert nodes so FK-less edge store works (edges don't require nodes, but we still test insert)
        try insertNode(hash: parent, payload: Data("<parent/>".utf8), frameID: frameID)
        try insertNode(hash: child, payload: Data("<child/>".utf8), frameID: frameID)
        try store.storeAXNodeEdge(parentHash: parent, childHash: child)
        try store.storeAXNodeEdge(parentHash: parent, childHash: child)  // idempotent
        XCTAssertEqual(try countAXEdges(), 1)
    }

    func testMissingAXReturnsNil() throws {
        let frameID = try store.insertSeedFrame(timestampMs: 1, foreground: "no-ax")
        XCTAssertNil(try store.axTreeXML(frameID: frameID))
        XCTAssertNil(try store.axTreeXML(frameID: 999_999))
    }

    func testVersionedMigrationPreservesPayloadsHashesCountsAndReferences() throws {
        let fixtures = try insertRawSnapshots(count: 70)
        let legacyFrame = try store.insertSeedFrame(timestampMs: 100, foreground: "legacy")
        let legacyXML = "<Legacy>" + String(repeating: "preserve this text ", count: 2_000) + "</Legacy>"
        let legacy = try store.db.prepare("INSERT INTO ax_legacy_tree(frame_id, payload) VALUES (?, ?)")
        SQLiteBind.int64(legacy, 1, legacyFrame)
        SQLiteBind.blob(legacy, 2, Data(legacyXML.utf8))
        XCTAssertEqual(sqlite3_step(legacy), SQLITE_DONE)
        sqlite3_finalize(legacy)
        let compressedFrame = try store.insertSeedFrame(timestampMs: 101, foreground: "already compressed")
        try store.storeAXSnapshot(
            frameID: compressedFrame,
            snapshot: AXTreeSnapshot(xml: legacyXML, nodeCount: 1, pid: 1, isPartial: false)
        )
        let compressedBefore = try storedPayload(frameID: compressedFrame)

        let report = try migrateAllPayloads()

        XCTAssertEqual(report.count, 71)
        XCTAssertGreaterThan(report.bytesSaved, 0)
        XCTAssertTrue(report.pending)
        XCTAssertEqual(try countAXNodes(), 71)
        XCTAssertEqual(try countAXSnapshots(), 71)
        for fixture in fixtures {
            XCTAssertEqual(try store.axTreeXML(frameID: fixture.frameID), fixture.xml)
            XCTAssertEqual(
                try store.frame(id: fixture.frameID)?.axRootHash,
                ContentHash.sha256(Data(fixture.xml.utf8))
            )
            XCTAssertTrue(AXPayloadCodec.isEncoded(try XCTUnwrap(storedPayload(frameID: fixture.frameID))))
        }
        XCTAssertEqual(try store.axTreeXML(frameID: legacyFrame), legacyXML)
        XCTAssertEqual(try storedPayload(frameID: compressedFrame), compressedBefore)
        XCTAssertEqual(try scalarCount("SELECT COUNT(*) FROM ax_legacy_tree"), 1)
        XCTAssertTrue(try store.db.foreignKeyViolations().isEmpty)
        let reclaimed = try XCTUnwrap(store.reclaimMigratedDatabaseSpace())
        XCTAssertGreaterThan(reclaimed.reclaimedBytes, 0)
        XCTAssertNil(try store.reclaimMigratedDatabaseSpace())
        let repeated = try store.migrateDatabasePayloadBatch()
        XCTAssertTrue(repeated.isComplete)
        XCTAssertFalse(repeated.reclamationPending)
        XCTAssertEqual(repeated.scannedPayloadCount, 0)
        XCTAssertEqual(repeated.compressedPayloadCount, 0)
    }

    func testReclamationDefersForLowSpaceWithoutUndoingMigration() throws {
        let fixture = try XCTUnwrap(insertRawSnapshots(count: 1).first)
        _ = try migrateAllPayloads()
        XCTAssertThrowsError(try store.reclaimMigratedDatabaseSpace(freeSpaceMarginBytes: Int64.max)) { error in
            guard case SQLiteMaintenanceError.insufficientFreeSpace = error else {
                return XCTFail("expected disk-headroom refusal, got \(error)")
            }
        }
        XCTAssertTrue(try store.migrateDatabasePayloadBatch().reclamationPending)
        XCTAssertTrue(AXPayloadCodec.isEncoded(try XCTUnwrap(storedPayload(frameID: fixture.frameID))))
        XCTAssertEqual(try store.axTreeXML(frameID: fixture.frameID), fixture.xml)
        XCTAssertNotNil(try store.reclaimMigratedDatabaseSpace())
        XCTAssertFalse(try store.migrateDatabasePayloadBatch().reclamationPending)
    }

    func testVersionedMigrationResumesAfterFailedBatchAndReopen() throws {
        let fixtures = try insertRawSnapshots(count: 70)
        try store.db.exec(
            """
            CREATE TRIGGER reject_ax_optimization BEFORE UPDATE OF payload ON ax_node
            WHEN OLD.first_seen_frame_id = \(fixtures[40].frameID)
            BEGIN SELECT RAISE(ABORT, 'fixture batch failure'); END
            """
        )

        XCTAssertEqual(try store.migrateDatabasePayloadBatch().compressedPayloadCount, 32)
        XCTAssertThrowsError(try store.migrateDatabasePayloadBatch())
        XCTAssertTrue(AXPayloadCodec.isEncoded(try XCTUnwrap(storedPayload(frameID: fixtures[0].frameID))))
        XCTAssertFalse(AXPayloadCodec.isEncoded(try XCTUnwrap(storedPayload(frameID: fixtures[32].frameID))))
        for fixture in fixtures {
            XCTAssertEqual(try store.axTreeXML(frameID: fixture.frameID), fixture.xml)
        }
        try store.db.exec("DROP TRIGGER reject_ax_optimization")
        try store.db.close()
        store = try Store(root: tempRoot)
        let report = try migrateAllPayloads()
        XCTAssertEqual(report.count, 38)
        for fixture in fixtures {
            XCTAssertEqual(try store.axTreeXML(frameID: fixture.frameID), fixture.xml)
        }
    }

    func testVersionedMigrationLeavesNonBeneficialPayloadsUnchanged() throws {
        let frameID = try store.insertSeedFrame(timestampMs: 1, foreground: "small tree")
        let raw = Data("<A/>".utf8)
        try insertNode(hash: ContentHash.sha256(raw), payload: raw, frameID: frameID)
        try store.storeAXSnapshot(
            frameID: frameID,
            snapshot: AXTreeSnapshot(xml: "<A/>", nodeCount: 1, pid: 1, isPartial: false)
        )

        let report = try migrateAllPayloads()

        XCTAssertEqual(report.count, 0)
        XCTAssertEqual(report.bytesSaved, 0)
        XCTAssertFalse(report.pending)
        XCTAssertEqual(try storedPayload(frameID: frameID), raw)
    }

    func testMigrationBoundsLargePayloadBatches() throws {
        for index in 0..<3 {
            let raw = Data((String(index) + String(repeating: "large payload ", count: 400_000)).utf8)
            let frameID = try store.insertSeedFrame(timestampMs: Int64(index), foreground: "large")
            try insertNode(hash: ContentHash.sha256(raw), payload: raw, frameID: frameID)
        }
        let first = try store.migrateDatabasePayloadBatch()
        XCTAssertEqual(first.scannedPayloadCount, 1)
        XCTAssertEqual(first.compressedPayloadCount, 1)
        XCTAssertFalse(first.isComplete)
        // A separate mutation can commit between migration batches.
        try store.setMeta(key: "fixture.interleaved", value: "written")
        XCTAssertEqual(try migrateAllPayloads().count, 2)
        XCTAssertEqual(try store.getMeta(key: "fixture.interleaved"), "written")
        XCTAssertEqual(try countAXNodes(), 3)
    }

    func testNewLibraryCompletesWithoutReclamation() throws {
        let report = try migrateAllPayloads()
        XCTAssertEqual(report.count, 0)
        XCTAssertFalse(report.pending)
        XCTAssertNil(try store.reclaimMigratedDatabaseSpace())
    }

    func testCompletedMarkerAvoidsPayloadTableScans() throws {
        _ = try migrateAllPayloads()
        // Removing these tables makes any accidental rescan fail immediately.
        try store.db.exec("DROP TABLE ax_legacy_tree; DROP TABLE ax_node;")
        let batch = try store.migrateDatabasePayloadBatch()
        XCTAssertTrue(batch.isComplete)
        XCTAssertEqual(batch.scannedPayloadCount, 0)
    }

    func testMigrationCancellationKeepsCommittedCursorForRestart() async throws {
        let fixtures = try insertRawSnapshots(count: 70)
        XCTAssertEqual(try store.migrateDatabasePayloadBatch().compressedPayloadCount, 32)
        let currentStore = try XCTUnwrap(store)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try currentStore.migrateDatabasePayloadBatch()
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // The interrupted call must not advance progress.
        }
        try store.db.close()
        store = try Store(root: tempRoot)
        XCTAssertEqual(try migrateAllPayloads().count, 38)
        for fixture in fixtures {
            XCTAssertEqual(try store.axTreeXML(frameID: fixture.frameID), fixture.xml)
        }
    }

    func testPinnedReaderDefersReclamationAndRetryPreservesHistory() throws {
        let fixtures = try insertRawSnapshots(count: 3)
        _ = try migrateAllPayloads()
        var reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(store.db.path, &reader, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(reader) }
        XCTAssertEqual(sqlite3_exec(reader, "BEGIN; SELECT count(*) FROM ax_node;", nil, nil, nil), SQLITE_OK)
        // Put a committed page beyond the reader's end mark.
        try store.setMeta(key: "fixture.reader", value: "pinned")
        XCTAssertThrowsError(try store.reclaimMigratedDatabaseSpace()) { error in
            guard case SQLiteMaintenanceError.checkpointBlocked = error else {
                return XCTFail("expected pinned checkpoint, got \(error)")
            }
        }
        XCTAssertTrue(try store.migrateDatabasePayloadBatch().reclamationPending)
        XCTAssertEqual(sqlite3_exec(reader, "COMMIT;", nil, nil, nil), SQLITE_OK)
        XCTAssertNotNil(try store.reclaimMigratedDatabaseSpace())
        XCTAssertEqual(try countAXSnapshots(), fixtures.count)
        for fixture in fixtures {
            XCTAssertEqual(try store.axTreeXML(frameID: fixture.frameID), fixture.xml)
        }
    }

    // MARK: - Helpers

    private func migrateAllPayloads() throws -> (count: Int, bytesSaved: Int64, pending: Bool) {
        var count = 0
        var saved: Int64 = 0
        while true {
            let batch = try store.migrateDatabasePayloadBatch()
            XCTAssertLessThanOrEqual(batch.scannedPayloadCount, 32)
            count += batch.compressedPayloadCount
            saved += batch.payloadBytesSaved
            if batch.isComplete { return (count, saved, batch.reclamationPending) }
        }
    }

    private func insertRawSnapshots(count: Int) throws -> [(frameID: Int64, xml: String)] {
        try (0..<count).map { index in
            let frameID = try store.insertSeedFrame(timestampMs: Int64(index + 1), foreground: "raw AX")
            let xml = "<Tree id=\"\(index)\">" + String(repeating: "<Node title=\"Repeated text\" />", count: 2_000) + "</Tree>"
            let raw = Data(xml.utf8)
            try insertNode(hash: ContentHash.sha256(raw), payload: raw, frameID: frameID)
            // Models an old raw node being reused after compression was added:
            // INSERT OR IGNORE must not replace its payload.
            try store.storeAXSnapshot(
                frameID: frameID,
                snapshot: AXTreeSnapshot(xml: xml, nodeCount: 2_000, pid: 1, isPartial: false)
            )
            return (frameID, xml)
        }
    }

    private func countAXNodes() throws -> Int {
        try scalarCount("SELECT COUNT(*) FROM ax_node")
    }

    private func countAXSnapshots() throws -> Int {
        try scalarCount("SELECT COUNT(*) FROM ax_snapshot")
    }

    private func countAXEdges() throws -> Int {
        try scalarCount("SELECT COUNT(*) FROM ax_node_edge")
    }

    private func storedPayload(frameID: Int64) throws -> Data? {
        let stmt = try store.db.prepare(
            "SELECT n.payload FROM ax_snapshot s JOIN ax_node n ON n.hash = s.root_hash WHERE s.frame_id = ?"
        )
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.int64(stmt, 1, frameID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return SQLiteColumn.data(stmt, 0)
    }

    private func scalarCount(_ sql: String) throws -> Int {
        let stmt = try store.db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(SQLiteColumn.int64(stmt, 0))
    }

    private func insertNode(hash: Data, payload: Data, frameID: Int64) throws {
        let stmt = try store.db.prepare(
            "INSERT OR IGNORE INTO ax_node(hash, payload, first_seen_frame_id) VALUES(?, ?, ?)"
        )
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.blob(stmt, 1, hash)
        SQLiteBind.blob(stmt, 2, payload)
        SQLiteBind.int64(stmt, 3, frameID)
        _ = sqlite3_step(stmt)
    }
}
