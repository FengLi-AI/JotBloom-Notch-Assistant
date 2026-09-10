import Foundation

public struct ReleaseVersion: Equatable, Comparable, Sendable {
    public let components: [Int]
    public init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part.count == 1 || part.first != "0", let number = Int(part) else { return nil }
            numbers.append(number)
        }
        components = numbers
    }
    public var description: String { components.map(String.init).joined(separator: ".") }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

public struct AvailableRelease: Equatable, Sendable {
    public let version: ReleaseVersion
    public let pageURL: URL
}

public enum ReleaseCheckError: Error { case invalidResponse, unavailable, invalidCurrentVersion }

/// Explicit user action only. No credentials, user content, cookies or automatic installation.
public struct ReleaseChecker: Sendable {
    public static let releasesURL = URL(string: "https://github.com/FengLi-AI/JotBloom-Notch-Assistant/releases")!
    public static let endpoint = URL(string: "https://api.github.com/repos/FengLi-AI/JotBloom-Notch-Assistant/releases?per_page=100")!
    public init() {}

    public func check() async throws -> AvailableRelease? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("JotBloom-Update-Check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw ReleaseCheckError.invalidResponse }
        return try Self.latest(in: data, statusCode: response.statusCode)
    }

    public static func latest(in data: Data, statusCode: Int) throws -> AvailableRelease? {
        guard statusCode == 200 else { throw ReleaseCheckError.unavailable }
        struct Asset: Decodable { let name: String; let state: String; let size: Int }
        struct Release: Decodable {
            let tag_name: String; let draft: Bool; let prerelease: Bool; let assets: [Asset]
        }
        guard data.count <= 5_000_000 else { throw ReleaseCheckError.invalidResponse }
        let releases = try JSONDecoder().decode([Release].self, from: data)
        return releases.compactMap { release -> AvailableRelease? in
            guard !release.draft, !release.prerelease, let version = ReleaseVersion(release.tag_name),
                  release.assets.contains(where: {
                      $0.name == "JotBloom-\(version.description)-universal.dmg" && $0.state == "uploaded" && $0.size > 0
                  }) else { return nil }
            return AvailableRelease(version: version, pageURL: Self.releasesURL.appendingPathComponent("tag").appendingPathComponent(release.tag_name))
        }.max { $0.version < $1.version }
    }
}
