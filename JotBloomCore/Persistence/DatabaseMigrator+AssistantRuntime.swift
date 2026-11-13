import Foundation

extension DatabaseMigrator {
    static func migrateVersionNineToTen(_ db: SQLiteConnection) throws {
        try db.transaction {
            try db.execute("CREATE TABLE assistant_task_runtime(task_id TEXT PRIMARY KEY NOT NULL REFERENCES assistant_tasks(id) ON DELETE CASCADE, state_json TEXT NOT NULL); PRAGMA user_version=10", operation: "migrate_v10_runtime")
            try validateVersionTen(db)
        }
    }
    static func validateVersionTen(_ db: SQLiteConnection) throws {
        try validateVersionNine(db)
        _ = try db.prepare("SELECT task_id,state_json FROM assistant_task_runtime LIMIT 0", operation: "validate_runtime")
    }
}
