import Foundation

public enum DataDirectoryResolver {
    public static let bundleIdentifier = "com.jotbloom.mengsheng"
    public static let databaseFileName = "jotbloom.sqlite"
    public static let clipboardDirectoryName = "Clipboard"

    public static func productionDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw PersistenceError.dataDirectoryUnavailable(path: "Application Support")
        }

        return applicationSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .standardizedFileURL
    }

    public static func validatedDebugDirectory(
        path: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard path.hasPrefix("/") else {
            throw PersistenceError.invalidDebugDataDirectory(path: path)
        }

        let candidate = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let allowedRoots = [
            fileManager.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath(),
            URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
        ]

        guard allowedRoots.contains(where: { isStrictDescendant(candidate, of: $0) }) else {
            throw PersistenceError.invalidDebugDataDirectory(path: candidate.path)
        }

        let production = try productionDirectory(fileManager: fileManager)
            .resolvingSymlinksInPath()
        guard candidate != production else {
            throw PersistenceError.invalidDebugDataDirectory(path: candidate.path)
        }

        return candidate
    }

    public static func makeEphemeralDirectory(
        prefix: String,
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path.hasPrefix(rootPath)
    }
}
