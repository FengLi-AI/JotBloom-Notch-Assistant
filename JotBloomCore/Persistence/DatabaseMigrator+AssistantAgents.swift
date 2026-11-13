import Foundation

extension DatabaseMigrator {
    static func migrateVersionTenToEleven(_ db: SQLiteConnection) throws {
        try db.transaction {
            try db.execute("""
            CREATE TABLE assistant_agent_sessions(task_id TEXT PRIMARY KEY NOT NULL REFERENCES assistant_tasks(id) ON DELETE CASCADE, state_json TEXT NOT NULL);
            CREATE TABLE assistant_owned_threads(thread_id TEXT PRIMARY KEY NOT NULL);
            PRAGMA user_version=11;
            """, operation: "migrate_v11_agents")
            try validateVersionEleven(db)
        }
    }
    static func validateVersionEleven(_ db: SQLiteConnection) throws {
        try validateVersionTen(db)
        _ = try db.prepare("SELECT task_id,state_json FROM assistant_agent_sessions LIMIT 0", operation: "validate_agent_sessions")
        _ = try db.prepare("SELECT thread_id FROM assistant_owned_threads LIMIT 0", operation: "validate_owned_threads")
    }
}
