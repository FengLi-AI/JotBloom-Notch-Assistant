#if DEBUG
import Foundation

public struct StageThreeDatabaseSnapshot: Equatable, Sendable {
    public let schemaVersion: Int32
    public let inspirationTitle: String?
    public let inspirationBody: String?
    public let draftContent: String?
    public let hasClipboardTable: Bool

    public init(
        schemaVersion: Int32,
        inspirationTitle: String?,
        inspirationBody: String?,
        draftContent: String?,
        hasClipboardTable: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.inspirationTitle = inspirationTitle
        self.inspirationBody = inspirationBody
        self.draftContent = draftContent
        self.hasClipboardTable = hasClipboardTable
    }
}

public enum StageThreeDebugHarness {
    public static func createVersionOneFixture(
        dataDirectoryURL: URL,
        inspirationTitle: String,
        inspirationBody: String,
        draftContent: String
    ) throws {
        try FileManager.default.createDirectory(
            at: dataDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let databaseURL = dataDirectoryURL.appendingPathComponent(
            DataDirectoryResolver.databaseFileName
        )
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        defer { connection.close() }
        try DatabaseMigrator.createVersionOne(connection)

        let inspiration = try connection.prepare(
            """
            INSERT INTO inspirations(
                title,
                body,
                category,
                category_source,
                created_at_utc_ms,
                updated_at_utc_ms,
                source
            ) VALUES (?, ?, 'idea', 'fallback', 1, 2, 'manual')
            """,
            operation: "stage3_fixture_inspiration"
        )
        try inspiration.bind(inspirationTitle, at: 1)
        try inspiration.bind(inspirationBody, at: 2)
        try inspiration.executeDone()

        let draft = try connection.prepare(
            """
            INSERT INTO drafts(kind, content, updated_at_utc_ms)
            VALUES ('inspiration', ?, 3)
            """,
            operation: "stage3_fixture_draft"
        )
        try draft.bind(draftContent, at: 1)
        try draft.executeDone()
    }

    public static func inspectDatabase(
        databaseURL: URL
    ) throws -> StageThreeDatabaseSnapshot {
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        defer { connection.close() }

        let inspiration = try connection.prepare(
            """
            SELECT title, body
            FROM inspirations
            ORDER BY id ASC
            LIMIT 1
            """,
            operation: "stage3_inspect_inspiration"
        )
        let hasInspiration = try inspiration.stepRow()
        let draft = try connection.prepare(
            """
            SELECT content
            FROM drafts
            WHERE kind = 'inspiration'
            LIMIT 1
            """,
            operation: "stage3_inspect_draft"
        )
        let hasDraft = try draft.stepRow()

        return StageThreeDatabaseSnapshot(
            schemaVersion: try connection.userVersion(),
            inspirationTitle: hasInspiration ? inspiration.text(at: 0) : nil,
            inspirationBody: hasInspiration ? inspiration.text(at: 1) : nil,
            draftContent: hasDraft ? draft.text(at: 0) : nil,
            hasClipboardTable: try connection.objectExists(
                type: "table",
                name: "clipboard_items"
            )
        )
    }
}
#endif
