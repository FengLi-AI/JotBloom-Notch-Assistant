import Foundation

public struct ClipboardAssetNames: Equatable, Sendable {
    public let imageFileName: String
    public let thumbnailFileName: String

    public init(imageFileName: String, thumbnailFileName: String) {
        self.imageFileName = imageFileName
        self.thumbnailFileName = thumbnailFileName
    }
}

public final class ClipboardAssetStore: @unchecked Sendable {
    public let directoryURL: URL

    private let fileManager: FileManager

    public init(
        dataDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        directoryURL = dataDirectoryURL
            .appendingPathComponent(
                DataDirectoryResolver.clipboardDirectoryName,
                isDirectory: true
            )
            .standardizedFileURL
        try Self.ensurePrivateDirectory(
            at: directoryURL,
            fileManager: fileManager
        )
    }

    public func writeNewImage(
        pngData: Data,
        thumbnailPNGData: Data,
        identifier: UUID = UUID()
    ) throws -> ClipboardAssetNames {
        let baseName = identifier.uuidString.uppercased()
        let names = ClipboardAssetNames(
            imageFileName: "\(baseName).png",
            thumbnailFileName: "\(baseName)-thumb.png"
        )
        try writeImage(
            pngData: pngData,
            thumbnailPNGData: thumbnailPNGData,
            names: names
        )
        return names
    }

    public func writeImage(
        pngData: Data,
        thumbnailPNGData: Data,
        names: ClipboardAssetNames
    ) throws {
        let imageURL = try safeURL(for: names.imageFileName)
        let thumbnailURL = try safeURL(for: names.thumbnailFileName)
        let imageExisted = fileManager.fileExists(atPath: imageURL.path)
        let thumbnailExisted = fileManager.fileExists(atPath: thumbnailURL.path)

        do {
            try rejectSymbolicLinkIfPresent(at: imageURL)
            try pngData.write(to: imageURL, options: .atomic)
            try setPrivateFilePermissions(at: imageURL)

            try rejectSymbolicLinkIfPresent(at: thumbnailURL)
            try thumbnailPNGData.write(to: thumbnailURL, options: .atomic)
            try setPrivateFilePermissions(at: thumbnailURL)
        } catch {
            if !imageExisted {
                try? fileManager.removeItem(at: imageURL)
            }
            if !thumbnailExisted {
                try? fileManager.removeItem(at: thumbnailURL)
            }
            if let error = error as? PersistenceError {
                throw error
            }
            throw PersistenceError.clipboardAssetOperationFailed(
                operation: "write_image"
            )
        }
    }

    public func readData(fileName: String) throws -> Data {
        let url = try safeURL(for: fileName)
        do {
            try rejectSymbolicLinkIfPresent(at: url)
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.clipboardAssetOperationFailed(
                operation: "read_asset"
            )
        }
    }

    public func writeThumbnailPNGData(
        _ data: Data,
        fileName: String
    ) throws {
        let url = try safeURL(for: fileName)
        do {
            try rejectSymbolicLinkIfPresent(at: url)
            try data.write(to: url, options: .atomic)
            try setPrivateFilePermissions(at: url)
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.clipboardAssetOperationFailed(
                operation: "write_thumbnail"
            )
        }
    }

    public func readableURL(fileName: String) -> URL? {
        guard let url = try? safeURL(for: fileName),
              fileManager.fileExists(atPath: url.path),
              (try? isSymbolicLink(at: url)) == false else {
            return nil
        }
        return url
    }

    public func filesExist(names: ClipboardAssetNames) -> Bool {
        readableURL(fileName: names.imageFileName) != nil
            && readableURL(fileName: names.thumbnailFileName) != nil
    }

    public func delete(names: ClipboardAssetNames) throws {
        var firstError: Error?
        for fileName in [names.imageFileName, names.thumbnailFileName] {
            do {
                let url = try safeURL(for: fileName)
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if let firstError {
            if let error = firstError as? PersistenceError {
                throw error
            }
            throw PersistenceError.clipboardAssetOperationFailed(
                operation: "delete_asset"
            )
        }
    }

    @discardableResult
    public func reconcile(referencedFileNames: Set<String>) throws -> Int {
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw PersistenceError.clipboardAssetOperationFailed(
                operation: "enumerate_assets"
            )
        }

        var removedCount = 0
        for url in urls {
            let fileName = url.lastPathComponent
            guard Self.isManagedFileName(fileName),
                  !referencedFileNames.contains(fileName) else {
                continue
            }
            do {
                try fileManager.removeItem(at: url)
                removedCount += 1
            } catch {
                throw PersistenceError.clipboardAssetOperationFailed(
                    operation: "remove_orphan"
                )
            }
        }
        return removedCount
    }

    public static func isManagedFileName(_ fileName: String) -> Bool {
        let stem: String
        if fileName.hasSuffix("-thumb.png") {
            stem = String(fileName.dropLast("-thumb.png".count))
        } else if fileName.hasSuffix(".png") {
            stem = String(fileName.dropLast(".png".count))
        } else {
            return false
        }
        return UUID(uuidString: stem) != nil
    }

    private func safeURL(for fileName: String) throws -> URL {
        guard Self.isManagedFileName(fileName),
              fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              !fileName.contains("/"),
              !fileName.contains("\\"),
              !fileName.contains("..") else {
            throw PersistenceError.invalidClipboardAssetName(name: fileName)
        }
        return directoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    private func rejectSymbolicLinkIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        if try isSymbolicLink(at: url) {
            throw PersistenceError.invalidClipboardAssetName(
                name: url.lastPathComponent
            )
        }
    }

    private func isSymbolicLink(at url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    }

    private func setPrivateFilePermissions(at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func ensurePrivateDirectory(
        at url: URL,
        fileManager: FileManager
    ) throws {
        do {
            if fileManager.fileExists(atPath: url.path),
               try url.resourceValues(
                   forKeys: [.isSymbolicLinkKey]
               ).isSymbolicLink == true {
                throw PersistenceError.clipboardDirectoryUnavailable(
                    path: url.path
                )
            }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else {
                    throw PersistenceError.clipboardDirectoryUnavailable(
                        path: url.path
                    )
                }
            } else {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.clipboardDirectoryUnavailable(path: url.path)
        }
    }
}
