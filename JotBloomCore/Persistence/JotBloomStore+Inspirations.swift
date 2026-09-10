import Foundation

extension JotBloomStore {
    public func listInspirationsPage(after cursor: InspirationPageCursor?, limit: Int, category: InspirationCategory?) async throws -> InspirationPage {
        try await performAsync { try Self.listInspirationsPage(after: cursor, limit: limit, category: category, connection: $0) }
    }
    public static let inspirationPageLimit = 50
    public static let maximumInspirationPageLimit = 100

    // Compare the complete stored representation, not previews or the loaded page.
    // Clipboard imports contain their automatic title again in their body.
    static func duplicateInspiration(title: String, body: String, origin: String, excluding id: Int64? = nil, connection: SQLiteConnection) throws -> Int64? {
        let expected = body
        let query = try connection.prepare("SELECT id,title,body,origin_kind FROM inspirations WHERE id != ? ORDER BY id", operation: "deduplicate_inspiration")
        try query.bind(id ?? -1, at: 1)
        while try query.stepRow() {
            let candidate = query.text(at: 2)
            if expected == candidate { return query.int64(at: 0) }
        }
        return nil
    }

    public func listInspirationsPage(
        after cursor: InspirationPageCursor? = nil,
        limit: Int = inspirationPageLimit
    ) async throws -> InspirationPage {
        try await performAsync {
            try Self.listInspirationsPage(
                after: cursor,
                limit: limit,
                connection: $0
            )
        }
    }

    public func listInspirationsPageSynchronously(
        after cursor: InspirationPageCursor? = nil,
        limit: Int = inspirationPageLimit
    ) throws -> InspirationPage {
        try performSync {
            try Self.listInspirationsPage(
                after: cursor,
                limit: limit,
                connection: $0
            )
        }
    }

    public func inspiration(id: Int64) async throws -> Inspiration {
        try await performAsync {
            try Self.requireInspiration(id: id, connection: $0)
        }
    }

    public func inspirationSynchronously(id: Int64) throws -> Inspiration {
        try performSync {
            try Self.requireInspiration(id: id, connection: $0)
        }
    }

    public func updateInspirationText(
        id: Int64,
        title: String,
        body: String,
        updatedAtUTCms: Int64
    ) async throws -> Inspiration {
        try await performAsync {
            try Self.updateInspirationText(
                id: id,
                title: title,
                body: body,
                updatedAtUTCms: updatedAtUTCms,
                connection: $0
            )
        }
    }

    public func updateInspirationTextSynchronously(
        id: Int64,
        title: String,
        body: String,
        updatedAtUTCms: Int64
    ) throws -> Inspiration {
        try performSync {
            try Self.updateInspirationText(
                id: id,
                title: title,
                body: body,
                updatedAtUTCms: updatedAtUTCms,
                connection: $0
            )
        }
    }

    public func updateInspirationCategory(
        id: Int64,
        category: InspirationCategory,
        updatedAtUTCms: Int64
    ) async throws -> Inspiration {
        try await performAsync {
            try Self.updateInspirationCategory(
                id: id,
                category: category,
                updatedAtUTCms: updatedAtUTCms,
                connection: $0
            )
        }
    }

    public func updateInspirationCategorySynchronously(
        id: Int64,
        category: InspirationCategory,
        updatedAtUTCms: Int64
    ) throws -> Inspiration {
        try performSync {
            try Self.updateInspirationCategory(
                id: id,
                category: category,
                updatedAtUTCms: updatedAtUTCms,
                connection: $0
            )
        }
    }

    public func deleteInspiration(id: Int64) async throws -> Inspiration {
        try await performAsync {
            try Self.deleteInspiration(id: id, connection: $0)
        }
    }

    public func deleteInspirationSynchronously(id: Int64) throws -> Inspiration {
        try performSync {
            try Self.deleteInspiration(id: id, connection: $0)
        }
    }

    public func restoreInspiration(
        _ inspiration: Inspiration
    ) async throws -> Inspiration {
        try await performAsync {
            try Self.restoreInspiration(inspiration, connection: $0)
        }
    }

    public func restoreInspirationSynchronously(
        _ inspiration: Inspiration
    ) throws -> Inspiration {
        try performSync {
            try Self.restoreInspiration(inspiration, connection: $0)
        }
    }

    private static func listInspirationsPage(
        after cursor: InspirationPageCursor?,
        limit: Int,
        category: InspirationCategory? = nil,
        connection: SQLiteConnection
    ) throws -> InspirationPage {
        let boundedLimit = min(max(limit, 1), maximumInspirationPageLimit)
        let statement: SQLiteStatement
        if let cursor {
            statement = try connection.prepare(
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
                WHERE (sort_order < ?
                   OR (sort_order = ? AND id < ?)) AND (? IS NULL OR category = ?)
                ORDER BY sort_order DESC, id DESC
                LIMIT ?
                """,
                operation: "list_inspirations_page"
            )
            try statement.bind(cursor.sortOrder ?? cursor.updatedAtUTCms, at: 1)
            try statement.bind(cursor.sortOrder ?? cursor.updatedAtUTCms, at: 2)
            try statement.bind(cursor.id, at: 3)
            try statement.bind(category?.rawValue, at: 4)
            try statement.bind(category?.rawValue, at: 5)
            try statement.bind(Int64(boundedLimit + 1), at: 6)
        } else {
            statement = try connection.prepare(
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
                WHERE (? IS NULL OR category = ?)
                ORDER BY sort_order DESC, id DESC
                LIMIT ?
                """,
                operation: "list_inspirations_page"
            )
            try statement.bind(category?.rawValue, at: 1)
            try statement.bind(category?.rawValue, at: 2)
            try statement.bind(Int64(boundedLimit + 1), at: 3)
        }

        var items: [Inspiration] = []
        while try statement.stepRow() {
            items.append(try decodeInspiration(statement))
        }

        let hasMore = items.count > boundedLimit
        if hasMore {
            items.removeLast(items.count - boundedLimit)
        }
        let nextCursor = hasMore
            ? items.last.map {
                InspirationPageCursor(
                    updatedAtUTCms: $0.updatedAtUTCms,
                    id: $0.id, sortOrder: $0.sortOrder
                )
            }
            : nil
        return InspirationPage(items: items, nextCursor: nextCursor)
    }

    private static func requireInspiration(
        id: Int64,
        connection: SQLiteConnection
    ) throws -> Inspiration {
        guard let inspiration = try findInspiration(id: id, connection: connection) else {
            throw PersistenceError.inspirationNotFound(id: id)
        }
        return inspiration
    }

    private static func findInspiration(
        id: Int64,
        connection: SQLiteConnection
    ) throws -> Inspiration? {
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
            WHERE id = ?
            LIMIT 1
            """,
            operation: "find_inspiration"
        )
        try statement.bind(id, at: 1)
        guard try statement.stepRow() else { return nil }
        return try decodeInspiration(statement)
    }

    private static func updateInspirationText(
        id: Int64,
        title: String,
        body: String,
        updatedAtUTCms: Int64,
        connection: SQLiteConnection
    ) throws -> Inspiration {
        let current = try requireInspiration(id: id, connection: connection)
        guard current.title != title || current.body != body else {
            return current
        }
        guard try duplicateInspiration(title: title, body: body, origin: current.originKind, excluding: id, connection: connection) == nil else { throw PromptError.duplicateInspiration }
        let timestamp = try monotonicTimestamp(
            proposed: updatedAtUTCms,
            after: current.updatedAtUTCms
        )
        let statement = try connection.prepare(
            """
            UPDATE inspirations
            SET title_source=CASE WHEN title!=?1 THEN 'user' ELSE title_source END,
                title_revision=title_revision+CASE WHEN title!=?1 THEN 1 ELSE 0 END,
                content_revision=content_revision+CASE WHEN body!=?2 THEN 1 ELSE 0 END,
                title = ?1, body = ?2, updated_at_utc_ms = ?3
            WHERE id = ?4
            """,
            operation: "update_inspiration_text"
        )
        try statement.bind(title, at: 1)
        try statement.bind(body, at: 2)
        try statement.bind(timestamp, at: 3)
        try statement.bind(id, at: 4)
        try statement.executeDone()
        guard try connection.changesCount() == 1 else {
            throw PersistenceError.inspirationNotFound(id: id)
        }
        return try requireInspiration(id: id, connection: connection)
    }

    private static func updateInspirationCategory(
        id: Int64,
        category: InspirationCategory,
        updatedAtUTCms: Int64,
        connection: SQLiteConnection
    ) throws -> Inspiration {
        let current = try requireInspiration(id: id, connection: connection)
        guard current.category != category || current.categorySource != .user else {
            return current
        }
        let timestamp = try monotonicTimestamp(
            proposed: updatedAtUTCms,
            after: current.updatedAtUTCms
        )
        let statement = try connection.prepare(
            """
            UPDATE inspirations
            SET category = ?, category_source = ?, updated_at_utc_ms = ?, category_revision=category_revision+1
            WHERE id = ?
            """,
            operation: "update_inspiration_category"
        )
        try statement.bind(category.rawValue, at: 1)
        try statement.bind(ValueSource.user.rawValue, at: 2)
        try statement.bind(timestamp, at: 3)
        try statement.bind(id, at: 4)
        try statement.executeDone()
        guard try connection.changesCount() == 1 else {
            throw PersistenceError.inspirationNotFound(id: id)
        }
        return try requireInspiration(id: id, connection: connection)
    }

    private static func deleteInspiration(
        id: Int64,
        connection: SQLiteConnection
    ) throws -> Inspiration {
        let inspiration = try requireInspiration(id: id, connection: connection)
        let statement = try connection.prepare(
            "DELETE FROM inspirations WHERE id = ?",
            operation: "delete_inspiration"
        )
        try statement.bind(id, at: 1)
        try statement.executeDone()
        guard try connection.changesCount() == 1 else {
            throw PersistenceError.inspirationNotFound(id: id)
        }
        return inspiration
    }

    private static func restoreInspiration(
        _ inspiration: Inspiration,
        connection: SQLiteConnection
    ) throws -> Inspiration {
        return try connection.transaction {
        var sourceID = inspiration.sourceClipboardID
        if let id = sourceID {
            let query = try connection.prepare("SELECT id FROM clipboard_items WHERE id = ? AND NOT EXISTS(SELECT 1 FROM inspirations WHERE source_clipboard_id = ?)", operation: "restore_inspiration_source")
            try query.bind(id, at: 1); try query.bind(id, at: 2)
            if try !query.stepRow() { sourceID = nil }
        }
        let statement = try connection.prepare(
            """
            INSERT INTO inspirations(
                id,
                title,
                body,
                category,
                category_source,
                created_at_utc_ms,
                updated_at_utc_ms,
                source,origin_kind,source_clipboard_id,source_application_name,source_bundle_identifier,sort_order
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            operation: "restore_inspiration"
        )
        try statement.bind(inspiration.id, at: 1)
        try statement.bind(inspiration.title, at: 2)
        try statement.bind(inspiration.body, at: 3)
        try statement.bind(inspiration.category.rawValue, at: 4)
        try statement.bind(inspiration.categorySource.rawValue, at: 5)
        try statement.bind(inspiration.createdAtUTCms, at: 6)
        try statement.bind(inspiration.updatedAtUTCms, at: 7)
        try statement.bind(inspiration.source.rawValue, at: 8)
        try statement.bind(inspiration.originKind, at: 9)
        try statement.bind(sourceID.map(String.init), at: 10)
        try statement.bind(inspiration.sourceApplicationName, at: 11)
        try statement.bind(inspiration.sourceBundleIdentifier, at: 12)
        try statement.bind(inspiration.sortOrder, at: 13)
        try statement.executeDone()
        guard try connection.changesCount() == 1 else {
            throw PersistenceError.inspirationNotFound(id: inspiration.id)
        }
        let protect = try connection.prepare("UPDATE inspirations SET title_source='user' WHERE id=?", operation: "protect_restored_title")
        try protect.bind(inspiration.id, at: 1); try protect.executeDone()
        return try requireInspiration(id: inspiration.id, connection: connection)
        }
    }

    private static func monotonicTimestamp(
        proposed: Int64,
        after current: Int64
    ) throws -> Int64 {
        let (next, overflow) = current.addingReportingOverflow(1)
        guard !overflow else {
            throw PersistenceError.invalidStoredValue(
                column: "inspirations.updated_at_utc_ms"
            )
        }
        return max(proposed, next)
    }

    private static func decodeInspiration(
        _ statement: SQLiteStatement
    ) throws -> Inspiration {
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
        return Inspiration(
            id: statement.int64(at: 0),
            title: statement.text(at: 1),
            body: statement.text(at: 2),
            category: category,
            categorySource: categorySource,
            createdAtUTCms: statement.int64(at: 5),
            updatedAtUTCms: statement.int64(at: 6),
            source: source,
            originKind: statement.text(at: 8), sourceClipboardID: statement.isNull(at: 9) ? nil : statement.int64(at: 9),
            sourceApplicationName: statement.optionalText(at: 10), sourceBundleIdentifier: statement.optionalText(at: 11), sortOrder: statement.int64(at: 12)
        )
    }
}
