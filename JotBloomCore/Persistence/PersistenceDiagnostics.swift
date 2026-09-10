import Foundation

public struct PersistenceFailureMetadata: Equatable, Sendable {
    public let kind: String
    public let sqliteResultCode: Int32?
    public let foundSchemaVersion: Int32?

    public init(
        kind: String,
        sqliteResultCode: Int32?,
        foundSchemaVersion: Int32?
    ) {
        self.kind = kind
        self.sqliteResultCode = sqliteResultCode
        self.foundSchemaVersion = foundSchemaVersion
    }
}

public enum PersistenceDiagnostics {
    public static func metadata(for error: Error) -> PersistenceFailureMetadata {
        guard let error = error as? PersistenceError else {
            return PersistenceFailureMetadata(
                kind: String(describing: type(of: error)),
                sqliteResultCode: nil,
                foundSchemaVersion: nil
            )
        }

        switch error {
        case .dataDirectoryUnavailable:
            return metadata(kind: "data_directory_unavailable")
        case .invalidDebugDataDirectory:
            return metadata(kind: "invalid_debug_data_directory")
        case let .databaseOpenFailed(code):
            return metadata(kind: "database_open_failed", sqliteResultCode: code)
        case .databaseClosed:
            return metadata(kind: "database_closed")
        case let .corruptedDatabase(code):
            return metadata(kind: "corrupted_database", sqliteResultCode: code)
        case let .unsupportedSchema(found, _):
            return metadata(
                kind: "unsupported_schema",
                foundSchemaVersion: found
            )
        case .invalidSchema:
            return metadata(kind: "invalid_schema")
        case .invalidStoredValue:
            return metadata(kind: "invalid_stored_value")
        case .inspirationNotFound:
            return metadata(kind: "inspiration_not_found")
        case let .sqliteFailure(_, code):
            return metadata(kind: "sqlite_failure", sqliteResultCode: code)
        case .backupAlreadyExists:
            return metadata(kind: "backup_already_exists")
        case .backupFailed:
            return metadata(kind: "backup_failed")
        case .clipboardDirectoryUnavailable:
            return metadata(kind: "clipboard_directory_unavailable")
        case .invalidClipboardAssetName:
            return metadata(kind: "invalid_clipboard_asset_name")
        case .clipboardAssetOperationFailed:
            return metadata(kind: "clipboard_asset_operation_failed")
        }
    }

    private static func metadata(
        kind: String,
        sqliteResultCode: Int32? = nil,
        foundSchemaVersion: Int32? = nil
    ) -> PersistenceFailureMetadata {
        PersistenceFailureMetadata(
            kind: kind,
            sqliteResultCode: sqliteResultCode,
            foundSchemaVersion: foundSchemaVersion
        )
    }
}
