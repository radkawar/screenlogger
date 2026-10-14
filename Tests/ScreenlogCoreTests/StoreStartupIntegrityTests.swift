import Foundation
import SQLite3
import XCTest

@testable import ScreenlogCore

final class StoreStartupIntegrityTests: XCTestCase {
    func testStartupRemovesOnlyCanonicalUnreferencedManagedStills() throws {
        let root = temporaryRoot("orphan-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        var store: Store? = try Store(root: root)
        let frameID = try XCTUnwrap(store).insertSeedFrame(
            timestampMs: 1_700_000_000_000,
            foreground: "referenced"
        )
        let referenced = try XCTUnwrap(try XCTUnwrap(store).frame(id: frameID)?.imagePath)
        let frames = try XCTUnwrap(store).framesDirectory

        let orphan = frames.appendingPathComponent("ffffffffffffffff.heic")
        let noncanonical = frames.appendingPathComponent("keep-me.heic")
        let symlink = frames.appendingPathComponent("eeeeeeeeeeeeeeee.jpg")
        let recoveryDirectory = frames.appendingPathComponent(".retention-recovery", isDirectory: true)
        let recoveryFile = recoveryDirectory.appendingPathComponent("dddddddddddddddd.heic")
        try Data([1]).write(to: orphan)
        try Data([2]).write(to: noncanonical)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: noncanonical)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        try Data([3]).write(to: recoveryFile)

        store = nil
        store = try Store(root: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: referenced))
        XCTAssertTrue(FileManager.default.fileExists(atPath: noncanonical.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryFile.path))
        XCTAssertEqual(try store?.stats().totalFrames, 1)
    }

    func testStartupRemovesOnlyCanonicalUnreferencedCompactionVideos() throws {
        let root = temporaryRoot("video-orphan-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        var store: Store? = try Store(root: root)
        let videos = ScreenlogPaths.videosDirectory(root: root)

        let referenced = videos.appendingPathComponent("v_1_2_DEADBEEF.mp4")
        let orphan = videos.appendingPathComponent("v_3_4_0123ABCD.mp4")
        let interruptedTemporary = videos.appendingPathComponent("v_5_6_89ABCDEF.tmp.mp4")
        let noncanonical = videos.appendingPathComponent("keep-me.mp4")
        let canonicalSymlink = videos.appendingPathComponent("v_7_8_AABBCCDD.mp4")
        let recoveryDirectory = videos.appendingPathComponent(
            ".retention-recovery",
            isDirectory: true
        )
        let recoveryFile = recoveryDirectory.appendingPathComponent("video-99.mp4")
        try Data([1]).write(to: referenced)
        try Data([2]).write(to: orphan)
        try Data([3]).write(to: interruptedTemporary)
        try Data([4]).write(to: noncanonical)
        try FileManager.default.createSymbolicLink(
            at: canonicalSymlink,
            withDestinationURL: noncanonical
        )
        try FileManager.default.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true
        )
        try Data([5]).write(to: recoveryFile)
        _ = try XCTUnwrap(store).insertVideo(
            path: referenced.path,
            numFrames: 2,
            sizeBytes: 1
        )

        store = nil
        store = try Store(root: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: interruptedTemporary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: noncanonical.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalSymlink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryFile.path))
    }

    func testFutureSchemaVersionFailsClosedWithoutChangingVersion() throws {
        let root = temporaryRoot("future-schema")
        defer { try? FileManager.default.removeItem(at: root) }
        try ScreenlogPaths.ensureDirectories(root: root)
        do {
            let db = try SQLiteDatabase(path: ScreenlogPaths.databaseURL(root: root).path)
            try db.exec("CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY NOT NULL)")
            try db.exec("INSERT INTO schema_migrations(version) VALUES (999)")
        }

        XCTAssertThrowsError(try Store(root: root)) { error in
            guard case StoreStartupError.schemaMigrationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let db = try SQLiteDatabase(path: ScreenlogPaths.databaseURL(root: root).path)
        XCTAssertEqual(try scalar("SELECT MAX(version) FROM schema_migrations", db: db), 999)
    }

    func testVersionThreeLibraryWithCapturedRelationshipsMigratesAtomically() throws {
        let root = temporaryRoot("version-three-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        try ScreenlogPaths.ensureDirectories(root: root)
        do {
            let db = try SQLiteDatabase(path: ScreenlogPaths.databaseURL(root: root).path)
            try createVersionThreeSchema(db)
            try db.exec(
                """
                INSERT INTO application(bundle_id, display_name, icon_path)
                VALUES('dev.screenlog.migration-fixture', 'Migration Fixture', NULL);
                INSERT INTO segment(start_frame_id, application, domain, url)
                VALUES(1, 1, NULL, NULL);
                INSERT INTO frame(timestamp, foreground, background, title, segment)
                VALUES(1700000000000, 'upgrade relationship phrase', '', 'Fixture', 1);
                """
            )
        }

        let store = try Store(root: root)

        XCTAssertEqual(try store.stats().totalFrames, 1)
        XCTAssertEqual(
            try store.ftsSearch(query: "upgrade relationship phrase", limit: 10).map(\.frameID),
            [1]
        )
        XCTAssertTrue(try store.db.foreignKeyViolations().isEmpty)
        XCTAssertEqual(try scalar("PRAGMA foreign_keys", db: store.db), 1)
        XCTAssertEqual(
            try scalar("SELECT MAX(version) FROM schema_migrations", db: store.db),
            Int64(Schema.currentVersion)
        )
        XCTAssertEqual(
            try scalar("SELECT application FROM segment WHERE id = 1", db: store.db),
            1
        )
    }

    func testVersionThreeMigrationRollsBackWhenLegacyRelationshipsAreInvalid() throws {
        let root = temporaryRoot("version-three-invalid-relationship")
        defer { try? FileManager.default.removeItem(at: root) }
        try ScreenlogPaths.ensureDirectories(root: root)
        do {
            let db = try SQLiteDatabase(path: ScreenlogPaths.databaseURL(root: root).path)
            try createVersionThreeSchema(db)
            try db.exec("PRAGMA foreign_keys = OFF")
            try db.exec(
                """
                INSERT INTO segment(id, start_frame_id, application, domain, url)
                VALUES(1, 1, 999, NULL, NULL);
                INSERT INTO frame(id, timestamp, foreground, segment)
                VALUES(1, 1700000000000, 'invalid relationship', 1);
                """
            )
            try db.exec("PRAGMA foreign_keys = ON")
        }

        XCTAssertThrowsError(try Store(root: root)) { error in
            guard case StoreStartupError.schemaMigrationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let db = try SQLiteDatabase(path: ScreenlogPaths.databaseURL(root: root).path)
        XCTAssertEqual(try scalar("SELECT MAX(version) FROM schema_migrations", db: db), 3)
        XCTAssertEqual(try scalar("PRAGMA foreign_keys", db: db), 1)
        XCTAssertFalse(try columnNames("application", db: db).contains("version"))
    }

    func testVersionFourAccessibilityPayloadMigratesWithoutLosingItsFrame() throws {
        let root = temporaryRoot("version-four-accessibility")
        defer { try? FileManager.default.removeItem(at: root) }
        try ScreenlogPaths.ensureDirectories(root: root)
        do {
            let db = try SQLiteDatabase(path: ScreenlogPaths.databaseURL(root: root).path)
            try createVersionThreeSchema(db)
            try db.exec(
                """
                DELETE FROM schema_migrations;
                INSERT INTO schema_migrations(version) VALUES(4);
                CREATE TABLE ax_snapshot (
                    frame_id INTEGER PRIMARY KEY REFERENCES frame(id) ON DELETE CASCADE,
                    payload TEXT NOT NULL,
                    node_count INTEGER NOT NULL DEFAULT 0,
                    bundle_id TEXT,
                    application_name TEXT,
                    process_identifier INTEGER,
                    is_partial INTEGER NOT NULL DEFAULT 0,
                    timestamp_ms INTEGER NOT NULL
                );
                CREATE TABLE ax_node (
                    hash TEXT PRIMARY KEY,
                    payload TEXT NOT NULL,
                    first_seen_frame_id INTEGER
                );
                INSERT INTO application(bundle_id, display_name)
                VALUES('dev.screenlog.ax-migration', 'AX Migration');
                INSERT INTO segment(id, start_frame_id, application) VALUES(1, 1, 1);
                INSERT INTO frame(id, timestamp, foreground, segment)
                VALUES(1, 1700000000000, 'accessibility migration', 1);
                INSERT INTO ax_snapshot(
                    frame_id, payload, node_count, bundle_id, application_name,
                    process_identifier, is_partial, timestamp_ms
                ) VALUES(
                    1, '<AccessibilityTree><Node role="AXWindow" /></AccessibilityTree>',
                    1, 'dev.screenlog.ax-migration', 'AX Migration', 42, 0, 1700000000000
                );
                """
            )
        }

        let store = try Store(root: root)

        XCTAssertEqual(
            try store.axTreeXML(frameID: 1),
            "<AccessibilityTree><Node role=\"AXWindow\" /></AccessibilityTree>"
        )
        XCTAssertEqual(try store.frame(id: 1)?.axRootHash?.count, 32)
        XCTAssertEqual(try store.stats().totalFrames, 1)
        XCTAssertTrue(try store.db.foreignKeyViolations().isEmpty)
    }

    func testFailedFreshMigrationRollsBackEverySchemaChange() throws {
        let root = temporaryRoot("atomic-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        try ScreenlogPaths.ensureDirectories(root: root)
        let db = try SQLiteDatabase(path: ScreenlogPaths.databaseURL(root: root).path)
        // The fresh migration's application index requires `bundle_id`; this
        // deliberately incompatible preexisting table fails after earlier DDL.
        try db.exec("CREATE TABLE application (wrong_column TEXT)")

        XCTAssertThrowsError(try Schema.migrate(db))

        XCTAssertFalse(try tableExists("metadata", db: db))
        XCTAssertFalse(try tableExists("schema_migrations", db: db))
        XCTAssertTrue(try tableExists("application", db: db))
        XCTAssertEqual(try columnNames("application", db: db), ["wrong_column"])
    }

    func testForeignKeyCorruptionFailsClosedAtReopen() throws {
        let root = temporaryRoot("foreign-key-check")
        defer { try? FileManager.default.removeItem(at: root) }
        var store: Store? = try Store(root: root)
        try XCTUnwrap(store).db.exec("PRAGMA foreign_keys = OFF")
        try XCTUnwrap(store).db.exec(
            """
            INSERT INTO ocr(frame, x, y, width, height, text_offset, text_length)
            VALUES(987654321, 0, 0, 1, 1, 0, 1)
            """
        )
        try XCTUnwrap(store).db.exec("PRAGMA foreign_keys = ON")
        store = nil

        XCTAssertThrowsError(try Store(root: root)) { error in
            guard case StoreStartupError.schemaValidationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCurrentVersionMarkerCannotHideIncompleteSchema() throws {
        let root = temporaryRoot("incomplete-current-schema")
        defer { try? FileManager.default.removeItem(at: root) }
        try ScreenlogPaths.ensureDirectories(root: root)
        do {
            let db = try SQLiteDatabase(path: ScreenlogPaths.databaseURL(root: root).path)
            try db.exec("CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY NOT NULL)")
            try db.exec("INSERT INTO schema_migrations(version) VALUES (\(Schema.currentVersion))")
        }

        XCTAssertThrowsError(try Store(root: root)) { error in
            guard case StoreStartupError.schemaValidationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMalformedDatabaseFailsClosedBeforeCreatingSchema() throws {
        let root = temporaryRoot("malformed-database")
        defer { try? FileManager.default.removeItem(at: root) }
        try ScreenlogPaths.ensureDirectories(root: root)
        let databaseURL = ScreenlogPaths.databaseURL(root: root)
        try Data("not a sqlite database".utf8).write(to: databaseURL)

        XCTAssertThrowsError(try Store(root: root)) { error in
            guard case StoreStartupError.databaseUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), Data("not a sqlite database".utf8))
    }

    private func temporaryRoot(_ purpose: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("screenlog-\(purpose)-\(UUID().uuidString)", isDirectory: true)
    }

    private func createVersionThreeSchema(_ db: SQLiteDatabase) throws {
        try db.exec(
            """
            CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY NOT NULL);
            INSERT INTO schema_migrations(version) VALUES(3);
            CREATE TABLE meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT,
                updated_at INTEGER
            );
            CREATE TABLE application (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                bundle_id TEXT NOT NULL UNIQUE,
                display_name TEXT,
                icon_path TEXT
            );
            CREATE TABLE domain (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                normalized_domain TEXT NOT NULL UNIQUE,
                common_name TEXT
            );
            CREATE TABLE segment (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                start_frame_id INTEGER NOT NULL,
                application INTEGER REFERENCES application(id),
                domain INTEGER REFERENCES domain(id),
                url TEXT
            );
            CREATE INDEX idx_segment_start_frame ON segment(start_frame_id);
            CREATE INDEX idx_segment_application ON segment(application);
            CREATE INDEX idx_segment_domain ON segment(domain);
            CREATE TABLE video (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                height INTEGER NOT NULL,
                width INTEGER NOT NULL,
                path TEXT NOT NULL,
                num_frames INTEGER NOT NULL,
                size_bytes INTEGER,
                status INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE frame (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL,
                video INTEGER REFERENCES video(id),
                video_index INTEGER,
                image_path TEXT,
                width INTEGER,
                height INTEGER,
                foreground TEXT,
                background TEXT,
                title TEXT,
                segment INTEGER REFERENCES segment(id),
                is_inactive INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX idx_frame_timestamp ON frame(timestamp);
            CREATE INDEX idx_frame_segment ON frame(segment);
            CREATE INDEX idx_frame_video ON frame(video);
            CREATE TABLE ocr (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                frame INTEGER NOT NULL REFERENCES frame(id) ON DELETE CASCADE,
                x INTEGER NOT NULL,
                y INTEGER NOT NULL,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                text_offset INTEGER NOT NULL,
                text_length INTEGER NOT NULL
            );
            CREATE INDEX idx_ocr_frame ON ocr(frame);
            CREATE TABLE window_bound (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                frame INTEGER NOT NULL REFERENCES frame(id) ON DELETE CASCADE,
                application INTEGER REFERENCES application(id),
                window_title TEXT,
                x INTEGER NOT NULL,
                y INTEGER NOT NULL,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                window_layer INTEGER NOT NULL DEFAULT 0,
                z_order INTEGER NOT NULL DEFAULT 0,
                url TEXT
            );
            CREATE INDEX idx_window_bound_frame ON window_bound(frame);
            CREATE VIRTUAL TABLE ocr_fts USING fts5(
                foreground,
                background,
                title,
                content='frame',
                content_rowid='id',
                tokenize='porter unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER frame_ai AFTER INSERT ON frame BEGIN
                INSERT INTO ocr_fts(rowid, foreground, background, title)
                VALUES (new.id, new.foreground, new.background, new.title);
            END;
            CREATE TRIGGER frame_ad AFTER DELETE ON frame BEGIN
                INSERT INTO ocr_fts(ocr_fts, rowid, foreground, background, title)
                VALUES('delete', old.id, old.foreground, old.background, old.title);
            END;
            CREATE TRIGGER frame_au AFTER UPDATE ON frame
            WHEN OLD.foreground IS NOT NEW.foreground
              OR OLD.background IS NOT NEW.background
              OR OLD.title IS NOT NEW.title
            BEGIN
                INSERT INTO ocr_fts(ocr_fts, rowid, foreground, background, title)
                VALUES('delete', old.id, old.foreground, old.background, old.title);
                INSERT INTO ocr_fts(rowid, foreground, background, title)
                VALUES (new.id, new.foreground, new.background, new.title);
            END;
            """
        )
    }

    private func scalar(_ sql: String, db: SQLiteDatabase) throws -> Int64 {
        let stmt = try db.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw SQLiteError.notFound }
        return SQLiteColumn.int64(stmt, 0)
    }

    private func tableExists(_ name: String, db: SQLiteDatabase) throws -> Bool {
        let stmt = try db.prepare(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        )
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.text(stmt, 1, name)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func columnNames(_ table: String, db: SQLiteDatabase) throws -> [String] {
        let stmt = try db.prepare("PRAGMA table_info('\(table)')")
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = SQLiteColumn.text(stmt, 1) { names.append(name) }
        }
        return names
    }
}
