import Foundation

/// Ordinary SQLite tables keep source lifetime and vector ownership in the same
/// transaction as capture, transcript finalization, retention, and deletion.
enum SemanticSchema {
    static let statements: [String] = [
        """
        CREATE TABLE semantic_config (
            id INTEGER PRIMARY KEY CHECK(id = 1),
            enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0, 1)),
            mode TEXT NOT NULL DEFAULT 'images' CHECK(mode IN ('images', 'text', 'both')),
            pipeline_id TEXT NOT NULL DEFAULT '',
            images_watermark INTEGER NOT NULL DEFAULT 0,
            text_watermark INTEGER NOT NULL DEFAULT 0,
            transcripts_watermark INTEGER NOT NULL DEFAULT 0,
            images_initialized INTEGER NOT NULL DEFAULT 0,
            text_initialized INTEGER NOT NULL DEFAULT 0
        )
        """,
        "INSERT INTO semantic_config(id) VALUES(1)",
        "CREATE UNIQUE INDEX idx_transcript_semantic_parent ON transcript_segment(id, frame_id)",
        """
        CREATE TABLE semantic_source (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            frame_id INTEGER NOT NULL REFERENCES frame(id) ON DELETE CASCADE,
            transcript_id INTEGER,
            kind TEXT NOT NULL CHECK(kind IN ('image', 'screenText', 'transcript')),
            revision INTEGER NOT NULL DEFAULT 1,
            pipeline_id TEXT NOT NULL,
            state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN ('pending', 'indexed', 'failed')),
            content_hash TEXT,
            error TEXT,
            FOREIGN KEY(transcript_id, frame_id) REFERENCES transcript_segment(id, frame_id) ON DELETE CASCADE,
            CHECK((kind = 'transcript') = (transcript_id IS NOT NULL))
        )
        """,
        "CREATE UNIQUE INDEX idx_semantic_source_frame_kind ON semantic_source(frame_id, kind) WHERE transcript_id IS NULL",
        "CREATE UNIQUE INDEX idx_semantic_source_transcript ON semantic_source(transcript_id) WHERE transcript_id IS NOT NULL",
        "CREATE INDEX idx_semantic_pending ON semantic_source(kind, id) WHERE state = 'pending'",
        "CREATE INDEX idx_semantic_source_frame ON semantic_source(frame_id)",
        "CREATE INDEX idx_semantic_content ON semantic_source(pipeline_id, kind, content_hash) WHERE state = 'indexed'",
        """
        CREATE TABLE semantic_occurrence (
            frame_id INTEGER NOT NULL REFERENCES frame(id) ON DELETE CASCADE,
            kind TEXT NOT NULL CHECK(kind IN ('image', 'screenText')),
            source_id INTEGER NOT NULL REFERENCES semantic_source(id) ON DELETE CASCADE,
            PRIMARY KEY(frame_id, kind)
        ) WITHOUT ROWID
        """,
        "CREATE INDEX idx_semantic_occurrence_source ON semantic_occurrence(source_id, frame_id)",
        """
        CREATE TABLE semantic_vector (
            pipeline_id TEXT NOT NULL,
            hash TEXT NOT NULL,
            dimensions INTEGER NOT NULL CHECK(dimensions = 768),
            value BLOB NOT NULL CHECK(length(value) = 3072),
            PRIMARY KEY(pipeline_id, hash)
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE semantic_chunk (
            source_id INTEGER NOT NULL REFERENCES semantic_source(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
            pipeline_id TEXT NOT NULL,
            hash TEXT NOT NULL,
            PRIMARY KEY(source_id, ordinal),
            FOREIGN KEY(pipeline_id, hash) REFERENCES semantic_vector(pipeline_id, hash)
        ) WITHOUT ROWID
        """,
        "CREATE INDEX idx_semantic_chunk_vector ON semantic_chunk(pipeline_id, hash)",
        """
        CREATE INDEX idx_frame_semantic_display ON frame(
            capture_display_x, capture_display_y, capture_display_width, capture_display_height, id
        )
        """,
        """
        CREATE TRIGGER semantic_chunk_ad AFTER DELETE ON semantic_chunk BEGIN
            DELETE FROM semantic_vector WHERE pipeline_id = OLD.pipeline_id AND hash = OLD.hash
                AND NOT EXISTS (SELECT 1 FROM semantic_chunk WHERE pipeline_id = OLD.pipeline_id AND hash = OLD.hash);
        END
        """,
        """
        CREATE TRIGGER semantic_frame_bd BEFORE DELETE ON frame BEGIN
            \(detach(frame: "OLD.id", kind: "image"))
            \(detach(frame: "OLD.id", kind: "screenText"))
        END
        """,
        """
        CREATE TRIGGER semantic_frame_ai AFTER INSERT ON frame
        WHEN (SELECT enabled AND mode IN ('text', 'both') FROM semantic_config WHERE id = 1)
        BEGIN
            \(admitFrame(frame: "NEW.id", kind: "screenText"))
        END
        """,
        """
        CREATE TRIGGER semantic_frame_text_au AFTER UPDATE OF foreground, background, title ON frame
        WHEN OLD.foreground IS NOT NEW.foreground OR OLD.background IS NOT NEW.background OR OLD.title IS NOT NEW.title
        BEGIN
            \(detach(frame: "NEW.id", kind: "screenText"))
            \(admitFrame(frame: "NEW.id", kind: "screenText", independent: true,
                         consent: "text_initialized = 1 OR (enabled = 1 AND mode IN ('text', 'both'))"))
            DELETE FROM semantic_chunk WHERE source_id IN
                (SELECT id FROM semantic_source WHERE frame_id = NEW.id AND kind = 'transcript' AND OLD.title IS NOT NEW.title);
            UPDATE semantic_source SET state = 'pending', content_hash = NULL, error = NULL, revision = revision + 1
                WHERE frame_id = NEW.id AND kind = 'transcript' AND OLD.title IS NOT NEW.title;
        END
        """,
        """
        CREATE TRIGGER semantic_frame_media_au AFTER UPDATE OF image_path, video, video_index ON frame
        BEGIN
            \(detach(frame: "NEW.id", kind: "image", condition: "NOT (\(mediaAvailable("NEW")))"))
            \(detach(frame: "NEW.id", kind: "image", condition: "(NULLIF(OLD.image_path, '') IS NOT NULL AND NULLIF(NEW.image_path, '') IS NOT NULL AND OLD.image_path IS NOT NEW.image_path) OR (NULLIF(OLD.image_path, '') IS NULL AND NULLIF(NEW.image_path, '') IS NULL AND OLD.video IS NOT NULL AND (OLD.video IS NOT NEW.video OR OLD.video_index IS NOT NEW.video_index))"))
            UPDATE semantic_source SET state = 'pending', content_hash = NULL, error = NULL, revision = revision + 1
                WHERE frame_id = NEW.id AND kind = 'image' AND state != 'indexed'
                  AND (NULLIF(OLD.image_path, '') IS NOT NULLIF(NEW.image_path, '')
                       OR (NULLIF(NEW.image_path, '') IS NULL
                           AND (OLD.video IS NOT NEW.video OR OLD.video_index IS NOT NEW.video_index)));
            \(admitFrame(frame: "NEW.id", kind: "image", consent: "(enabled = 1 AND mode IN ('images', 'both')) OR (images_initialized = 1 AND NEW.id <= images_watermark)"))
        END
        """,
        """
        CREATE TRIGGER semantic_video_au AFTER UPDATE OF status ON video
        WHEN OLD.status IS NOT NEW.status
        BEGIN
            UPDATE frame SET video = video WHERE video = NEW.id;
        END
        """,
        """
        CREATE TRIGGER semantic_transcript_ai AFTER INSERT ON transcript_segment
        WHEN (SELECT enabled AND mode IN ('text', 'both') FROM semantic_config WHERE id = 1)
        BEGIN
            \(admitTranscript(predicate: "t.id = NEW.id"))
        END
        """,
        """
        CREATE TRIGGER semantic_transcript_au AFTER UPDATE OF text, frame_id ON transcript_segment
        WHEN OLD.text IS NOT NEW.text OR OLD.frame_id IS NOT NEW.frame_id
        BEGIN
            DELETE FROM semantic_source WHERE transcript_id = NEW.id;
            \(admitTranscript(predicate: "t.id = NEW.id", consent: "text_initialized = 1 OR (enabled = 1 AND mode IN ('text', 'both'))"))
        END
        """,
    ]

    /// Existing Libraries need the same trigger behavior as a fresh schema.
    static let revisionAndAdmissionMigration: [String] = [
        "semantic_frame_bd", "semantic_frame_ai", "semantic_frame_text_au",
        "semantic_frame_media_au", "semantic_transcript_ai",
    ].flatMap { name in
        ["DROP TRIGGER \(name)"] + statements.filter { $0.hasPrefix("CREATE TRIGGER \(name) ") }
    }

    static func frameEligible(_ kind: String, frame: String = "f") -> String {
        kind == "image"
            ? mediaAvailable(frame)
            : "length(trim(coalesce(\(frame).foreground, '') || coalesce(\(frame).background, '') || coalesce(\(frame).title, ''))) > 0"
    }

    static func mediaAvailable(_ frame: String) -> String {
        """
        (NULLIF(\(frame).image_path, '') IS NOT NULL OR
         (\(frame).video_index IS NOT NULL AND EXISTS
          (SELECT 1 FROM video WHERE id = \(frame).video AND status = 0)))
        """
    }

    /// Re-anchor a shared source before its representative is removed. This
    /// preserves other occurrences without retaining provenance for the old row.
    static func detach(frame: String, kind: String, condition: String = "1") -> String {
        """
        UPDATE semantic_source SET frame_id = (
            SELECT MIN(o.frame_id) FROM semantic_occurrence o
            WHERE o.source_id = semantic_source.id AND o.frame_id != \(frame)
        ), revision = revision + 1,
           state = CASE WHEN state = 'failed' THEN 'pending' ELSE state END, error = NULL
        WHERE frame_id = \(frame) AND kind = '\(kind)' AND (\(condition))
          AND EXISTS (SELECT 1 FROM semantic_occurrence o
                      WHERE o.source_id = semantic_source.id AND o.frame_id != \(frame));
        DELETE FROM semantic_source WHERE frame_id = \(frame) AND kind = '\(kind)' AND (\(condition));
        DELETE FROM semantic_occurrence WHERE frame_id = \(frame) AND kind = '\(kind)' AND (\(condition));
        """
    }

    static func admitFrame(frame: String, kind: String, independent: Bool = false, consent: String? = nil) -> String {
        let allowed =
            consent
            ?? (kind == "image"
                ? "enabled = 1 AND mode IN ('images', 'both')"
                : "enabled = 1 AND mode IN ('text', 'both')")
        let eligible = frameEligible(kind)
        let textEquality =
            kind == "screenText"
            ? "AND p.foreground IS f.foreground AND p.background IS f.background AND p.title IS f.title" : ""
        let previous =
            independent
            ? "NULL"
            : """
            (SELECT o.source_id FROM frame p
             LEFT JOIN semantic_occurrence o ON o.frame_id = p.id AND o.kind = '\(kind)'
             WHERE p.id < f.id AND f.index_search = 0
               AND p.capture_display_x IS f.capture_display_x
               AND p.capture_display_y IS f.capture_display_y
               AND p.capture_display_width IS f.capture_display_width
               AND p.capture_display_height IS f.capture_display_height
               \(textEquality)
             ORDER BY p.id DESC LIMIT 1)
            """
        return """
            INSERT OR IGNORE INTO semantic_source(frame_id, kind, pipeline_id)
            SELECT f.id, '\(kind)', c.pipeline_id FROM frame f CROSS JOIN semantic_config c
            WHERE f.id = \(frame) AND c.id = 1 AND (\(allowed)) AND \(eligible)
              AND NOT EXISTS (SELECT 1 FROM semantic_occurrence WHERE frame_id = f.id AND kind = '\(kind)')
              AND \(previous) IS NULL;
            INSERT OR IGNORE INTO semantic_occurrence(frame_id, kind, source_id)
            SELECT f.id, '\(kind)', coalesce(
                (SELECT id FROM semantic_source WHERE frame_id = f.id AND kind = '\(kind)'), \(previous))
            FROM frame f CROSS JOIN semantic_config c
            WHERE f.id = \(frame) AND c.id = 1 AND (\(allowed)) AND \(eligible)
              AND coalesce((SELECT id FROM semantic_source WHERE frame_id = f.id AND kind = '\(kind)'), \(previous)) IS NOT NULL;
            """
    }

    static func admitTranscript(predicate: String, consent: String = "enabled = 1 AND mode IN ('text', 'both')") -> String {
        """
        INSERT OR IGNORE INTO semantic_source(frame_id, transcript_id, kind, pipeline_id)
        SELECT t.frame_id, t.id, 'transcript', c.pipeline_id FROM transcript_segment t CROSS JOIN semantic_config c
        WHERE c.id = 1 AND (\(consent)) AND length(trim(t.text)) > 0 AND (\(predicate));
        """
    }
}
