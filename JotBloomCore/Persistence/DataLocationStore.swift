import CryptoKit
import Darwin
import Foundation

public struct DataLocationRecord: Codable, Equatable, Sendable {
    public var version = 1
    public var activePath: String
    public var previousPath: String?
    public var identity: String
}

public enum MigrationPhase: String, Codable, Sendable {
    case copying, validating, ready, committed
}
public struct MigrationJournal: Codable, Sendable {
    public let version: Int
    public let transactionID: String
    public let source: String
    public let target: String
    public let staging: String
    public var phase: MigrationPhase
}

/// Location commit is independent of the database and remains on the internal control volume.
public struct DataLocationStore: Sendable {
    public let controlDirectory: URL
    private var recordURL: URL { controlDirectory.appendingPathComponent("data-location-v1.json") }
    private var journalURL: URL { controlDirectory.appendingPathComponent("data-migration-v1.json") }
    public init(controlDirectory: URL) { self.controlDirectory = controlDirectory }
    public func record() throws -> DataLocationRecord? {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        try Self.requireRegularFile(recordURL)
        guard let record = try? JSONDecoder().decode(DataLocationRecord.self, from: Data(contentsOf: recordURL)),
              record.version == 1, record.activePath.hasPrefix("/"), UUID(uuidString: record.identity) != nil else { throw SettingsError.unavailableDirectory }
        return record
    }
    public func activeDirectory() throws -> URL {
        guard let record = try record() else { return controlDirectory }
        let url = URL(fileURLWithPath: record.activePath, isDirectory: true)
        try validateIdentity(at: url, expected: record.identity)
        return url
    }
    public func relocate(to url: URL) throws {
        guard var record = try record() else { throw SettingsError.unavailableDirectory }
        try validateIdentity(at: url, expected: record.identity)
        record.activePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        try commit(record)
    }
    public func commit(_ record: DataLocationRecord) throws {
        try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: recordURL.path) { try Self.requireRegularFile(recordURL) }
        try Self.durableWrite(try JSONEncoder().encode(record), to: recordURL)
    }
    public func migrationJournal() throws -> MigrationJournal? {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        try Self.requireRegularFile(journalURL)
        let journal = try JSONDecoder().decode(MigrationJournal.self, from: Data(contentsOf: journalURL))
        guard journal.version == 1, UUID(uuidString: journal.transactionID) != nil else { throw SettingsError.migrationFailed }
        return journal
    }
    func writeJournal(_ journal: MigrationJournal) throws {
        try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: journalURL.path) { try Self.requireRegularFile(journalURL) }
        try Self.durableWrite(try JSONEncoder().encode(journal), to: journalURL)
    }
    func validateIdentity(at url: URL, expected: String) throws {
        let identity = url.appendingPathComponent("data-identity")
        let database = url.appendingPathComponent(DataDirectoryResolver.databaseFileName)
        try Self.requireRegularFile(identity); try Self.requireRegularFile(database)
        guard try String(contentsOf: identity, encoding: .utf8) == expected else { throw SettingsError.unavailableDirectory }
        let connection = try SQLiteConnection(databaseURL: database, readOnly: true)
        defer { connection.close() }
        guard try connection.userVersion() == DatabaseMigrator.currentVersion else { throw SettingsError.unavailableDirectory }
        let check = try connection.prepare("PRAGMA quick_check", operation: "validate_location")
        guard try check.stepRow(), check.text(at: 0) == "ok" else { throw SettingsError.unavailableDirectory }
    }
    static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SettingsError.unavailableDirectory }
    }
    static func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try syncFile(url)
        try syncDirectory(url.deletingLastPathComponent())
    }
    static func syncFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw SettingsError.migrationFailed }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw SettingsError.migrationFailed }
    }
}

public extension JotBloomStore {
    func createConsistentBackup(at database: URL) throws {
        try performSync { try $0.backup(to: database) }
    }
    func migrationRecordCounts() throws -> [Int64] {
        try performSync { connection in
            try ["inspirations", "clipboard_items", "drafts", "prompts", "chat_sessions", "chat_messages"].map { table in
                let statement = try connection.prepare("SELECT COUNT(*) FROM \(table)", operation: "migration_count")
                guard try statement.stepRow() else { throw SettingsError.migrationFailed }
                return statement.int64(at: 0)
            }
        }
    }
}

/// First launch selects a directory before any business store or capture service exists.
public struct InitialDataDirectorySetup {
    public init() {}

    public func needsSelection(location: DataLocationStore, previouslyUsed: Bool = false) throws -> Bool {
        if try location.record() != nil {
            _ = try location.activeDirectory() // Missing external disk is recovery, never a new install.
            return false
        }
        let fm = FileManager.default
        let control = location.controlDirectory
        guard fm.fileExists(atPath: control.path) else {
            if previouslyUsed { throw SettingsError.unavailableDirectory }
            return true
        }
        let names = try fm.contentsOfDirectory(atPath: control.path)
        if names.contains(DataDirectoryResolver.databaseFileName) {
            try DataLocationStore.requireRegularFile(control.appendingPathComponent(DataDirectoryResolver.databaseFileName))
            return false // Even an empty legacy database must be retained.
        }
        if previouslyUsed || names.contains(where: {
            $0.hasPrefix("jotbloom.sqlite") || $0 == "data-identity" || $0.hasPrefix("data-migration") || $0 == "data-location-v1.json"
        }) { throw SettingsError.unavailableDirectory }
        return true
    }

    @discardableResult
    public func create(in parent: URL, location: DataLocationStore,
                       beforeCommit: () throws -> Void = {}) throws -> URL {
        guard try needsSelection(location: location) else { throw SettingsError.invalidDirectory }
        let fm = FileManager.default
        guard parent.isFileURL else { throw SettingsError.invalidDirectory }
        let parent = parent.standardizedFileURL.resolvingSymlinksInPath()
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey])
        guard values.isDirectory == true, values.volumeIsLocal == true,
              fm.isWritableFile(atPath: parent.path) else { throw SettingsError.invalidDirectory }
        let target = parent.appendingPathComponent("JotBloom", isDirectory: true)
        // Directory listing also detects dangling symlinks; never adopt an existing name.
        guard !(try fm.contentsOfDirectory(atPath: parent.path)).contains("JotBloom"),
              target != location.controlDirectory.standardizedFileURL.resolvingSymlinksInPath() else {
            throw SettingsError.invalidDirectory
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let store = try JotBloomStore(dataDirectoryURL: target)
            store.close()
            let identity = UUID().uuidString
            try DataLocationStore.durableWrite(Data(identity.utf8), to: target.appendingPathComponent("data-identity"))
            try DataLocationStore.syncFile(target.appendingPathComponent(DataDirectoryResolver.databaseFileName))
            try DataLocationStore.syncDirectory(target)
            try DataLocationStore.syncDirectory(parent)
            try location.validateIdentity(at: target, expected: identity)
            try beforeCommit()
            try location.commit(DataLocationRecord(activePath: target.path, previousPath: nil, identity: identity))
            return target
        } catch {
            // Atomic replacement can succeed before fsync fails. Keep the committed directory.
            if (try? location.record()?.activePath) == target.path { return target }
            // No services have started and this invocation exclusively created the directory.
            try? fm.removeItem(at: target)
            throw error
        }
    }
}

public struct DataDirectoryMigration: Sendable {
    private let checkpoint: @Sendable (MigrationPhase) throws -> Void
    public init(checkpoint: @escaping @Sendable (MigrationPhase) throws -> Void = { _ in }) { self.checkpoint = checkpoint }
    /// Caller holds the application write barrier, including external assets, until this returns.
    public func migrate(store: JotBloomStore, parent: URL, location: DataLocationStore,
                        progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default
        let source = store.dataDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let parent = parent.resolvingSymlinksInPath().standardizedFileURL
        let target = parent.appendingPathComponent("JotBloom", isDirectory: true)
        if source.path == target.path { return source }
        guard target.path != source.path, !target.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(target.path + "/"),
              !fm.fileExists(atPath: target.path), fm.isWritableFile(atPath: parent.path),
              try parent.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else { throw SettingsError.invalidDirectory }
        let assets = try ClipboardAssetStore(dataDirectoryURL: source)
        let names = try store.referencedClipboardAssetFileNamesSynchronously().sorted()
        let backups = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.hasPrefix("jotbloom.sqlite.bak-v") && !$0.lastPathComponent.hasSuffix("-wal") && !$0.lastPathComponent.hasSuffix("-shm")
        }
        var required: Int64 = 16_000_000 // Filesystem/WAL and journal headroom, never a guarantee against later disk-full.
        let files = try names.map { name -> URL in
            guard let url = assets.readableURL(fileName: name) else { throw SettingsError.migrationFailed }
            return url
        } + backups + [store.databaseURL, URL(fileURLWithPath: store.databaseURL.path + "-wal")].filter { fm.fileExists(atPath: $0.path) }
        for file in files {
            try DataLocationStore.requireRegularFile(file)
            let size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            let (sum, overflow) = required.addingReportingOverflow(size)
            guard !overflow else { throw SettingsError.invalidDirectory }; required = sum
        }
        let available = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let available, available < required { throw SettingsError.invalidDirectory }
        let idURL = source.appendingPathComponent("data-identity")
        let identity: String
        if fm.fileExists(atPath: idURL.path) {
            try DataLocationStore.requireRegularFile(idURL)
            identity = try String(contentsOf: idURL, encoding: .utf8)
            guard UUID(uuidString: identity) != nil else { throw SettingsError.unavailableDirectory }
        } else {
            identity = UUID().uuidString
            try DataLocationStore.durableWrite(Data(identity.utf8), to: idURL)
        }
        // A new location gets a new identity. The retained source is a stale snapshot,
        // not a valid relocation candidate after commit.
        let destinationIdentity = UUID().uuidString
        let transactionID = UUID().uuidString
        let staging = parent.appendingPathComponent(".jotbloom-migration-" + transactionID, isDirectory: true)
        var journal = MigrationJournal(version: 1, transactionID: transactionID, source: source.path, target: target.path, staging: staging.path, phase: .copying)
        try location.writeJournal(journal)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var renamed = false
        do {
            try Task.checkCancellation()
            try checkpoint(.copying)
            progress("正在创建一致的数据快照…")
            let database = staging.appendingPathComponent(DataDirectoryResolver.databaseFileName)
            try store.createConsistentBackup(at: database)
            try DataLocationStore.syncFile(database)
            try DataLocationStore.durableWrite(Data(destinationIdentity.utf8), to: staging.appendingPathComponent("data-identity"))
            let targetAssets = staging.appendingPathComponent(DataDirectoryResolver.clipboardDirectoryName)
            try fm.createDirectory(at: targetAssets, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for (index, name) in names.enumerated() {
                try Task.checkCancellation()
                guard let original = assets.readableURL(fileName: name) else { throw SettingsError.migrationFailed }
                let copy = targetAssets.appendingPathComponent(name)
                try verifiedCopy(from: original, to: copy)
                progress("正在校验图片 \(index + 1) / \(names.count)…")
            }
            for backup in backups {
                try verifiedCopy(from: backup, to: staging.appendingPathComponent(backup.lastPathComponent))
            }
            journal.phase = .validating; try location.writeJournal(journal); try checkpoint(.validating)
            let validation = try JotBloomStore(dataDirectoryURL: staging)
            defer { validation.close() }
            guard try validation.schemaVersionSynchronously() == store.schemaVersionSynchronously(),
                  try validation.referencedClipboardAssetFileNamesSynchronously() == Set(names),
                  try validation.migrationRecordCounts() == store.migrationRecordCounts(),
                  try validation.listClipboardItemsSynchronously() == store.listClipboardItemsSynchronously(),
                  try validation.loadDraftSynchronously(kind: .inspiration) == store.loadDraftSynchronously(kind: .inspiration) else { throw SettingsError.migrationFailed }
            validation.close()
            try DataLocationStore.syncDirectory(targetAssets)
            try DataLocationStore.syncDirectory(staging)
            try Task.checkCancellation()
            try fm.moveItem(at: staging, to: target)
            renamed = true
            try DataLocationStore.syncDirectory(parent)
            journal.phase = .ready; try location.writeJournal(journal); try checkpoint(.ready)
            try location.validateIdentity(at: target, expected: destinationIdentity)
            try Task.checkCancellation()
            progress("正在切换保存位置…")
            try location.commit(DataLocationRecord(activePath: target.path, previousPath: source.path, identity: destinationIdentity))
            journal.phase = .committed; try location.writeJournal(journal); try checkpoint(.committed)
            return target
        } catch {
            // A durability error can occur after the atomic locator replacement. Never resume the old writer then.
            if renamed, (try? location.record()?.activePath) == target.path { return target }
            // Only remove our private staging directory. Never remove source or an already renamed target.
            if !renamed { try? fm.removeItem(at: staging) }
            throw error
        }
    }
    private func verifiedCopy(from source: URL, to target: URL) throws {
        try DataLocationStore.requireRegularFile(source)
        try FileManager.default.copyItem(at: source, to: target)
        guard try digest(source) == digest(target) else { throw SettingsError.migrationFailed }
        try DataLocationStore.syncFile(target)
    }
    private func digest(_ url: URL) throws -> SHA256.Digest {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let block = try file.read(upToCount: 65_536), !block.isEmpty {
            try Task.checkCancellation(); hash.update(data: block)
        }
        return hash.finalize()
    }
}
