import Foundation
import SQLite3

public enum DatabaseMigrator {
    public static let currentVersion: Int32 = 7

    static func preflight(_ connection: SQLiteConnection) throws -> Int32 {
        try mapCorruption {
            try connection.execute(
                "PRAGMA foreign_keys = ON",
                operation: "enable_foreign_keys"
            )
            let version = try connection.userVersion()
            guard version <= currentVersion else {
                throw PersistenceError.unsupportedSchema(
                    found: version,
                    supported: currentVersion
                )
            }

            switch version {
            case 0:
                break
            case 1:
                try validateVersionOne(connection)
            case 2:
                try validateVersionTwo(connection)
            case 3:
                try validateVersionThree(connection)
            case 4:
                try validateVersionFour(connection)
            case 5:
                try validateVersionFive(connection)
            case 6:
                try validateVersionSix(connection)
            case 7:
                try validateVersionSeven(connection)
            default:
                throw PersistenceError.invalidSchema(object: "migration_path")
            }
            return version
        }
    }

    static func bootstrap(_ connection: SQLiteConnection) throws {
        try mapCorruption {
            try connection.execute(
                "PRAGMA foreign_keys = ON",
                operation: "enable_foreign_keys"
            )

            let version = try connection.userVersion()
            guard version <= currentVersion else {
                throw PersistenceError.unsupportedSchema(
                    found: version,
                    supported: currentVersion
                )
            }

            switch version {
            case 0:
                try createVersionTwo(connection)
                try migrateVersionTwoToThree(connection)
            case 1:
                try migrateVersionOneToTwo(connection)
                try migrateVersionTwoToThree(connection)
            case 2:
                try migrateVersionTwoToThree(connection)
            case 3:
                try validateVersionThree(connection)
            case 4:
                try validateVersionFour(connection)
            case 5:
                try validateVersionFive(connection)
            case 6:
                try validateVersionSix(connection)
            case 7:
                try validateVersionSeven(connection)
            default:
                throw PersistenceError.invalidSchema(object: "migration_path")
            }
            if version < 4 { try migrateVersionThreeToFour(connection) }
            if version < 5 { try migrateVersionFourToFive(connection) }
            if version < 6 { try migrateVersionFiveToSix(connection) }
            if version < 7 { try migrateVersionSixToSeven(connection) }
        }
    }

    static func migrateVersionFourToFive(_ connection: SQLiteConnection) throws {
        try connection.transaction {
            try connection.execute("""
                CREATE TABLE chat_sessions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    slot INTEGER NOT NULL UNIQUE CHECK(slot=1),
                    token TEXT NOT NULL UNIQUE, updated_at_utc_ms INTEGER NOT NULL
                );
                CREATE TABLE chat_messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id INTEGER NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
                    role TEXT NOT NULL CHECK(role IN ('user','assistant')),
                    content TEXT NOT NULL, created_at_utc_ms INTEGER NOT NULL,
                    turn_token TEXT NOT NULL, attempt_token TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('waiting','streaming','complete','stopped','failed','interrupted','length')),
                    error_code TEXT,
                    UNIQUE(session_id,turn_token,role)
                );
                CREATE INDEX chat_message_order ON chat_messages(session_id,id DESC);
                CREATE INDEX inspiration_category_order ON inspirations(category,sort_order DESC,id DESC);
                PRAGMA user_version = 5;
                """, operation: "migrate_v5_chat")
            try validateVersionFive(connection)
        }
    }

    static func migrateVersionFiveToSix(_ connection: SQLiteConnection) throws {
        try connection.transaction {
            try connection.execute("""
                ALTER TABLE chat_sessions RENAME TO chat_sessions_v5;
                ALTER TABLE chat_messages RENAME TO chat_messages_v5;
                DROP INDEX chat_message_order;
                CREATE TABLE chat_sessions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    slot INTEGER UNIQUE CHECK(slot=1),
                    token TEXT NOT NULL UNIQUE, updated_at_utc_ms INTEGER NOT NULL,
                    title TEXT NOT NULL DEFAULT '', draft TEXT NOT NULL DEFAULT ''
                );
                INSERT INTO chat_sessions(id,slot,token,updated_at_utc_ms)
                    SELECT id,slot,token,updated_at_utc_ms FROM chat_sessions_v5;
                CREATE TABLE chat_messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id INTEGER NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
                    role TEXT NOT NULL CHECK(role IN ('user','assistant')),
                    content TEXT NOT NULL, created_at_utc_ms INTEGER NOT NULL,
                    turn_token TEXT NOT NULL, attempt_token TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('waiting','streaming','complete','stopped','failed','interrupted','length')),
                    error_code TEXT, UNIQUE(session_id,turn_token,role)
                );
                INSERT INTO chat_messages SELECT * FROM chat_messages_v5;
                UPDATE sqlite_sequence SET seq=MAX(seq,COALESCE((SELECT seq FROM sqlite_sequence WHERE name='chat_messages_v5'),0)) WHERE name='chat_messages';
                UPDATE sqlite_sequence SET seq=MAX(seq,COALESCE((SELECT seq FROM sqlite_sequence WHERE name='chat_sessions_v5'),0)) WHERE name='chat_sessions';
                DROP TABLE chat_messages_v5;
                DROP TABLE chat_sessions_v5;
                CREATE INDEX chat_message_order ON chat_messages(session_id,id DESC);
                CREATE INDEX chat_session_order ON chat_sessions(updated_at_utc_ms DESC,id DESC);
                PRAGMA user_version=6;
                """, operation: "migrate_v6_history")
            try validateVersionSix(connection)
        }
    }

    private static func migrateVersionSixToSeven(_ db: SQLiteConnection) throws {
        try db.transaction {
            try db.execute("""
                ALTER TABLE inspirations ADD COLUMN title_source TEXT NOT NULL DEFAULT 'fallback' CHECK(title_source IN ('ai','fallback','user'));
                ALTER TABLE inspirations ADD COLUMN content_revision INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE inspirations ADD COLUMN title_revision INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE inspirations ADD COLUMN category_revision INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE inspirations ADD COLUMN lifecycle_token TEXT NOT NULL DEFAULT '';
                ALTER TABLE chat_sessions ADD COLUMN system_prompt TEXT;
                UPDATE inspirations SET body=CASE
                    WHEN title='' OR substr(body,1,length(title))=title THEN body
                    WHEN body='' THEN title ELSE title || char(10) || body END,
                    title_source='user',lifecycle_token=lower(hex(randomblob(16)));
                CREATE TRIGGER inspiration_lifecycle AFTER INSERT ON inspirations
                    BEGIN UPDATE inspirations SET lifecycle_token=lower(hex(randomblob(16))) WHERE id=NEW.id; END;
                PRAGMA user_version=7;
                """, operation: "migrate_v7_ai")
            let prompt = try db.prepare("UPDATE chat_sessions SET system_prompt=? WHERE EXISTS(SELECT 1 FROM chat_messages WHERE session_id=chat_sessions.id) OR length(draft)>0 OR (slot=1 AND EXISTS(SELECT 1 FROM drafts WHERE kind='ai_chat' AND length(content)>0))", operation: "snapshot_legacy_prompt")
            try prompt.bind(ChatContext.legacySystem, at: 1); try prompt.executeDone()
            try validateVersionSeven(db)
        }
    }

    private static func validateVersionSeven(_ db: SQLiteConnection) throws {
        try validateVersionSix(db)
        _ = try db.prepare("SELECT title_source,content_revision,title_revision,category_revision,lifecycle_token FROM inspirations LIMIT 0", operation: "validate_ai_metadata")
        _ = try db.prepare("SELECT system_prompt FROM chat_sessions LIMIT 0", operation: "validate_prompt_snapshot")
        guard try db.objectExists(type: "trigger", name: "inspiration_lifecycle") else { throw PersistenceError.invalidSchema(object: "inspiration_lifecycle") }
    }

    private static func validateVersionSix(_ connection: SQLiteConnection) throws {
        try validateVersionFive(connection)
        _ = try connection.prepare("SELECT title,draft FROM chat_sessions LIMIT 0", operation: "validate_chat_history")
        guard try connection.objectExists(type: "index", name: "chat_session_order") else {
            throw PersistenceError.invalidSchema(object: "chat_session_order")
        }
    }

    private static func validateVersionFive(_ connection: SQLiteConnection) throws {
        try validateVersionFour(connection)
        _ = try connection.prepare("SELECT id,slot,token,updated_at_utc_ms FROM chat_sessions LIMIT 0", operation: "validate_chat_session")
        _ = try connection.prepare("SELECT id,session_id,role,content,created_at_utc_ms,turn_token,attempt_token,state,error_code FROM chat_messages LIMIT 0", operation: "validate_chat_messages")
        guard try connection.objectExists(type: "index", name: "chat_message_order"),
              try connection.objectExists(type: "index", name: "inspiration_category_order") else { throw PersistenceError.invalidSchema(object: "chat_indexes") }
    }

    static func migrateVersionThreeToFour(_ connection: SQLiteConnection) throws {
        try connection.transaction {
            try connection.execute("ALTER TABLE prompts ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0; ALTER TABLE prompts ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0 CHECK(is_favorite IN (0,1)); ALTER TABLE inspirations ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0; UPDATE prompts SET sort_order = created_at_utc_ms; UPDATE inspirations SET sort_order = created_at_utc_ms; CREATE INDEX prompts_manual_order ON prompts(sort_order DESC,id DESC); CREATE INDEX inspirations_manual_order ON inspirations(sort_order DESC,id DESC); PRAGMA user_version = 4;", operation: "migrate_v4_library_order")
            try validateVersionFour(connection)
        }
    }
    private static func validateVersionFour(_ connection: SQLiteConnection) throws {
        try validateVersionThree(connection)
        _ = try connection.prepare("SELECT sort_order,is_favorite FROM prompts LIMIT 0", operation: "validate_v4_prompts")
        _ = try connection.prepare("SELECT sort_order FROM inspirations LIMIT 0", operation: "validate_v4_inspirations")
    }

    static func createMigrationBackup(
        databaseURL: URL,
        oldVersion: Int32,
        fileManager: FileManager = .default
    ) throws -> URL {
        let backupURL = databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(databaseURL.lastPathComponent).bak-v\(oldVersion)")

        guard !fileManager.fileExists(atPath: backupURL.path) else {
            throw PersistenceError.backupAlreadyExists(path: backupURL.path)
        }

        do {
            let source = try SQLiteConnection(databaseURL: databaseURL, readOnly: true, createIfMissing: false)
            defer { source.close() }
            try source.backup(to: backupURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: backupURL.path
            )
            return backupURL
        } catch {
            try? fileManager.removeItem(at: backupURL)
            throw PersistenceError.backupFailed(path: backupURL.path)
        }
    }

    static func createVersionOne(_ connection: SQLiteConnection) throws {
        try connection.transaction {
            try createVersionOneObjects(connection)
            try connection.setUserVersion(1)
        }
        try validateVersionOne(connection)
    }

    static func createVersionTwo(_ connection: SQLiteConnection) throws {
        try connection.transaction {
            try createVersionOneObjects(connection)
            try createClipboardObjects(connection)
            try connection.setUserVersion(2)
        }
        try validateVersionTwo(connection)
    }

    private static func migrateVersionOneToTwo(
        _ connection: SQLiteConnection
    ) throws {
        try validateVersionOne(connection)
        try connection.transaction {
            try createClipboardObjects(connection)
            try connection.setUserVersion(2)
        }
        try validateVersionTwo(connection)
    }

    static func migrateVersionTwoToThree(_ connection: SQLiteConnection) throws {
        try validateVersionTwo(connection)
        try connection.transaction {
            try connection.execute("""
                CREATE TABLE prompts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    title TEXT NOT NULL, content TEXT NOT NULL,
                    title_source TEXT NOT NULL CHECK(title_source IN ('ai','fallback','user')),
                    created_at_utc_ms INTEGER NOT NULL,
                    origin_kind TEXT NOT NULL CHECK(origin_kind IN ('clipboard','input')),
                    source_clipboard_id INTEGER UNIQUE REFERENCES clipboard_items(id) ON DELETE SET NULL,
                    source_application_name TEXT, source_bundle_identifier TEXT,
                    submission_token TEXT NOT NULL UNIQUE,
                    lifecycle_token TEXT NOT NULL,
                    title_revision INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX idx_prompts_created_at ON prompts(created_at_utc_ms DESC, id DESC);
                ALTER TABLE inspirations ADD COLUMN origin_kind TEXT NOT NULL DEFAULT 'manual';
                ALTER TABLE inspirations ADD COLUMN source_clipboard_id INTEGER REFERENCES clipboard_items(id) ON DELETE SET NULL;
                ALTER TABLE inspirations ADD COLUMN source_application_name TEXT;
                ALTER TABLE inspirations ADD COLUMN source_bundle_identifier TEXT;
                CREATE UNIQUE INDEX idx_inspirations_clipboard ON inspirations(source_clipboard_id);
                UPDATE clipboard_items SET is_favorited_to_prompt = 0;
                CREATE TRIGGER prompt_insert_flag AFTER INSERT ON prompts BEGIN
                    UPDATE clipboard_items SET is_favorited_to_prompt = 1 WHERE id = NEW.source_clipboard_id;
                END;
                CREATE TRIGGER prompt_delete_flag AFTER DELETE ON prompts BEGIN
                    UPDATE clipboard_items SET is_favorited_to_prompt = 0 WHERE id = OLD.source_clipboard_id;
                END;
                """, operation: "migrate_v3")
            try validateVersionThree(connection)
            try connection.setUserVersion(3)
        }
    }

    private static func validateVersionThree(_ connection: SQLiteConnection) throws {
        try validateVersionTwo(connection)
        for (type, name) in [("table", "prompts"), ("index", "idx_prompts_created_at"),
                             ("index", "idx_inspirations_clipboard"), ("trigger", "prompt_insert_flag"), ("trigger", "prompt_delete_flag")] {
            guard try connection.objectExists(type: type, name: name) else { throw PersistenceError.invalidSchema(object: name) }
        }
        _ = try connection.prepare("SELECT title,content,title_source,created_at_utc_ms,origin_kind,source_clipboard_id,source_application_name,source_bundle_identifier,submission_token,lifecycle_token,title_revision FROM prompts LIMIT 0", operation: "validate_prompt_columns")
        _ = try connection.prepare("SELECT origin_kind,source_clipboard_id,source_application_name,source_bundle_identifier FROM inspirations LIMIT 0", operation: "validate_origin_columns")
        let check = try connection.prepare("PRAGMA foreign_key_check", operation: "validate_relations")
        guard try !check.stepRow() else { throw PersistenceError.invalidSchema(object: "source_relations") }
    }

    private static func createVersionOneObjects(
        _ connection: SQLiteConnection
    ) throws {
        try connection.execute(
            """
            CREATE TABLE inspirations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                category TEXT NOT NULL
                    CHECK (category IN ('文章类', '作品类', '产品类', 'idea')),
                category_source TEXT NOT NULL
                    CHECK (category_source IN ('ai', 'fallback', 'user')),
                created_at_utc_ms INTEGER NOT NULL,
                updated_at_utc_ms INTEGER NOT NULL,
                source TEXT NOT NULL
                    CHECK (source IN ('manual', 'ai_chat'))
            )
            """,
            operation: "create_inspirations"
        )
        try connection.execute(
            """
            CREATE INDEX idx_inspirations_updated_at
                ON inspirations(updated_at_utc_ms DESC, id DESC)
            """,
            operation: "create_inspirations_index"
        )
        try connection.execute(
            """
            CREATE TABLE drafts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL UNIQUE
                    CHECK (kind IN ('inspiration', 'ai_chat')),
                content TEXT NOT NULL,
                updated_at_utc_ms INTEGER NOT NULL
            )
            """,
            operation: "create_drafts"
        )
    }

    private static func createClipboardObjects(
        _ connection: SQLiteConnection
    ) throws {
        try connection.execute(
            """
            CREATE TABLE clipboard_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content_type TEXT NOT NULL
                    CHECK (content_type IN ('text', 'link', 'image')),
                text_content TEXT,
                image_file_name TEXT,
                thumbnail_file_name TEXT,
                content_byte_count INTEGER NOT NULL
                    CHECK (content_byte_count >= 0),
                image_sha256 TEXT,
                image_width_px INTEGER,
                image_height_px INTEGER,
                copied_at_utc_ms INTEGER NOT NULL,
                source_application_name TEXT,
                source_bundle_identifier TEXT,
                is_favorited_to_prompt INTEGER NOT NULL DEFAULT 0
                    CHECK (is_favorited_to_prompt IN (0, 1)),
                CHECK (
                    (
                        content_type IN ('text', 'link')
                        AND text_content IS NOT NULL
                        AND image_file_name IS NULL
                        AND thumbnail_file_name IS NULL
                        AND image_sha256 IS NULL
                        AND image_width_px IS NULL
                        AND image_height_px IS NULL
                    )
                    OR
                    (
                        content_type = 'image'
                        AND text_content IS NULL
                        AND image_file_name IS NOT NULL
                        AND thumbnail_file_name IS NOT NULL
                        AND image_sha256 IS NOT NULL
                        AND image_width_px IS NOT NULL
                        AND image_width_px > 0
                        AND image_height_px IS NOT NULL
                        AND image_height_px > 0
                    )
                )
            )
            """,
            operation: "create_clipboard_items"
        )
        try connection.execute(
            """
            CREATE INDEX idx_clipboard_items_copied_at
                ON clipboard_items(copied_at_utc_ms DESC, id DESC)
            """,
            operation: "create_clipboard_items_time_index"
        )
        try connection.execute(
            """
            CREATE INDEX idx_clipboard_items_image_dedupe
                ON clipboard_items(
                    content_type,
                    content_byte_count,
                    image_sha256
                )
            """,
            operation: "create_clipboard_items_image_index"
        )
    }

    private static func validateVersionOne(_ connection: SQLiteConnection) throws {
        let requiredObjects = [
            ("table", "inspirations"),
            ("table", "drafts"),
            ("index", "idx_inspirations_updated_at")
        ]

        for (type, name) in requiredObjects {
            guard try connection.objectExists(type: type, name: name) else {
                throw PersistenceError.invalidSchema(object: name)
            }
        }
    }

    private static func validateVersionTwo(_ connection: SQLiteConnection) throws {
        try validateVersionOne(connection)
        let requiredObjects = [
            ("table", "clipboard_items"),
            ("index", "idx_clipboard_items_copied_at"),
            ("index", "idx_clipboard_items_image_dedupe")
        ]
        for (type, name) in requiredObjects {
            guard try connection.objectExists(type: type, name: name) else {
                throw PersistenceError.invalidSchema(object: name)
            }
        }
    }

    private static func mapCorruption<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as PersistenceError {
            switch error {
            case let .sqliteFailure(_, code)
                where code == SQLITE_CORRUPT || code == SQLITE_NOTADB:
                throw PersistenceError.corruptedDatabase(code: code)
            default:
                throw error
            }
        }
    }
}
