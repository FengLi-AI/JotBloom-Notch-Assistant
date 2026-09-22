import Foundation
import Darwin
import UniformTypeIdentifiers

public enum ShelfFileKind: String, Codable, CaseIterable, Sendable {
    case image, document, video, audio, archive, folder, other
    public var title: String {
        switch self { case .image: return "图片"; case .document: return "文档"; case .video: return "视频"
        case .audio: return "音频"; case .archive: return "压缩包"; case .folder: return "文件夹"; case .other: return "其他" }
    }
    public var symbol: String {
        switch self { case .image: return "photo"; case .document: return "doc.text"; case .video: return "film"
        case .audio: return "waveform"; case .archive: return "archivebox"; case .folder: return "folder"; case .other: return "doc" }
    }
    public static func classify(_ url: URL, directory: Bool) -> Self {
        if directory { return .folder }
        let ext = url.pathExtension.lowercased()
        if ["zip", "rar", "7z", "gz", "bz2", "tar", "xz", "tgz"].contains(ext) { return .archive }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .spreadsheet) || type.conforms(to: .presentation)
            || ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf"].contains(ext) { return .document }
        return .other
    }
}

public enum FileReferenceError: Error, LocalizedError, Equatable {
    case unavailable, permission, notDownloaded, unsupported, replaced
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "找不到原文件，或原位置暂不可用"
        case .permission: return "无法访问原文件，请重新选择"
        case .notDownloaded: return "请先在原位置将文件下载到本机"
        case .unsupported: return "请先将文件保存到本机后再拖入"
        case .replaced: return "原文件已被替换，请重新选择"
        }
    }
}

/// Contains metadata and a locating bookmark only. Never reads or exports file contents.
public struct FileReference: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var url: URL
    public var bookmark: Data
    public var identity: String
    public var kind: ShelfFileKind
    public var addedAt: Date
    public var name: String { url.lastPathComponent }

    public static func create(url: URL, now: Date = Date()) throws -> Self {
        guard url.isFileURL else { throw FileReferenceError.unsupported }
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let info = try inspect(url)
        return Self(id: UUID(), url: url, bookmark: try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil),
                    identity: info.identity, kind: .classify(url, directory: info.directory), addedAt: now)
    }

    public func resolved() throws -> Self {
        // The usual case needs only a metadata check. Resolve the bookmark only after
        // the path changes, avoiding a bookmark lookup during every drag gesture.
        if let info = try? Self.inspect(url), info.identity == identity {
            var value = self
            value.kind = .classify(url, directory: info.directory)
            return value
        }
        var stale = false
        let candidate = (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)) ?? url
        let info = try Self.inspect(candidate)
        guard info.identity == identity else { throw FileReferenceError.replaced }
        var value = self
        value.url = candidate
        value.kind = .classify(candidate, directory: info.directory)
        if stale || candidate != url {
            value.bookmark = try candidate.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        return value
    }

    private static func inspect(_ url: URL) throws -> (identity: String, directory: Bool) {
        var metadata = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        guard status == 0 else { throw FileReferenceError.unavailable }
        // File Provider placeholders are not all iCloud ubiquitous items.
        // Check metadata before any bookmark or thumbnail request can hydrate them.
        guard metadata.st_flags & UInt32(SF_DATALESS) == 0 else { throw FileReferenceError.notDownloaded }
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .volumeUUIDStringKey]) }
        catch { throw FileReferenceError.unavailable }
        if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current && values.ubiquitousItemDownloadingStatus != .downloaded {
            throw FileReferenceError.notDownloaded
        }
        guard values.isDirectory == true || values.isRegularFile == true else { throw FileReferenceError.unsupported }
        guard values.isReadable != false, FileManager.default.isReadableFile(atPath: url.path) else { throw FileReferenceError.permission }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let volume = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else { throw FileReferenceError.unavailable }
        // Volume UUID remains stable when an external disk is remounted.
        let volumeIdentity = values.volumeUUIDString ?? "device-\(volume)"
        // Birth time also distinguishes a later file if the filesystem reuses an inode.
        let birth = metadata.st_birthtimespec
        return ("\(volumeIdentity):\(inode):\(birth.tv_sec):\(birth.tv_nsec)", values.isDirectory == true)
    }
}

public enum FileShelfOrder {
    /// Permutes visible slots only; hidden items keep both their slots and relative order.
    public static func moving(_ ids: Set<UUID>, before target: UUID?, items: [FileReference], visible: [FileReference]) -> [FileReference] {
        let moving = visible.filter { ids.contains($0.id) }
        guard !moving.isEmpty, target.map({ !ids.contains($0) }) ?? true else { return items }
        var ordered = visible.filter { !ids.contains($0.id) }
        let index = target.flatMap { t in ordered.firstIndex { $0.id == t } } ?? ordered.count
        ordered.insert(contentsOf: moving, at: index)
        let visibleIDs = Set(visible.map(\.id))
        var iterator = ordered.makeIterator()
        return items.map { visibleIDs.contains($0.id) ? iterator.next()! : $0 }
    }
}
