import Foundation
import Darwin

/// Directory-relative descriptors keep a file operation anchored to its approved
/// directory. No shell, path arguments, symlink following, or deletion tools.
public struct AssistantResultFiles: Sendable {
    public let directory: String
    public let identity: String
    public init(directory: String, expectedIdentity: String? = nil, create: Bool = true) throws {
        guard directory.hasPrefix("/"), URL(fileURLWithPath: directory).standardizedFileURL.path != FileManager.default.homeDirectoryForCurrentUser.path,
              !["/", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private"].contains(URL(fileURLWithPath: directory).standardizedFileURL.path) else { throw ExecutionError.denied("请选择独立的任务结果文件夹。") }
        if create && expectedIdentity == nil { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        // Resolve the approved parent once; each subsequent operation verifies inode identity.
        self.directory = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL.path
        let fd = open(self.directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ExecutionError.unreadable("无法打开结果文件夹。") }; defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0 else { throw ExecutionError.changedDirectory }
        identity = "\(info.st_dev):\(info.st_ino)"
        if let expectedIdentity, identity != expectedIdentity { throw ExecutionError.changedDirectory }
    }
    public static func validateName(_ name: String, allTypes: Bool = false) throws {
        guard !name.isEmpty, name.utf8.count <= 240, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"), !name.contains(":"), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              allTypes || ["md", "txt", "csv"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else { throw ExecutionError.denied(allTypes ? "只支持结果目录中的普通文件名，不能包含路径、隐藏名或控制字符。" : "只支持结果目录中的 .md、.txt、.csv 文件名，不能包含路径、隐藏名或控制字符。") }
    }
    private func withDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ExecutionError.changedDirectory }; defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, "\(info.st_dev):\(info.st_ino)" == identity else { throw ExecutionError.changedDirectory }
        return try body(fd)
    }
    private func read(_ name: String, directoryFD: Int32, maximumBytes: Int = 1_048_576) throws -> Data {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ExecutionError.unreadable("文件不存在或是符号链接。") }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size <= maximumBytes else { throw ExecutionError.denied("文件必须是普通文件，不能是链接，且不能超过 \(maximumBytes / 1_048_576)MB。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ExecutionError.denied("文件超过大小限制。") }; return data
    }
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff", "bmp"]
    public static let textActionExtensions: Set<String> = ["md", "txt", "csv", "html", "json"]
    public static func supportsTextActions(_ name: String) -> Bool {
        (try? validateName(name, allTypes: true)) != nil && textActionExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }
    public func readImage(_ name: String) throws -> Data {
        try Self.validateName(name, allTypes: true)
        guard Self.imageExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else { throw ExecutionError.denied("此类型暂不支持图片预览。") }
        return try withDirectory { try read(name, directoryFD: $0, maximumBytes: 20 * 1_048_576) }
    }
    public func read(_ name: String, allTypes: Bool = false) throws -> String {
        try Self.validateName(name, allTypes: allTypes)
        return try withDirectory { fd in
            guard let text = String(data: try read(name, directoryFD: fd), encoding: .utf8), !text.contains("\0") else { throw ExecutionError.unreadable("结果文件不是 UTF-8 文本。") }; return text
        }
    }
    public func write(_ name: String, content: String, mode: String) throws {
        try Self.validateName(name)
        guard ["create", "overwrite", "append"].contains(mode) else { throw ExecutionError.invalid("写入方式不支持。") }
        try withDirectory { fd in
            var info = stat(); let exists = fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            if exists && (info.st_mode & S_IFMT != S_IFREG || info.st_nlink != 1) { throw ExecutionError.denied("不能覆盖链接或非普通文件。") }
            if mode == "create" && exists { throw ExecutionError.denied("文件已存在，请先读取后决定是否覆盖。") }
            var data = mode == "append" && exists ? try read(name, directoryFD: fd) : Data()
            data.append(Data(content.utf8)); guard data.count <= 1_048_576 else { throw ExecutionError.denied("单个结果文件不能超过 1MB，请拆成多个文件。") }
            let temporary = ".jotbloom-" + UUID().uuidString
            let output = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw ExecutionError.unreadable("结果文件夹不可写。") }
            defer { close(output); unlinkat(fd, temporary, 0) }
            let handle = FileHandle(fileDescriptor: output, closeOnDealloc: false)
            try handle.write(contentsOf: data); guard fsync(output) == 0 else { throw ExecutionError.unreadable("结果文件未能保存到磁盘。") }
            if mode == "create" {
                guard linkat(fd, temporary, fd, name, 0) == 0 else { throw ExecutionError.denied("文件已存在，未覆盖。") }
            } else { guard renameat(fd, temporary, fd, name) == 0 else { throw ExecutionError.unreadable("结果文件保存失败。") } }
            _ = fsync(fd)
        }
    }
    public func list(allTypes: Bool = false) throws -> [AssistantResultFile] {
        try withDirectory { fd in
            // Enumerate through the open directory, not a re-resolved path.
            guard let stream = fdopendir(dup(fd)) else { throw ExecutionError.unreadable("无法列出结果。") }; defer { closedir(stream) }
            var values: [AssistantResultFile] = []
            while let entry = readdir(stream), values.count < 200 {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { p in p.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) } }
                guard !name.hasPrefix("."), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), allTypes || (try? Self.validateName(name)) != nil else { continue }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { continue }
                values.append(.init(name: name, bytes: info.st_size, url: URL(fileURLWithPath: directory).appendingPathComponent(name)))
            }
            return values.sorted { $0.name < $1.name }
        }
    }
}
