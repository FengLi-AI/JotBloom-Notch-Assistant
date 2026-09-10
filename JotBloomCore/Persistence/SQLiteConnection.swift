import Foundation
import SQLite3

private let jotBloomSQLiteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(databaseURL: URL, readOnly: Bool = false, createIfMissing: Bool = true) throws {
        var database: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | (createIfMissing ? SQLITE_OPEN_CREATE : 0)) | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(databaseURL.path, &database, flags, nil)

        guard result == SQLITE_OK, let database else {
            if let database {
                sqlite3_close_v2(database)
            }
            throw PersistenceError.databaseOpenFailed(code: result)
        }

        handle = database
        sqlite3_busy_timeout(database, 2_000)
    }

    deinit {
        close()
    }

    func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    func execute(_ sql: String, operation: String) throws {
        let database = try openHandle()
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        if let message {
            sqlite3_free(message)
        }
        guard result == SQLITE_OK else {
            throw PersistenceError.sqliteFailure(operation: operation, code: result)
        }
    }

    func prepare(_ sql: String, operation: String) throws -> SQLiteStatement {
        let database = try openHandle()
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw PersistenceError.sqliteFailure(operation: operation, code: result)
        }
        return SQLiteStatement(handle: statement, operation: operation)
    }

    func userVersion() throws -> Int32 {
        let statement = try prepare("PRAGMA user_version", operation: "read_user_version")
        guard try statement.stepRow() else {
            throw PersistenceError.invalidSchema(object: "user_version")
        }
        return Int32(statement.int64(at: 0))
    }

    func backup(to url: URL) throws {
        let destination = try SQLiteConnection(databaseURL: url)
        defer { destination.close() }
        guard let backup = sqlite3_backup_init(try destination.openHandle(), "main", try openHandle(), "main") else {
            throw SettingsError.migrationFailed
        }
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else { throw SettingsError.migrationFailed }
        let check = try destination.prepare("PRAGMA integrity_check", operation: "validate_migration")
        guard try check.stepRow(), check.text(at: 0) == "ok" else { throw SettingsError.migrationFailed }
    }

    func setUserVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version = \(version)", operation: "write_user_version")
    }

    func objectExists(type: String, name: String) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM sqlite_master WHERE type = ? AND name = ? LIMIT 1",
            operation: "validate_schema"
        )
        try statement.bind(type, at: 1)
        try statement.bind(name, at: 2)
        return try statement.stepRow()
    }

    func lastInsertRowID() throws -> Int64 {
        sqlite3_last_insert_rowid(try openHandle())
    }

    func changesCount() throws -> Int64 {
        Int64(sqlite3_changes64(try openHandle()))
    }

    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE", operation: "begin_transaction")
        do {
            let result = try operation()
            try execute("COMMIT", operation: "commit_transaction")
            return result
        } catch {
            try? execute("ROLLBACK", operation: "rollback_transaction")
            throw error
        }
    }

    private func openHandle() throws -> OpaquePointer {
        guard let handle else {
            throw PersistenceError.databaseClosed
        }
        return handle
    }
}

final class SQLiteStatement {
    private var handle: OpaquePointer?
    private let operation: String

    init(handle: OpaquePointer, operation: String) {
        self.handle = handle
        self.operation = operation
    }

    deinit {
        if let handle {
            sqlite3_finalize(handle)
        }
    }

    func bind(_ value: String, at index: Int32) throws {
        let statement = try openHandle()
        var bytes = Array(value.utf8)
        bytes.append(0)
        let result = bytes.withUnsafeBufferPointer { buffer -> Int32 in
            sqlite3_bind_text(
                statement,
                index,
                UnsafePointer<CChar>(OpaquePointer(buffer.baseAddress)),
                Int32(buffer.count - 1),
                jotBloomSQLiteTransient
            )
        }
        try validate(result, suffix: "bind_text")
    }

    func bind(_ value: String?, at index: Int32) throws {
        if let value {
            try bind(value, at: index)
        } else {
            try validate(
                sqlite3_bind_null(try openHandle(), index),
                suffix: "bind_null"
            )
        }
    }

    func bind(_ value: Int64, at index: Int32) throws {
        try validate(
            sqlite3_bind_int64(try openHandle(), index, sqlite3_int64(value)),
            suffix: "bind_int64"
        )
    }

    func stepRow() throws -> Bool {
        let result = sqlite3_step(try openHandle())
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw PersistenceError.sqliteFailure(operation: operation, code: result)
        }
    }

    func executeDone() throws {
        guard try !stepRow() else {
            throw PersistenceError.sqliteFailure(operation: operation, code: SQLITE_MISUSE)
        }
    }

    func reset() throws {
        try validate(sqlite3_reset(try openHandle()), suffix: "reset")
        try validate(sqlite3_clear_bindings(try openHandle()), suffix: "clear_bindings")
    }

    func int64(at index: Int32) -> Int64 {
        guard let handle else { return 0 }
        return Int64(sqlite3_column_int64(handle, index))
    }

    func text(at index: Int32) -> String {
        guard let handle,
              let pointer = sqlite3_column_text(handle, index) else {
            return ""
        }
        let count = Int(sqlite3_column_bytes(handle, index))
        let buffer = UnsafeBufferPointer(start: pointer, count: count)
        return String(decoding: buffer, as: UTF8.self)
    }

    func optionalText(at index: Int32) -> String? {
        guard let handle,
              sqlite3_column_type(handle, index) != SQLITE_NULL else {
            return nil
        }
        return text(at: index)
    }

    func isNull(at index: Int32) -> Bool {
        guard let handle else { return true }
        return sqlite3_column_type(handle, index) == SQLITE_NULL
    }

    private func openHandle() throws -> OpaquePointer {
        guard let handle else {
            throw PersistenceError.databaseClosed
        }
        return handle
    }

    private func validate(_ result: Int32, suffix: String) throws {
        guard result == SQLITE_OK else {
            throw PersistenceError.sqliteFailure(
                operation: "\(operation)_\(suffix)",
                code: result
            )
        }
    }
}
