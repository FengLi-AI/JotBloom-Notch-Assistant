import Foundation

extension JotBloomStore {
    public func listClipboardItems() async throws -> [ClipboardItem] {
        try await performAsync { try Self.listClipboardItems(connection: $0) }
    }

    public func listClipboardItemsSynchronously() throws -> [ClipboardItem] {
        try performSync { try Self.listClipboardItems(connection: $0) }
    }

    public func upsertClipboardTextSynchronously(
        text: String,
        contentType: ClipboardContentType,
        copiedAtUTCms: Int64,
        sourceApplication: ClipboardSourceApplication
    ) throws -> ClipboardCaptureOutcome {
        guard contentType == .text || contentType == .link else {
            throw PersistenceError.invalidStoredValue(
                column: "clipboard_items.content_type"
            )
        }

        return try performSync { connection in
            if let existing = try Self.findText(
                text,
                connection: connection
            ) {
                try Self.refreshClipboardItem(
                    id: existing.id,
                    contentType: contentType,
                    copiedAtUTCms: copiedAtUTCms,
                    sourceApplication: sourceApplication,
                    connection: connection
                )
                guard let refreshed = try Self.findClipboardItem(
                    id: existing.id,
                    connection: connection
                ) else {
                    throw PersistenceError.invalidStoredValue(
                        column: "clipboard_items.id"
                    )
                }
                return .refreshed(refreshed)
            }

            let statement = try connection.prepare(
                """
                INSERT INTO clipboard_items(
                    content_type,
                    text_content,
                    image_file_name,
                    thumbnail_file_name,
                    content_byte_count,
                    image_sha256,
                    image_width_px,
                    image_height_px,
                    copied_at_utc_ms,
                    source_application_name,
                    source_bundle_identifier,
                    is_favorited_to_prompt
                )
                VALUES (?, ?, NULL, NULL, ?, NULL, NULL, NULL, ?, ?, ?, 0)
                """,
                operation: "insert_clipboard_text"
            )
            try statement.bind(contentType.rawValue, at: 1)
            try statement.bind(text, at: 2)
            try statement.bind(
                ClipboardContentClassifier.utf8ByteCount(of: text),
                at: 3
            )
            try statement.bind(copiedAtUTCms, at: 4)
            try statement.bind(sourceApplication.name, at: 5)
            try statement.bind(sourceApplication.bundleIdentifier, at: 6)
            try statement.executeDone()

            let identifier = try connection.lastInsertRowID()
            guard let inserted = try Self.findClipboardItem(
                id: identifier,
                connection: connection
            ) else {
                throw PersistenceError.invalidStoredValue(
                    column: "clipboard_items.id"
                )
            }
            return .inserted(inserted)
        }
    }

    public func refreshMatchingClipboardImageSynchronously(
        byteCount: Int64,
        sha256: String,
        copiedAtUTCms: Int64,
        sourceApplication: ClipboardSourceApplication
    ) throws -> ClipboardItem? {
        try performSync { connection in
            guard let existing = try Self.findImage(
                byteCount: byteCount,
                sha256: sha256,
                connection: connection
            ) else {
                return nil
            }
            try Self.refreshClipboardItem(
                id: existing.id,
                contentType: .image,
                copiedAtUTCms: copiedAtUTCms,
                sourceApplication: sourceApplication,
                connection: connection
            )
            return try Self.findClipboardItem(
                id: existing.id,
                connection: connection
            )
        }
    }

    public func matchingClipboardImageSynchronously(
        byteCount: Int64,
        sha256: String
    ) throws -> ClipboardItem? {
        try performSync {
            try Self.findImage(
                byteCount: byteCount,
                sha256: sha256,
                connection: $0
            )
        }
    }

    public func refreshClipboardItemSynchronously(
        id: Int64,
        contentType: ClipboardContentType,
        copiedAtUTCms: Int64,
        sourceApplication: ClipboardSourceApplication
    ) throws -> ClipboardItem {
        try performSync { connection in
            try Self.refreshClipboardItem(
                id: id,
                contentType: contentType,
                copiedAtUTCms: copiedAtUTCms,
                sourceApplication: sourceApplication,
                connection: connection
            )
            guard let refreshed = try Self.findClipboardItem(
                id: id,
                connection: connection
            ) else {
                throw PersistenceError.invalidStoredValue(
                    column: "clipboard_items.id"
                )
            }
            return refreshed
        }
    }

    public func insertClipboardImageSynchronously(
        names: ClipboardAssetNames,
        byteCount: Int64,
        sha256: String,
        widthPixels: Int,
        heightPixels: Int,
        copiedAtUTCms: Int64,
        sourceApplication: ClipboardSourceApplication
    ) throws -> ClipboardItem {
        try performSync { connection in
            let statement = try connection.prepare(
                """
                INSERT INTO clipboard_items(
                    content_type,
                    text_content,
                    image_file_name,
                    thumbnail_file_name,
                    content_byte_count,
                    image_sha256,
                    image_width_px,
                    image_height_px,
                    copied_at_utc_ms,
                    source_application_name,
                    source_bundle_identifier,
                    is_favorited_to_prompt
                )
                VALUES ('image', NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                """,
                operation: "insert_clipboard_image"
            )
            try statement.bind(names.imageFileName, at: 1)
            try statement.bind(names.thumbnailFileName, at: 2)
            try statement.bind(byteCount, at: 3)
            try statement.bind(sha256, at: 4)
            try statement.bind(Int64(widthPixels), at: 5)
            try statement.bind(Int64(heightPixels), at: 6)
            try statement.bind(copiedAtUTCms, at: 7)
            try statement.bind(sourceApplication.name, at: 8)
            try statement.bind(sourceApplication.bundleIdentifier, at: 9)
            try statement.executeDone()

            let identifier = try connection.lastInsertRowID()
            guard let inserted = try Self.findClipboardItem(
                id: identifier,
                connection: connection
            ) else {
                throw PersistenceError.invalidStoredValue(
                    column: "clipboard_items.id"
                )
            }
            return inserted
        }
    }

    public func deleteClipboardItemSynchronously(
        id: Int64
    ) throws -> ClipboardItem? {
        try performSync { connection in
            guard let item = try Self.findClipboardItem(
                id: id,
                connection: connection
            ) else {
                return nil
            }
            try connection.transaction {
                let statement = try connection.prepare(
                    "DELETE FROM clipboard_items WHERE id = ?",
                    operation: "delete_clipboard_item"
                )
                try statement.bind(id, at: 1)
                try statement.executeDone()
            }
            return item
        }
    }

    public func deleteClipboardItemsSynchronously(
        ids: [Int64], matching snapshot: [ClipboardItem]? = nil
    ) throws -> [ClipboardItem] {
        guard !ids.isEmpty else { return [] }
        return try performSync { connection in
            let expected = snapshot.map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
            var items: [ClipboardItem] = []
            for id in ids {
                if let item = try Self.findClipboardItem(
                    id: id,
                    connection: connection
                ) {
                    if let expected, expected[id] != item { continue }
                    items.append(item)
                }
            }
            try connection.transaction {
                let statement = try connection.prepare(
                    "DELETE FROM clipboard_items WHERE id = ?",
                    operation: "delete_clipboard_items"
                )
                for item in items {
                    try statement.bind(item.id, at: 1)
                    try statement.executeDone()
                    try statement.reset()
                }
            }
            return items
        }
    }

    public func restoreClipboardItemSynchronously(
        _ item: ClipboardItem
    ) throws -> ClipboardItem {
        try performSync { connection in
            let existing: ClipboardItem?
            switch item.contentType {
            case .text, .link:
                existing = try item.textContent.flatMap {
                    try Self.findText($0, connection: connection)
                }
            case .image:
                if let hash = item.imageSHA256 {
                    existing = try Self.findImage(
                        byteCount: item.contentByteCount,
                        sha256: hash,
                        connection: connection
                    )
                } else {
                    existing = nil
                }
            }
            if let existing {
                return existing
            }

            let statement = try connection.prepare(
                """
                INSERT INTO clipboard_items(
                    id,
                    content_type,
                    text_content,
                    image_file_name,
                    thumbnail_file_name,
                    content_byte_count,
                    image_sha256,
                    image_width_px,
                    image_height_px,
                    copied_at_utc_ms,
                    source_application_name,
                    source_bundle_identifier,
                    is_favorited_to_prompt
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                operation: "restore_clipboard_item"
            )
            try statement.bind(item.id, at: 1)
            try statement.bind(item.contentType.rawValue, at: 2)
            try statement.bind(item.textContent, at: 3)
            try statement.bind(item.imageFileName, at: 4)
            try statement.bind(item.thumbnailFileName, at: 5)
            try statement.bind(item.contentByteCount, at: 6)
            try statement.bind(item.imageSHA256, at: 7)
            try Self.bindOptionalInteger(
                item.imageWidthPixels,
                statement: statement,
                index: 8
            )
            try Self.bindOptionalInteger(
                item.imageHeightPixels,
                statement: statement,
                index: 9
            )
            try statement.bind(item.copiedAtUTCms, at: 10)
            try statement.bind(item.sourceApplication.name, at: 11)
            try statement.bind(item.sourceApplication.bundleIdentifier, at: 12)
            // Deleted sources have already been detached from saved targets.
            try statement.bind(Int64(0), at: 13)
            try statement.executeDone()
            return try Self.findClipboardItem(id: item.id, connection: connection) ?? item
        }
    }

    public func referencedClipboardAssetFileNamesSynchronously() throws -> Set<String> {
        try performSync { connection in
            let statement = try connection.prepare(
                """
                SELECT image_file_name, thumbnail_file_name
                FROM clipboard_items
                WHERE content_type = 'image'
                """,
                operation: "list_clipboard_asset_references"
            )
            var names = Set<String>()
            while try statement.stepRow() {
                if let image = statement.optionalText(at: 0) {
                    names.insert(image)
                }
                if let thumbnail = statement.optionalText(at: 1) {
                    names.insert(thumbnail)
                }
            }
            return names
        }
    }

    private static let clipboardSelection = """
        SELECT
            id,
            content_type,
            text_content,
            image_file_name,
            thumbnail_file_name,
            content_byte_count,
            image_sha256,
            image_width_px,
            image_height_px,
            copied_at_utc_ms,
            source_application_name,
            source_bundle_identifier,
            is_favorited_to_prompt
        FROM clipboard_items
        """

    private static func listClipboardItems(
        connection: SQLiteConnection
    ) throws -> [ClipboardItem] {
        let statement = try connection.prepare(
            clipboardSelection
                + " ORDER BY copied_at_utc_ms DESC, id DESC",
            operation: "list_clipboard_items"
        )
        var items: [ClipboardItem] = []
        while try statement.stepRow() {
            items.append(try decodeClipboardItem(statement))
        }
        return items
    }

    private static func findClipboardItem(
        id: Int64,
        connection: SQLiteConnection
    ) throws -> ClipboardItem? {
        let statement = try connection.prepare(
            clipboardSelection + " WHERE id = ? LIMIT 1",
            operation: "find_clipboard_item"
        )
        try statement.bind(id, at: 1)
        return try statement.stepRow() ? decodeClipboardItem(statement) : nil
    }

    private static func findText(
        _ text: String,
        connection: SQLiteConnection
    ) throws -> ClipboardItem? {
        let statement = try connection.prepare(
            clipboardSelection
                + """
                 WHERE content_type IN ('text', 'link')
                   AND text_content = ?
                 ORDER BY id ASC
                 LIMIT 1
                """,
            operation: "find_clipboard_text"
        )
        try statement.bind(text, at: 1)
        return try statement.stepRow() ? decodeClipboardItem(statement) : nil
    }

    private static func findImage(
        byteCount: Int64,
        sha256: String,
        connection: SQLiteConnection
    ) throws -> ClipboardItem? {
        let statement = try connection.prepare(
            clipboardSelection
                + """
                 WHERE content_type = 'image'
                   AND content_byte_count = ?
                   AND image_sha256 = ?
                 ORDER BY id ASC
                 LIMIT 1
                """,
            operation: "find_clipboard_image"
        )
        try statement.bind(byteCount, at: 1)
        try statement.bind(sha256, at: 2)
        return try statement.stepRow() ? decodeClipboardItem(statement) : nil
    }

    private static func refreshClipboardItem(
        id: Int64,
        contentType: ClipboardContentType,
        copiedAtUTCms: Int64,
        sourceApplication: ClipboardSourceApplication,
        connection: SQLiteConnection
    ) throws {
        let statement = try connection.prepare(
            """
            UPDATE clipboard_items
            SET content_type = ?,
                copied_at_utc_ms = ?,
                source_application_name = ?,
                source_bundle_identifier = ?
            WHERE id = ?
            """,
            operation: "refresh_clipboard_item"
        )
        try statement.bind(contentType.rawValue, at: 1)
        try statement.bind(copiedAtUTCms, at: 2)
        try statement.bind(sourceApplication.name, at: 3)
        try statement.bind(sourceApplication.bundleIdentifier, at: 4)
        try statement.bind(id, at: 5)
        try statement.executeDone()
    }

    private static func decodeClipboardItem(
        _ statement: SQLiteStatement
    ) throws -> ClipboardItem {
        guard let contentType = ClipboardContentType(
            rawValue: statement.text(at: 1)
        ) else {
            throw PersistenceError.invalidStoredValue(
                column: "clipboard_items.content_type"
            )
        }

        let favoriteValue = statement.int64(at: 12)
        guard favoriteValue == 0 || favoriteValue == 1 else {
            throw PersistenceError.invalidStoredValue(
                column: "clipboard_items.is_favorited_to_prompt"
            )
        }

        return ClipboardItem(
            id: statement.int64(at: 0),
            contentType: contentType,
            textContent: statement.optionalText(at: 2),
            imageFileName: statement.optionalText(at: 3),
            thumbnailFileName: statement.optionalText(at: 4),
            contentByteCount: statement.int64(at: 5),
            imageSHA256: statement.optionalText(at: 6),
            imageWidthPixels: statement.isNull(at: 7)
                ? nil
                : Int(statement.int64(at: 7)),
            imageHeightPixels: statement.isNull(at: 8)
                ? nil
                : Int(statement.int64(at: 8)),
            copiedAtUTCms: statement.int64(at: 9),
            sourceApplication: ClipboardSourceApplication(
                name: statement.optionalText(at: 10),
                bundleIdentifier: statement.optionalText(at: 11)
            ),
            isFavoritedToPrompt: favoriteValue == 1
        )
    }

    private static func bindOptionalInteger(
        _ value: Int?,
        statement: SQLiteStatement,
        index: Int32
    ) throws {
        if let value {
            try statement.bind(Int64(value), at: index)
        } else {
            try statement.bind(nil as String?, at: index)
        }
    }
}
