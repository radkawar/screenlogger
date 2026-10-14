import CryptoKit
import Foundation
import SQLite3

public enum SchemaMigrationError: Error, Equatable, Sendable {
    case unsupportedVersion(found: Int, supported: Int)
    case invalidSchema([String])
}

extension SchemaMigrationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let found, let supported):
            return "A newer Screenlogger version created this Library. Schema: \(found). Maximum supported schema: \(supported)."
        case .invalidSchema:
            return "The Screenlogger Library schema is incomplete or inconsistent."
        }
    }
}

/// Screenlogger schema and migrations for frames, OCR, segments, FTS5, and AX context.
/// Uses plain SQLite3 (not SQLCipher). Bookkeeping via `schema_migrations` (not grdb_migrations).
public enum Schema {
    public static let currentVersion = 9

    public static let createStatements: [String] =
        [
            // ---- Core activity graph ----
            """
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT,
                updated_at INTEGER
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS application (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                bundle_id TEXT NOT NULL,
                version TEXT NOT NULL DEFAULT '',
                icon_path TEXT,
                display_name TEXT,
                is_user_app INTEGER,
                dominant_color INTEGER,
                UNIQUE(bundle_id, version)
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_application_bundle_id ON application(bundle_id)
            """,
            """
            CREATE TABLE IF NOT EXISTS domain (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                normalized_domain TEXT NOT NULL UNIQUE,
                common_name TEXT,
                icon_path TEXT,
                dominant_color INTEGER
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_domain_normalized ON domain(normalized_domain)
            """,
            """
            CREATE TABLE IF NOT EXISTS video (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                height INTEGER NOT NULL,
                width INTEGER NOT NULL,
                path TEXT NOT NULL,
                num_frames INTEGER NOT NULL,
                size_bytes INTEGER,
                status INTEGER NOT NULL DEFAULT 0
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_video_status ON video(status)
                WHERE status != 0
            """,
            """
            CREATE TABLE IF NOT EXISTS segment (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                start_frame_id INTEGER NOT NULL,
                application INTEGER REFERENCES application(id),
                domain INTEGER REFERENCES domain(id),
                url TEXT
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_segment_start_frame ON segment(start_frame_id)
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_segment_application ON segment(application)
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_segment_domain ON segment(domain)
            """,
            """
            CREATE TABLE IF NOT EXISTS frame (
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
                tree BLOB,
                segment INTEGER REFERENCES segment(id),
                is_inactive INTEGER NOT NULL DEFAULT 0,
                ax_root_hash BLOB,
                capture_display_x REAL,
                capture_display_y REAL,
                capture_display_width REAL,
                capture_display_height REAL,
                index_search INTEGER NOT NULL DEFAULT 1
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_frame_timestamp ON frame(timestamp)
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_frame_segment ON frame(segment)
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_frame_video ON frame(video)
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_frame_timestamp_segment
                ON frame(timestamp, segment) WHERE segment IS NOT NULL
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_frame_window_covering
                ON frame(id, video, video_index, timestamp, image_path, title, segment)
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_frame_video_timestamp
                ON frame(video, timestamp) WHERE video IS NOT NULL
            """,
            """
            CREATE TABLE IF NOT EXISTS ocr (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                frame INTEGER NOT NULL REFERENCES frame(id) ON DELETE CASCADE,
                x INTEGER NOT NULL,
                y INTEGER NOT NULL,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                text_offset INTEGER NOT NULL,
                text_length INTEGER NOT NULL
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_ocr_frame ON ocr(frame)
            """,
            """
            CREATE TABLE IF NOT EXISTS window_bound (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                frame INTEGER NOT NULL REFERENCES frame(id) ON DELETE CASCADE,
                application INTEGER NOT NULL REFERENCES application(id),
                window_title TEXT,
                x INTEGER NOT NULL,
                y INTEGER NOT NULL,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                window_layer INTEGER NOT NULL DEFAULT 0,
                z_order INTEGER NOT NULL DEFAULT 0,
                url TEXT
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_window_bound_frame ON window_bound(frame)
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_window_bound_application ON window_bound(application)
            """,

            // ---- FTS5 external content on frame ----
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS ocr_fts USING fts5(
                foreground,
                background,
                title,
                content='frame',
                content_rowid='id',
                tokenize='porter unicode61 remove_diacritics 2'
            )
            """,
            """
            CREATE TRIGGER IF NOT EXISTS frame_ai AFTER INSERT ON frame
            WHEN COALESCE(new.index_search, 1) != 0
            BEGIN
                INSERT INTO ocr_fts(rowid, foreground, background, title)
                VALUES (new.id, new.foreground, new.background, new.title);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS frame_ad AFTER DELETE ON frame
            WHEN COALESCE(old.index_search, 1) != 0
            BEGIN
                INSERT INTO ocr_fts(ocr_fts, rowid, foreground, background, title)
                VALUES('delete', old.id, old.foreground, old.background, old.title);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS frame_au AFTER UPDATE ON frame
            WHEN OLD.foreground IS NOT NEW.foreground
              OR OLD.background IS NOT NEW.background
              OR OLD.title IS NOT NEW.title
            BEGIN
                INSERT INTO ocr_fts(ocr_fts, rowid, foreground, background, title)
                VALUES('delete', old.id, old.foreground, old.background, old.title);
                INSERT INTO ocr_fts(rowid, foreground, background, title)
                VALUES (new.id, new.foreground, new.background, new.title);
            END
            """,

            // ---- On-device audio transcripts (no retained audio) ----
            """
            CREATE TABLE IF NOT EXISTS transcript_segment (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                frame_id INTEGER NOT NULL REFERENCES frame(id) ON DELETE CASCADE,
                start_timestamp INTEGER NOT NULL,
                end_timestamp INTEGER NOT NULL,
                source TEXT NOT NULL CHECK(source IN ('microphone', 'computer')),
                text TEXT NOT NULL,
                locale_identifier TEXT,
                confidence REAL,
                CHECK(end_timestamp >= start_timestamp)
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_transcript_segment_frame
                ON transcript_segment(frame_id)
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_transcript_segment_time
                ON transcript_segment(start_timestamp, end_timestamp)
            """,
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS transcript_fts USING fts5(
                text,
                content='transcript_segment',
                content_rowid='id',
                tokenize='porter unicode61 remove_diacritics 2'
            )
            """,
            """
            CREATE TRIGGER IF NOT EXISTS transcript_segment_ai AFTER INSERT ON transcript_segment BEGIN
                INSERT INTO transcript_fts(rowid, text) VALUES (new.id, new.text);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS transcript_segment_ad AFTER DELETE ON transcript_segment BEGIN
                INSERT INTO transcript_fts(transcript_fts, rowid, text)
                VALUES('delete', old.id, old.text);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS transcript_segment_au AFTER UPDATE OF text ON transcript_segment BEGIN
                INSERT INTO transcript_fts(transcript_fts, rowid, text)
                VALUES('delete', old.id, old.text);
                INSERT INTO transcript_fts(rowid, text) VALUES (new.id, new.text);
            END
            """,

            // ---- Persistent accessibility tree (content-addressed) ----
            """
            CREATE TABLE IF NOT EXISTS ax_node (
                hash BLOB PRIMARY KEY,
                payload BLOB NOT NULL,
                first_seen_frame_id INTEGER
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_ax_node_first_seen_frame_id
                ON ax_node(first_seen_frame_id)
            """,
            """
            CREATE TABLE IF NOT EXISTS ax_node_edge (
                parent_hash BLOB NOT NULL,
                child_hash BLOB NOT NULL,
                PRIMARY KEY (parent_hash, child_hash)
            ) WITHOUT ROWID
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_ax_node_edge_child ON ax_node_edge(child_hash)
            """,
            """
            CREATE TABLE IF NOT EXISTS ax_snapshot (
                frame_id INTEGER PRIMARY KEY REFERENCES frame(id) ON DELETE CASCADE,
                root_hash BLOB NOT NULL REFERENCES ax_node(hash),
                timestamp_ms INTEGER NOT NULL,
                application_name TEXT NOT NULL,
                bundle_id TEXT NOT NULL,
                process_identifier INTEGER NOT NULL,
                extraction_mode TEXT NOT NULL DEFAULT 'unknown',
                is_partial_tree INTEGER NOT NULL DEFAULT 0
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_ax_snapshot_root_hash ON ax_snapshot(root_hash)
            """,
            """
            CREATE TABLE IF NOT EXISTS ax_legacy_tree (
                frame_id INTEGER PRIMARY KEY REFERENCES frame(id) ON DELETE CASCADE,
                payload BLOB NOT NULL
            ) WITHOUT ROWID
            """,

            // ---- Aux tables ----
            """
            CREATE TABLE IF NOT EXISTS app_version (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                version TEXT NOT NULL,
                observed_at INTEGER NOT NULL
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_app_version_observed_at ON app_version(observed_at)
            """,
            """
            CREATE TABLE IF NOT EXISTS timezone (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                identifier TEXT NOT NULL,
                observed_at INTEGER NOT NULL
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS idx_timezone_observed_at ON timezone(observed_at)
            """,
            """
            CREATE TABLE IF NOT EXISTS once_tasks (
                task_id TEXT PRIMARY KEY,
                completed INTEGER NOT NULL DEFAULT 0,
                completed_at REAL
            )
            """,
        ] + SemanticSchema.statements

    public static func migrate(_ db: SQLiteDatabase) throws {
        let hasVersionTable = try tableExists(db, "schema_migrations")
        let originalVersion = hasVersionTable ? try userVersion(db) : 0
        guard originalVersion <= currentVersion else {
            throw SchemaMigrationError.unsupportedVersion(
                found: originalVersion,
                supported: currentVersion
            )
        }

        // V5 rebuilds the application parent table to replace the historical
        // UNIQUE(bundle_id) constraint with UNIQUE(bundle_id, version).
        // SQLite ignores PRAGMA foreign_keys changes inside a transaction, so
        // disable enforcement on this connection before beginning the atomic
        // migration. An explicit foreign_key_check still runs before commit.
        let rebuildsReferencedParentTable = originalVersion > 0 && originalVersion < 5
        if rebuildsReferencedParentTable {
            try db.exec("PRAGMA foreign_keys = OFF")
        }
        var foreignKeyEnforcementRestored = !rebuildsReferencedParentTable
        defer {
            if !foreignKeyEnforcementRestored {
                try? db.exec("PRAGMA foreign_keys = ON")
            }
        }

        try db.transaction {
            // Defer every foreign-key check until the rebuilt parent tables and
            // indexes are back in place at commit.
            try db.exec("PRAGMA defer_foreign_keys = ON")
            try db.exec("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY NOT NULL)")
            let current = try userVersion(db)

            // Fresh database: apply full current schema in one atomic pass.
            if current < 1 {
                for sql in createStatements {
                    try db.exec(sql)
                }
                try setUserVersion(db, currentVersion)
                return
            }

            // Legacy path for DBs created before AX tables existed.
            if current < 4 {
                try migrateToV4(db)
                try setUserVersion(db, 4)
            }

            // Content-addressed AX columns and covering indexes.
            if try userVersion(db) < 5 {
                try migrateToV5(db)
                try setUserVersion(db, 5)
            }

            if try userVersion(db) < 6 {
                try migrateToV6(db)
                try setUserVersion(db, 6)
            }

            if try userVersion(db) < 7 {
                try migrateToV7(db)
                try setUserVersion(db, 7)
            }

            if try userVersion(db) < 8 {
                for sql in SemanticSchema.statements {
                    try db.exec(sql)
                }
                try setUserVersion(db, 8)
            }

            if try userVersion(db) < 9 {
                for sql in SemanticSchema.revisionAndAdmissionMigration {
                    try db.exec(sql)
                }
                try setUserVersion(db, 9)
            }

            if try userVersion(db) < currentVersion {
                try setUserVersion(db, currentVersion)
            }

            if rebuildsReferencedParentTable {
                let violations = try db.foreignKeyViolations()
                guard violations.isEmpty else {
                    throw SchemaMigrationError.invalidSchema(
                        violations.prefix(20).map {
                            "foreign key \($0.table)[\($0.rowID.map(String.init) ?? "nil")] -> \($0.parentTable)#\($0.constraintIndex)"
                        }
                    )
                }
            }
        }

        if rebuildsReferencedParentTable {
            try db.exec("PRAGMA foreign_keys = ON")
            foreignKeyEnforcementRestored = true
        }
    }

    /// Verify the actual contract rather than trusting only the version marker.
    public static func validate(_ db: SQLiteDatabase) throws {
        var failures: [String] = []
        let version = try userVersion(db)
        if version != currentVersion {
            failures.append("schema version is \(version), expected \(currentVersion)")
        }

        let requiredColumns: [String: [String]] = [
            "schema_migrations": ["version"],
            "metadata": ["key", "value", "updated_at"],
            "application": ["id", "bundle_id", "version", "icon_path", "display_name", "is_user_app", "dominant_color"],
            "domain": ["id", "normalized_domain", "common_name", "icon_path", "dominant_color"],
            "video": ["id", "height", "width", "path", "num_frames", "size_bytes", "status"],
            "segment": ["id", "start_frame_id", "application", "domain", "url"],
            "frame": [
                "id", "timestamp", "video", "video_index", "image_path", "width", "height",
                "foreground", "background", "title", "tree", "segment", "is_inactive", "ax_root_hash",
                "capture_display_x", "capture_display_y", "capture_display_width", "capture_display_height",
                "index_search",
            ],
            "ocr": ["id", "frame", "x", "y", "width", "height", "text_offset", "text_length"],
            "window_bound": [
                "id", "frame", "application", "window_title", "x", "y", "width", "height",
                "window_layer", "z_order", "url",
            ],
            "ocr_fts": ["foreground", "background", "title"],
            "transcript_segment": [
                "id", "frame_id", "start_timestamp", "end_timestamp", "source", "text",
                "locale_identifier", "confidence",
            ],
            "transcript_fts": ["text"],
            "ax_node": ["hash", "payload", "first_seen_frame_id"],
            "ax_node_edge": ["parent_hash", "child_hash"],
            "ax_snapshot": [
                "frame_id", "root_hash", "timestamp_ms", "application_name", "bundle_id",
                "process_identifier", "extraction_mode", "is_partial_tree",
            ],
            "ax_legacy_tree": ["frame_id", "payload"],
            "app_version": ["id", "version", "observed_at"],
            "timezone": ["id", "identifier", "observed_at"],
            "once_tasks": ["task_id", "completed", "completed_at"],
            "semantic_config": [
                "id", "enabled", "mode", "pipeline_id", "images_watermark", "text_watermark",
                "transcripts_watermark", "images_initialized", "text_initialized",
            ],
            "semantic_source": [
                "id", "frame_id", "transcript_id", "kind", "revision", "pipeline_id",
                "state", "content_hash", "error",
            ],
            "semantic_occurrence": ["frame_id", "kind", "source_id"],
            "semantic_vector": ["pipeline_id", "hash", "dimensions", "value"],
            "semantic_chunk": ["source_id", "ordinal", "pipeline_id", "hash"],
        ]

        for table in requiredColumns.keys.sorted() {
            guard try tableExists(db, table) else {
                failures.append("missing table \(table)")
                continue
            }
            for column in requiredColumns[table] ?? [] where try !columnExists(db, table: table, column: column) {
                failures.append("missing column \(table).\(column)")
            }
        }

        for trigger in [
            "frame_ai", "frame_ad", "frame_au",
            "transcript_segment_ai", "transcript_segment_ad", "transcript_segment_au",
            "semantic_chunk_ad", "semantic_frame_bd", "semantic_frame_ai",
            "semantic_frame_text_au", "semantic_frame_media_au", "semantic_video_au",
            "semantic_transcript_ai", "semantic_transcript_au",
        ] where try !triggerExists(db, trigger) {
            failures.append("missing trigger \(trigger)")
        }

        guard failures.isEmpty else { throw SchemaMigrationError.invalidSchema(failures) }
    }

    // MARK: - V4 (legacy flat AX; kept for upgrade chain)

    private static func migrateToV4(_ db: SQLiteDatabase) throws {
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS ax_snapshot (
                frame_id INTEGER PRIMARY KEY REFERENCES frame(id) ON DELETE CASCADE,
                payload TEXT NOT NULL,
                node_count INTEGER NOT NULL DEFAULT 0,
                bundle_id TEXT,
                application_name TEXT,
                process_identifier INTEGER,
                is_partial INTEGER NOT NULL DEFAULT 0,
                timestamp_ms INTEGER NOT NULL
            )
            """
        )
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS ax_node (
                hash TEXT PRIMARY KEY,
                payload TEXT NOT NULL,
                first_seen_frame_id INTEGER
            )
            """
        )
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT,
                updated_at INTEGER
            )
            """
        )
    }

    // MARK: - V5

    private static func migrateToV5(_ db: SQLiteDatabase) throws {
        try renameMetaToMetadata(db)
        try migrateApplicationTable(db)
        try ensureColumns(
            db, table: "domain",
            columns: [
                ("icon_path", "TEXT"),
                ("dominant_color", "INTEGER"),
            ])
        try ensureColumns(
            db, table: "frame",
            columns: [
                ("tree", "BLOB"),
                ("ax_root_hash", "BLOB"),
                ("capture_display_x", "REAL"),
                ("capture_display_y", "REAL"),
                ("capture_display_width", "REAL"),
                ("capture_display_height", "REAL"),
            ])
        try db.exec(
            """
            CREATE INDEX IF NOT EXISTS idx_frame_timestamp_segment
                ON frame(timestamp, segment) WHERE segment IS NOT NULL
            """
        )
        try db.exec(
            """
            CREATE INDEX IF NOT EXISTS idx_frame_window_covering
                ON frame(id, video, video_index, timestamp, image_path, title, segment)
            """
        )
        try db.exec(
            """
            CREATE INDEX IF NOT EXISTS idx_frame_video_timestamp
                ON frame(video, timestamp) WHERE video IS NOT NULL
            """
        )
        try db.exec(
            """
            CREATE INDEX IF NOT EXISTS idx_video_status ON video(status)
                WHERE status != 0
            """
        )
        try db.exec(
            """
            CREATE INDEX IF NOT EXISTS idx_window_bound_application ON window_bound(application)
            """
        )
        try db.exec(
            """
            CREATE INDEX IF NOT EXISTS idx_application_bundle_id ON application(bundle_id)
            """
        )
        try db.exec(
            """
            CREATE INDEX IF NOT EXISTS idx_domain_normalized ON domain(normalized_domain)
            """
        )

        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS ax_legacy_tree (
                frame_id INTEGER PRIMARY KEY REFERENCES frame(id) ON DELETE CASCADE,
                payload BLOB NOT NULL
            ) WITHOUT ROWID
            """
        )

        try migrateAXTablesToContentAddressed(db)

        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS app_version (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                version TEXT NOT NULL,
                observed_at INTEGER NOT NULL
            )
            """
        )
        try db.exec(
            """
            CREATE INDEX IF NOT EXISTS idx_app_version_observed_at ON app_version(observed_at)
            """
        )
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS timezone (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                identifier TEXT NOT NULL,
                observed_at INTEGER NOT NULL
            )
            """
        )
        try db.exec(
            """
            CREATE INDEX IF NOT EXISTS idx_timezone_observed_at ON timezone(observed_at)
            """
        )
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS once_tasks (
                task_id TEXT PRIMARY KEY,
                completed INTEGER NOT NULL DEFAULT 0,
                completed_at REAL
            )
            """
        )
    }

    // MARK: - V6

    private static func migrateToV6(_ db: SQLiteDatabase) throws {
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS transcript_segment (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                frame_id INTEGER NOT NULL REFERENCES frame(id) ON DELETE CASCADE,
                start_timestamp INTEGER NOT NULL,
                end_timestamp INTEGER NOT NULL,
                source TEXT NOT NULL CHECK(source IN ('microphone', 'computer')),
                text TEXT NOT NULL,
                locale_identifier TEXT,
                confidence REAL,
                CHECK(end_timestamp >= start_timestamp)
            )
            """
        )
        try db.exec(
            """
            CREATE INDEX IF NOT EXISTS idx_transcript_segment_frame
                ON transcript_segment(frame_id)
            """
        )
        try db.exec(
            """
            CREATE INDEX IF NOT EXISTS idx_transcript_segment_time
                ON transcript_segment(start_timestamp, end_timestamp)
            """
        )
        try db.exec(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS transcript_fts USING fts5(
                text,
                content='transcript_segment',
                content_rowid='id',
                tokenize='porter unicode61 remove_diacritics 2'
            )
            """
        )
        try db.exec(
            """
            CREATE TRIGGER IF NOT EXISTS transcript_segment_ai AFTER INSERT ON transcript_segment BEGIN
                INSERT INTO transcript_fts(rowid, text) VALUES (new.id, new.text);
            END
            """
        )
        try db.exec(
            """
            CREATE TRIGGER IF NOT EXISTS transcript_segment_ad AFTER DELETE ON transcript_segment BEGIN
                INSERT INTO transcript_fts(transcript_fts, rowid, text)
                VALUES('delete', old.id, old.text);
            END
            """
        )
        try db.exec(
            """
            CREATE TRIGGER IF NOT EXISTS transcript_segment_au AFTER UPDATE OF text ON transcript_segment BEGIN
                INSERT INTO transcript_fts(transcript_fts, rowid, text)
                VALUES('delete', old.id, old.text);
                INSERT INTO transcript_fts(rowid, text) VALUES (new.id, new.text);
            END
            """
        )
    }

    // MARK: - V7

    private static func migrateToV7(_ db: SQLiteDatabase) throws {
        try ensureColumns(
            db,
            table: "frame",
            columns: [
                ("index_search", "INTEGER NOT NULL DEFAULT 1")
            ]
        )
        try db.exec("DROP TRIGGER IF EXISTS frame_ai")
        try db.exec("DROP TRIGGER IF EXISTS frame_ad")
        try db.exec(
            """
            CREATE TRIGGER frame_ai AFTER INSERT ON frame
            WHEN COALESCE(new.index_search, 1) != 0
            BEGIN
                INSERT INTO ocr_fts(rowid, foreground, background, title)
                VALUES (new.id, new.foreground, new.background, new.title);
            END
            """
        )
        try db.exec(
            """
            CREATE TRIGGER frame_ad AFTER DELETE ON frame
            WHEN COALESCE(old.index_search, 1) != 0
            BEGIN
                INSERT INTO ocr_fts(ocr_fts, rowid, foreground, background, title)
                VALUES('delete', old.id, old.foreground, old.background, old.title);
            END
            """
        )
    }

    private static func renameMetaToMetadata(_ db: SQLiteDatabase) throws {
        let hasMetadata = try tableExists(db, "metadata")
        let hasMeta = try tableExists(db, "meta")
        if hasMetadata {
            return
        }
        if hasMeta {
            try db.exec("ALTER TABLE meta RENAME TO metadata")
            return
        }
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT,
                updated_at INTEGER
            )
            """
        )
    }

    private static func migrateApplicationTable(_ db: SQLiteDatabase) throws {
        try ensureColumns(
            db, table: "application",
            columns: [
                ("version", "TEXT NOT NULL DEFAULT ''"),
                ("is_user_app", "INTEGER"),
                ("dominant_color", "INTEGER"),
            ])

        if try applicationNeedsUniquenessRebuild(db) {
            try db.exec(
                """
                CREATE TABLE application_v5 (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    bundle_id TEXT NOT NULL,
                    version TEXT NOT NULL DEFAULT '',
                    icon_path TEXT,
                    display_name TEXT,
                    is_user_app INTEGER,
                    dominant_color INTEGER,
                    UNIQUE(bundle_id, version)
                )
                """
            )
            try db.exec(
                """
                INSERT INTO application_v5(id, bundle_id, version, icon_path, display_name, is_user_app, dominant_color)
                SELECT id, bundle_id, COALESCE(version, ''), icon_path, display_name, is_user_app, dominant_color
                FROM application
                """
            )
            try db.exec("DROP TABLE application")
            try db.exec("ALTER TABLE application_v5 RENAME TO application")
            try db.exec("CREATE INDEX IF NOT EXISTS idx_application_bundle_id ON application(bundle_id)")
        }
    }

    private static func applicationNeedsUniquenessRebuild(_ db: SQLiteDatabase) throws -> Bool {
        // Application versions require uniqueness across bundle ID and version.
        let list = try db.prepare("PRAGMA index_list('application')")
        defer { sqlite3_finalize(list) }
        var uniqueIndexNames: [String] = []
        var listResult = sqlite3_step(list)
        while listResult == SQLITE_ROW {
            let isUnique = sqlite3_column_int(list, 2) == 1
            if isUnique, let name = SQLiteColumn.text(list, 1) {
                uniqueIndexNames.append(name)
            }
            listResult = sqlite3_step(list)
        }
        guard listResult == SQLITE_DONE else {
            throw SQLiteError.step("application index scan failed")
        }
        for name in uniqueIndexNames {
            let info = try db.prepare("PRAGMA index_info('\(name)')")
            defer { sqlite3_finalize(info) }
            var cols: [String] = []
            var infoResult = sqlite3_step(info)
            while infoResult == SQLITE_ROW {
                if let col = SQLiteColumn.text(info, 2) {
                    cols.append(col)
                }
                infoResult = sqlite3_step(info)
            }
            guard infoResult == SQLITE_DONE else {
                throw SQLiteError.step("application index detail scan failed")
            }
            if cols == ["bundle_id"] {
                return true
            }
            if cols == ["bundle_id", "version"] {
                return false
            }
        }
        // No matching unique index found - rebuild to ensure constraint.
        return true
    }

    private static func migrateAXTablesToContentAddressed(_ db: SQLiteDatabase) throws {
        let hasSnapshot = try tableExists(db, "ax_snapshot")
        let hasPayload = try columnExists(db, table: "ax_snapshot", column: "payload")
        let hasRootHash = try columnExists(db, table: "ax_snapshot", column: "root_hash")
        let legacySnapshot = hasSnapshot && hasPayload && !hasRootHash

        if legacySnapshot {
            struct LegacySnap {
                var frameID: Int64
                var payload: Data
                var bundleID: String
                var applicationName: String
                var pid: Int64
                var isPartial: Bool
                var timestampMs: Int64
            }
            var legacy: [LegacySnap] = []
            let stmt = try db.prepare(
                """
                SELECT frame_id, payload, bundle_id, application_name,
                       process_identifier, is_partial, timestamp_ms
                FROM ax_snapshot
                """
            )
            defer { sqlite3_finalize(stmt) }
            var result = sqlite3_step(stmt)
            while result == SQLITE_ROW {
                let payloadText = SQLiteColumn.text(stmt, 1) ?? ""
                legacy.append(
                    LegacySnap(
                        frameID: SQLiteColumn.int64(stmt, 0),
                        payload: Data(payloadText.utf8),
                        bundleID: SQLiteColumn.text(stmt, 2) ?? "",
                        applicationName: SQLiteColumn.text(stmt, 3) ?? "",
                        pid: SQLiteColumn.int64Optional(stmt, 4) ?? 0,
                        isPartial: SQLiteColumn.bool(stmt, 5),
                        timestampMs: SQLiteColumn.int64(stmt, 6)
                    )
                )
                result = sqlite3_step(stmt)
            }
            guard result == SQLITE_DONE else {
                throw SQLiteError.step("legacy accessibility snapshot scan failed")
            }

            try db.exec("DROP TABLE IF EXISTS ax_snapshot")
            try db.exec("DROP TABLE IF EXISTS ax_node_edge")
            try db.exec("DROP TABLE IF EXISTS ax_node")

            try createContentAddressedAXTables(db)

            for row in legacy {
                let hash = ContentHash.sha256(row.payload)
                let n = try db.prepare(
                    """
                    INSERT OR IGNORE INTO ax_node(hash, payload, first_seen_frame_id)
                    VALUES(?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(n) }
                SQLiteBind.blob(n, 1, hash)
                SQLiteBind.blob(n, 2, row.payload)
                SQLiteBind.int64(n, 3, row.frameID)
                guard sqlite3_step(n) == SQLITE_DONE else {
                    throw SQLiteError.step("accessibility node migration failed")
                }

                let s = try db.prepare(
                    """
                    INSERT OR REPLACE INTO ax_snapshot(
                        frame_id, root_hash, timestamp_ms, application_name, bundle_id,
                        process_identifier, extraction_mode, is_partial_tree
                    ) VALUES(?, ?, ?, ?, ?, ?, 'legacy_xml', ?)
                    """
                )
                defer { sqlite3_finalize(s) }
                SQLiteBind.int64(s, 1, row.frameID)
                SQLiteBind.blob(s, 2, hash)
                SQLiteBind.int64(s, 3, row.timestampMs)
                SQLiteBind.text(s, 4, row.applicationName)
                SQLiteBind.text(s, 5, row.bundleID)
                SQLiteBind.int64(s, 6, row.pid)
                SQLiteBind.bool(s, 7, row.isPartial)
                guard sqlite3_step(s) == SQLITE_DONE else {
                    throw SQLiteError.step("accessibility snapshot migration failed")
                }

                let f = try db.prepare("UPDATE frame SET ax_root_hash = ? WHERE id = ?")
                defer { sqlite3_finalize(f) }
                SQLiteBind.blob(f, 1, hash)
                SQLiteBind.int64(f, 2, row.frameID)
                guard sqlite3_step(f) == SQLITE_DONE else {
                    throw SQLiteError.step("frame accessibility reference migration failed")
                }

                let leg = try db.prepare(
                    "INSERT OR REPLACE INTO ax_legacy_tree(frame_id, payload) VALUES(?, ?)"
                )
                defer { sqlite3_finalize(leg) }
                SQLiteBind.int64(leg, 1, row.frameID)
                SQLiteBind.blob(leg, 2, row.payload)
                guard sqlite3_step(leg) == SQLITE_DONE else {
                    throw SQLiteError.step("legacy accessibility payload migration failed")
                }
            }
            return
        }

        // Already content-addressed or missing - ensure tables exist.
        try createContentAddressedAXTables(db)
    }

    private static func createContentAddressedAXTables(_ db: SQLiteDatabase) throws {
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS ax_node (
                hash BLOB PRIMARY KEY,
                payload BLOB NOT NULL,
                first_seen_frame_id INTEGER
            )
            """
        )
        try db.exec(
            """
            CREATE INDEX IF NOT EXISTS idx_ax_node_first_seen_frame_id
                ON ax_node(first_seen_frame_id)
            """
        )
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS ax_node_edge (
                parent_hash BLOB NOT NULL,
                child_hash BLOB NOT NULL,
                PRIMARY KEY (parent_hash, child_hash)
            ) WITHOUT ROWID
            """
        )
        try db.exec(
            """
            CREATE INDEX IF NOT EXISTS idx_ax_node_edge_child ON ax_node_edge(child_hash)
            """
        )
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS ax_snapshot (
                frame_id INTEGER PRIMARY KEY REFERENCES frame(id) ON DELETE CASCADE,
                root_hash BLOB NOT NULL REFERENCES ax_node(hash),
                timestamp_ms INTEGER NOT NULL,
                application_name TEXT NOT NULL,
                bundle_id TEXT NOT NULL,
                process_identifier INTEGER NOT NULL,
                extraction_mode TEXT NOT NULL DEFAULT 'unknown',
                is_partial_tree INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        try db.exec(
            """
            CREATE INDEX IF NOT EXISTS idx_ax_snapshot_root_hash ON ax_snapshot(root_hash)
            """
        )
    }

    // MARK: - Helpers

    private static func ensureColumns(
        _ db: SQLiteDatabase,
        table: String,
        columns: [(String, String)]
    ) throws {
        for (name, decl) in columns {
            if try !columnExists(db, table: table, column: name) {
                try db.exec("ALTER TABLE \(table) ADD COLUMN \(name) \(decl)")
            }
        }
    }

    private static func tableExists(_ db: SQLiteDatabase, _ name: String) throws -> Bool {
        let stmt = try db.prepare(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name = ? LIMIT 1"
        )
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.text(stmt, 1, name)
        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW { return true }
        guard result == SQLITE_DONE else {
            throw SQLiteError.step("table lookup failed")
        }
        return false
    }

    private static func triggerExists(_ db: SQLiteDatabase, _ name: String) throws -> Bool {
        let stmt = try db.prepare(
            "SELECT 1 FROM sqlite_master WHERE type='trigger' AND name = ? LIMIT 1"
        )
        defer { sqlite3_finalize(stmt) }
        SQLiteBind.text(stmt, 1, name)
        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW { return true }
        guard result == SQLITE_DONE else {
            throw SQLiteError.step("trigger lookup failed")
        }
        return false
    }

    private static func columnExists(_ db: SQLiteDatabase, table: String, column: String) throws -> Bool {
        let stmt = try db.prepare("PRAGMA table_info('\(table)')")
        defer { sqlite3_finalize(stmt) }
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            if SQLiteColumn.text(stmt, 1) == column {
                return true
            }
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else {
            throw SQLiteError.step("column lookup failed")
        }
        return false
    }

    private static func userVersion(_ db: SQLiteDatabase) throws -> Int {
        let stmt = try db.prepare("SELECT COALESCE(MAX(version), 0) FROM schema_migrations")
        defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        guard result == SQLITE_DONE else {
            throw SQLiteError.step("schema version lookup failed")
        }
        throw SQLiteError.notFound
    }

    private static func setUserVersion(_ db: SQLiteDatabase, _ version: Int) throws {
        let stmt = try db.prepare("INSERT OR REPLACE INTO schema_migrations(version) VALUES (?)")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(version))
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw SQLiteError.step("setUserVersion failed")
        }
    }
}

// MARK: - Content hash (shared by migration + Store)

enum ContentHash {
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func sha256(utf8 string: String) -> Data {
        sha256(Data(string.utf8))
    }
}
