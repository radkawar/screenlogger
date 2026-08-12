import SQLite3
import XCTest

@testable import ScreenlogCore

/// Verifies required covering indexes exist after migration.
final class SchemaIndexTests: XCTestCase {
    var tempRoot: URL!
    var store: Store!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = try Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testRequiredIndexesPresent() throws {
        let required: Set<String> = [
            // frame / time / video
            "idx_frame_timestamp",
            "idx_frame_segment",
            "idx_frame_video",
            "idx_frame_timestamp_segment",
            "idx_frame_window_covering",
            "idx_frame_video_timestamp",
            // segment to application lookup path
            "idx_segment_application",
            "idx_segment_start_frame",
            "idx_segment_domain",
            // OCR / window
            "idx_ocr_frame",
            "idx_window_bound_frame",
            "idx_window_bound_application",
            "idx_transcript_segment_frame",
            "idx_transcript_segment_time",
            // app / domain
            "idx_application_bundle_id",
            "idx_domain_normalized",
            // video status partial
            "idx_video_status",
            // AX lookups
            "idx_ax_node_first_seen_frame_id",
            "idx_ax_node_edge_child",
            "idx_ax_snapshot_root_hash",
            // aux
            "idx_app_version_observed_at",
            "idx_timezone_observed_at",
        ]

        let present = try indexNames(in: store.db)
        let missing = required.subtracting(present)
        XCTAssertTrue(missing.isEmpty, "Missing required indexes: \(missing.sorted())")
    }

    func testFTSVirtualTableAndTriggersExist() throws {
        let tables = try masterNames(type: "table", in: store.db)
        // FTS5 may show as table in sqlite_master
        XCTAssertTrue(tables.contains("ocr_fts") || tables.contains("ocr_fts_data"), "ocr_fts FTS5 table required")
        XCTAssertTrue(
            tables.contains("transcript_fts") || tables.contains("transcript_fts_data"),
            "transcript_fts FTS5 table required"
        )

        let triggers = try masterNames(type: "trigger", in: store.db)
        XCTAssertTrue(triggers.contains("frame_ai"))
        XCTAssertTrue(triggers.contains("frame_ad"))
        XCTAssertTrue(triggers.contains("frame_au"))
        XCTAssertTrue(triggers.contains("transcript_segment_ai"))
        XCTAssertTrue(triggers.contains("transcript_segment_ad"))
        XCTAssertTrue(triggers.contains("transcript_segment_au"))
    }

    func testSchemaVersionIsCurrent() throws {
        let stmt = try store.db.prepare("SELECT COALESCE(MAX(version), 0) FROM schema_migrations")
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(SQLiteColumn.int64(stmt, 0), Int64(Schema.currentVersion))
    }

    func testNearestFrameDirectionalProbesUseTimestampIndex() throws {
        for comparisonAndOrder in [("<=", "DESC"), (">=", "ASC")] {
            let (comparison, order) = comparisonAndOrder
            let stmt = try store.db.prepare(
                """
                EXPLAIN QUERY PLAN
                SELECT id FROM frame
                WHERE timestamp \(comparison) ?
                ORDER BY timestamp \(order), id ASC
                LIMIT 1
                """
            )
            defer { sqlite3_finalize(stmt) }
            SQLiteBind.int64(stmt, 1, 1_000)
            var details: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let detail = SQLiteColumn.text(stmt, 3) {
                    details.append(detail)
                }
            }
            XCTAssertTrue(
                details.contains { $0.contains("SEARCH frame USING") },
                "Expected an indexed frame search, got: \(details)"
            )
            XCTAssertFalse(
                details.contains { $0.contains("SCAN frame") },
                "Nearest-frame lookup must not scan the frame table: \(details)"
            )
        }
    }

    func testCoreTablesExist() throws {
        let tables = try masterNames(type: "table", in: store.db)
        for name in [
            "frame", "ocr", "segment", "application", "domain", "video",
            "window_bound", "metadata", "ax_node", "ax_node_edge", "ax_snapshot",
            "ax_legacy_tree", "once_tasks", "app_version", "timezone",
            "transcript_segment",
        ] {
            XCTAssertTrue(tables.contains(name), "missing table \(name)")
        }
    }

    // MARK: - Helpers

    private func indexNames(in db: SQLiteDatabase) throws -> Set<String> {
        let stmt = try db.prepare(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'"
        )
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let n = SQLiteColumn.text(stmt, 0) {
                names.insert(n)
            }
        }
        return names
    }

    private func masterNames(type: String, in db: SQLiteDatabase) throws -> Set<String> {
        let stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type = ?")
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.text(stmt, 1, type)
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let n = SQLiteColumn.text(stmt, 0) {
                names.insert(n)
            }
        }
        return names
    }
}
