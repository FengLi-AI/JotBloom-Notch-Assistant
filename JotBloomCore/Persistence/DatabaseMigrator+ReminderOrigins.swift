import Foundation

extension DatabaseMigrator {
    static func migrateVersionElevenToTwelve(_ db: SQLiteConnection) throws {
        try db.transaction {
            try db.execute("""
                ALTER TABLE assistant_reminders ADD COLUMN origin TEXT NOT NULL DEFAULT 'auto' CHECK(origin IN ('auto','user','explicit','agent'));
                PRAGMA user_version=12;
                """, operation: "migrate_v12_reminder_origins")
            try validateVersionTwelve(db)
        }
    }
    static func validateVersionTwelve(_ db: SQLiteConnection) throws {
        try validateVersionEleven(db)
        _ = try db.prepare("SELECT origin FROM assistant_reminders LIMIT 0", operation: "validate_reminder_origins")
    }
}
