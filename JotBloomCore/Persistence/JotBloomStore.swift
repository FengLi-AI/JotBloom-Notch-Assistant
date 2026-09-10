import Foundation

public final class JotBloomStore: @unchecked Sendable {
    public static let recentInspirationLimit = 50

    public let dataDirectoryURL: URL
    public let databaseURL: URL
    public let clipboardDirectoryURL: URL

    private let queue = DispatchQueue(label: "com.jotbloom.mengsheng.sqlite")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var connection: SQLiteConnection?

    public init(
        dataDirectoryURL: URL,
        fileManager: FileManager = .default,
        requireExisting: Bool = false
    ) throws {
        self.dataDirectoryURL = dataDirectoryURL.standardizedFileURL
        databaseURL = self.dataDirectoryURL
            .appendingPathComponent(DataDirectoryResolver.databaseFileName)
        clipboardDirectoryURL = self.dataDirectoryURL
            .appendingPathComponent(
                DataDirectoryResolver.clipboardDirectoryName,
                isDirectory: true
            )

        queue.setSpecific(key: queueKey, value: 1)

        if requireExisting { try DataLocationStore.requireRegularFile(databaseURL) }

        do {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(
                atPath: self.dataDirectoryURL.path,
                isDirectory: &isDirectory
            ) {
                guard isDirectory.boolValue else {
                    throw PersistenceError.dataDirectoryUnavailable(
                        path: self.dataDirectoryURL.path
                    )
                }
            } else {
                guard !requireExisting else { throw SettingsError.unavailableDirectory }
                try fileManager.createDirectory(
                    at: self.dataDirectoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: self.dataDirectoryURL.path
            )
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.dataDirectoryUnavailable(
                path: self.dataDirectoryURL.path
            )
        }

        var openedConnection: SQLiteConnection?
        do {
            let initialConnection = try SQLiteConnection(databaseURL: databaseURL, createIfMissing: !requireExisting)
            openedConnection = initialConnection
            let existingVersion = try DatabaseMigrator.preflight(initialConnection)

            if existingVersion > 0, existingVersion < DatabaseMigrator.currentVersion {
                initialConnection.close()
                openedConnection = nil
                _ = try DatabaseMigrator.createMigrationBackup(
                    databaseURL: databaseURL,
                    oldVersion: existingVersion,
                    fileManager: fileManager
                )
                let migratedConnection = try SQLiteConnection(databaseURL: databaseURL, createIfMissing: !requireExisting)
                openedConnection = migratedConnection
            }

            guard let openedConnection else {
                throw PersistenceError.databaseClosed
            }
            try DatabaseMigrator.bootstrap(openedConnection)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: databaseURL.path
            )
            _ = try ClipboardAssetStore(
                dataDirectoryURL: self.dataDirectoryURL,
                fileManager: fileManager
            )
            self.connection = openedConnection
        } catch {
            openedConnection?.close()
            throw error
        }
    }

    deinit {
        connection?.close()
    }

    public func close() {
        syncWithoutThrow {
            connection?.close()
            connection = nil
        }
    }

    public func schemaVersion() async throws -> Int32 {
        try await performAsync { try $0.userVersion() }
    }

    public func schemaVersionSynchronously() throws -> Int32 {
        try performSync { try $0.userVersion() }
    }

    public func loadDraft(kind: DraftKind) async throws -> Draft? {
        try await performAsync { try Self.loadDraft(kind: kind, connection: $0) }
    }

    public func loadDraftSynchronously(kind: DraftKind) throws -> Draft? {
        try performSync { try Self.loadDraft(kind: kind, connection: $0) }
    }

    public func persistDraft(
        kind: DraftKind,
        content: String,
        updatedAtUTCms: Int64
    ) async throws {
        try await performAsync {
            try Self.persistDraft(
                kind: kind,
                content: content,
                updatedAtUTCms: updatedAtUTCms,
                connection: $0
            )
        }
    }

    public func persistDraftSynchronously(
        kind: DraftKind,
        content: String,
        updatedAtUTCms: Int64
    ) throws {
        try performSync {
            try Self.persistDraft(
                kind: kind,
                content: content,
                updatedAtUTCms: updatedAtUTCms,
                connection: $0
            )
        }
    }

    public func saveManualInspiration(
        _ parsed: ParsedInspiration,
        timestampUTCms: Int64
    ) async throws -> Inspiration {
        try await performAsync {
            try Self.saveManualInspiration(
                parsed,
                timestampUTCms: timestampUTCms,
                connection: $0
            )
        }
    }

    public func saveManualInspirationSynchronously(
        _ parsed: ParsedInspiration,
        timestampUTCms: Int64
    ) throws -> Inspiration {
        try performSync {
            try Self.saveManualInspiration(
                parsed,
                timestampUTCms: timestampUTCms,
                connection: $0
            )
        }
    }

    public func listRecentInspirations(limit: Int = recentInspirationLimit) async throws -> [Inspiration] {
        try await performAsync {
            try Self.listRecentInspirations(limit: limit, connection: $0)
        }
    }

    public func listRecentInspirationsSynchronously(
        limit: Int = recentInspirationLimit
    ) throws -> [Inspiration] {
        try performSync {
            try Self.listRecentInspirations(limit: limit, connection: $0)
        }
    }

    func performAsync<T>(
        _ operation: @escaping (SQLiteConnection) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let connection else {
                        throw PersistenceError.databaseClosed
                    }
                    continuation.resume(returning: try operation(connection))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func performSync<T>(
        _ operation: (SQLiteConnection) throws -> T
    ) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            guard let connection else {
                throw PersistenceError.databaseClosed
            }
            return try operation(connection)
        }

        return try queue.sync {
            guard let connection else {
                throw PersistenceError.databaseClosed
            }
            return try operation(connection)
        }
    }

    private func syncWithoutThrow(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }

    private static func loadDraft(
        kind: DraftKind,
        connection: SQLiteConnection
    ) throws -> Draft? {
        let statement = try connection.prepare(
            """
            SELECT id, kind, content, updated_at_utc_ms
            FROM drafts
            WHERE kind = ?
            LIMIT 1
            """,
            operation: "load_draft"
        )
        try statement.bind(kind.rawValue, at: 1)
        guard try statement.stepRow() else { return nil }

        guard let storedKind = DraftKind(rawValue: statement.text(at: 1)) else {
            throw PersistenceError.invalidStoredValue(column: "drafts.kind")
        }

        return Draft(
            id: statement.int64(at: 0),
            kind: storedKind,
            content: statement.text(at: 2),
            updatedAtUTCms: statement.int64(at: 3)
        )
    }

    private static func persistDraft(
        kind: DraftKind,
        content: String,
        updatedAtUTCms: Int64,
        connection: SQLiteConnection
    ) throws {
        if content.isEmpty {
            let statement = try connection.prepare(
                "DELETE FROM drafts WHERE kind = ?",
                operation: "clear_draft"
            )
            try statement.bind(kind.rawValue, at: 1)
            try statement.executeDone()
            return
        }

        let statement = try connection.prepare(
            """
            INSERT INTO drafts(kind, content, updated_at_utc_ms)
            VALUES (?, ?, ?)
            ON CONFLICT(kind) DO UPDATE SET
                content = excluded.content,
                updated_at_utc_ms = excluded.updated_at_utc_ms
            """,
            operation: "persist_draft"
        )
        try statement.bind(kind.rawValue, at: 1)
        try statement.bind(content, at: 2)
        try statement.bind(updatedAtUTCms, at: 3)
        try statement.executeDone()
    }

    private static func saveManualInspiration(
        _ parsed: ParsedInspiration,
        timestampUTCms: Int64,
        connection: SQLiteConnection
    ) throws -> Inspiration {
        try connection.transaction {
            guard try duplicateInspiration(title: parsed.title, body: parsed.completeText, origin: "manual", connection: connection) == nil else { throw PromptError.duplicateInspiration }
            let insert = try connection.prepare(
                """
                INSERT INTO inspirations(
                    title,
                    body,
                    category,
                    category_source,
                    created_at_utc_ms,
                    updated_at_utc_ms,
                    source, sort_order
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, (SELECT COALESCE(MAX(sort_order),0)+1 FROM inspirations))
                """,
                operation: "insert_inspiration"
            )
            try insert.bind(parsed.title, at: 1)
            try insert.bind(parsed.completeText, at: 2)
            try insert.bind(InspirationCategory.idea.rawValue, at: 3)
            try insert.bind(ValueSource.fallback.rawValue, at: 4)
            try insert.bind(timestampUTCms, at: 5)
            try insert.bind(timestampUTCms, at: 6)
            try insert.bind(InspirationSource.manual.rawValue, at: 7)
            try insert.executeDone()

            let identifier = try connection.lastInsertRowID()

            let clearDraft = try connection.prepare(
                "DELETE FROM drafts WHERE kind = ?",
                operation: "clear_draft_after_save"
            )
            try clearDraft.bind(DraftKind.inspiration.rawValue, at: 1)
            try clearDraft.executeDone()

            let savedOrder = try connection.prepare("SELECT sort_order FROM inspirations WHERE id = ?", operation: "read_inserted_order")
            try savedOrder.bind(identifier, at: 1)
            _ = try savedOrder.stepRow()
            return Inspiration(
                id: identifier,
                title: parsed.title,
                body: parsed.completeText,
                category: .idea,
                categorySource: .fallback,
                createdAtUTCms: timestampUTCms,
                updatedAtUTCms: timestampUTCms,
                source: .manual,
                sortOrder: savedOrder.int64(at: 0)
            )
        }
    }

    private static func listRecentInspirations(
        limit: Int,
        connection: SQLiteConnection
    ) throws -> [Inspiration] {
        guard limit > 0 else { return [] }
        let boundedLimit = min(limit, recentInspirationLimit)
        let statement = try connection.prepare(
            """
            SELECT
                id,
                title,
                body,
                category,
                category_source,
                created_at_utc_ms,
                updated_at_utc_ms,
                source,origin_kind,source_clipboard_id,source_application_name,source_bundle_identifier,sort_order
            FROM inspirations
            ORDER BY created_at_utc_ms DESC, id DESC
            LIMIT ?
            """,
            operation: "list_recent_inspirations"
        )
        try statement.bind(Int64(boundedLimit), at: 1)

        var values: [Inspiration] = []
        while try statement.stepRow() {
            guard let category = InspirationCategory(rawValue: statement.text(at: 3)) else {
                throw PersistenceError.invalidStoredValue(
                    column: "inspirations.category"
                )
            }
            guard let categorySource = ValueSource(rawValue: statement.text(at: 4)) else {
                throw PersistenceError.invalidStoredValue(
                    column: "inspirations.category_source"
                )
            }
            guard let source = InspirationSource(rawValue: statement.text(at: 7)) else {
                throw PersistenceError.invalidStoredValue(
                    column: "inspirations.source"
                )
            }

            values.append(
                Inspiration(
                    id: statement.int64(at: 0),
                    title: statement.text(at: 1),
                    body: statement.text(at: 2),
                    category: category,
                    categorySource: categorySource,
                    createdAtUTCms: statement.int64(at: 5),
                    updatedAtUTCms: statement.int64(at: 6),
                    source: source,
                    originKind: statement.text(at: 8), sourceClipboardID: statement.isNull(at: 9) ? nil : statement.int64(at: 9),
                    sourceApplicationName: statement.optionalText(at: 10), sourceBundleIdentifier: statement.optionalText(at: 11),
                    sortOrder: statement.int64(at: 12)
                )
            )
        }
        return values
    }
}
