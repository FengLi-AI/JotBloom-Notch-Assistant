import Foundation
import Darwin

public enum UserProvidedURLs {
    public static func extract(_ text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen: Set<String> = []
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text), let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            let exact = String(text[range]); return seen.insert(exact).inserted ? exact : nil
        }
    }
}
public enum SafeWebAddress {
    public static func validate(_ text: String) throws -> URL {
        guard text.utf8.count <= 4096, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, let host = url.host, !host.isEmpty,
              !host.lowercased().hasSuffix(".local"), !host.lowercased().hasSuffix(".localhost"), host.lowercased() != "localhost" else { throw ExecutionError.denied("只支持没有登录信息的公网 HTTP 或 HTTPS 地址。") }
        return url
    }
    public static func isPublicIP(_ text: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            let n = UInt32(bigEndian: v4.s_addr), a = n >> 24, b = (n >> 16) & 255, c = (n >> 8) & 255
            if [0, 10, 127].contains(a) || a >= 224 { return false }
            if a == 100 && (64...127).contains(b) || a == 169 && b == 254 || a == 172 && (16...31).contains(b) || a == 192 && b == 168 { return false }
            if a == 192 && (b == 0 || b == 2 || (b == 88 && c == 99)) || a == 198 && (b == 18 || b == 19 || b == 51 && c == 100) || a == 203 && b == 0 && c == 113 { return false }
            return true
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, text, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255 { return isPublicIP(bytes.suffix(4).map(String.init).joined(separator: ".")) }
        guard bytes[0] & 0xE0 == 0x20 else { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return false } // 6to4 can embed a private IPv4 destination.
        if bytes[0] == 0x20 && bytes[1] == 0x01 && ((bytes[2] == 0 && bytes[3] == 0) || (bytes[2] == 0x0D && bytes[3] == 0xB8)) { return false }
        return true
    }
    public static func resolve(_ url: URL) throws -> [String] {
        let host = (url.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { throw ExecutionError.unreadable("网页地址无法解析。") }
        defer { freeaddrinfo(first) }
        var addresses: [String] = [], pointer: UnsafeMutablePointer<addrinfo>? = first
        while let current = pointer {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 { addresses.append(String(cString: buffer)) }
            pointer = current.pointee.ai_next
        }
        guard !addresses.isEmpty, addresses.allSatisfy(isPublicIP) else { throw ExecutionError.denied("网页被解析到本机、内网或保留地址，已停止读取。如果代理使用虚拟 IP，请让其 DNS 返回真实公网地址后再试。") }
        return addresses
    }
}

public struct WebPageResponse: Sendable {
    public let status: Int
    public let location: String?
    public let contentType: String
    public let data: Data
    public init(status: Int, location: String? = nil, contentType: String = "text/html", data: Data) {
        self.status = status; self.location = location; self.contentType = contentType; self.data = data
    }
}
public protocol AssistantWebTransport: Sendable { func fetch(_ url: URL, address: String, timeout: TimeInterval) async throws -> WebPageResponse }

/// macOS ships curl. A fixed executable and argument list are used solely for GET.
/// --resolve pins the checked IP while retaining hostname TLS verification/SNI;
/// no shell, user curl configuration, proxy, cookies, credentials or redirects.
public struct PinnedWebTransport: AssistantWebTransport {
    public init() {}
    public func fetch(_ url: URL, address: String, timeout: TimeInterval) async throws -> WebPageResponse {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jotbloom-web-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let body = root.appendingPathComponent("body"), headers = root.appendingPathComponent("headers")
        let host = (url.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let resolvedHost = host.contains(":") ? "[\(host)]" : host
        let ip = address.contains(":") ? "[\(address)]" : address
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.arguments = ["--disable", "--globoff", "--path-as-is", "--silent", "--show-error", "--proxy", "", "--noproxy", "*", "--proto", "=http,https", "--request", "GET", "--max-time", String(max(1, timeout)), "--connect-timeout", "8", "--max-filesize", "2097152", "--resolve", "\(resolvedHost):\(port):\(ip)", "--dump-header", headers.path, "--output", body.path, "--url", url.absoluteString]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                try Task.checkCancellation()
                for (file, max) in [(body, 2_097_152), (headers, 65_536)] {
                    if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > max { throw ExecutionError.unreadable("网页响应过大。") }
                }
                guard Date() < deadline else { throw ExecutionError.unreadable("网页读取超过 15 秒。") }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit(); throw error
        }
        guard process.terminationStatus == 0 else { throw ExecutionError.unreadable("网页无法读取，可能超时、证书异常或超过 2MB。") }
        let data = try Data(contentsOf: body), headerData = try Data(contentsOf: headers)
        guard data.count <= 2_097_152, headerData.count <= 65_536 else { throw ExecutionError.unreadable("网页响应过大。") }
        let lines = String(decoding: headerData, as: UTF8.self).components(separatedBy: "\r\n")
        var status = 0, location: String?, contentType = ""
        for line in lines {
            if line.hasPrefix("HTTP/") { status = Int(line.split(separator: " ").dropFirst().first ?? "0") ?? 0; location = nil; contentType = "" }
            else if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if name == "location" { location = value }; if name == "content-type" { contentType = value.lowercased() }
            }
        }
        return .init(status: status, location: location, contentType: contentType, data: data)
    }
}
public struct AssistantWebReader: Sendable {
    private let transport: any AssistantWebTransport
    private let resolve: @Sendable (URL) throws -> [String]
    public init(transport: any AssistantWebTransport = PinnedWebTransport(), resolve: @escaping @Sendable (URL) throws -> [String] = { try SafeWebAddress.resolve($0) }) { self.transport = transport; self.resolve = resolve }
    public func read(_ exactURL: String, allowed: [String]) async throws -> String {
        guard allowed.contains(exactURL) else { throw ExecutionError.denied("地址不是用户给出的原链接。") }
        let deadline = Date().addingTimeInterval(15)
        var url = try SafeWebAddress.validate(exactURL)
        for hop in 0...3 {
            let resolver = resolve, resolvingURL = url
            let request = WebDNSRequest()
            let addresses = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    request.start(continuation)
                    DispatchQueue.global(qos: .utility).async { request.finish(Result { try resolver(resolvingURL) }) }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow)) { request.finish(.failure(ExecutionError.unreadable("网页地址解析超时。"))) }
                }
            }, onCancel: { request.finish(.failure(CancellationError())) })
            try Task.checkCancellation()
            guard let ip = addresses.first, addresses.allSatisfy(SafeWebAddress.isPublicIP) else { throw ExecutionError.denied("网页解析到了非公网地址。") }
            let remaining = deadline.timeIntervalSinceNow; guard remaining > 0 else { throw ExecutionError.unreadable("网页读取超时。") }
            let response = try await transport.fetch(url, address: ip, timeout: remaining)
            guard response.data.count <= 2_097_152 else { throw ExecutionError.unreadable("网页超过 2MB。") }
            if (300...399).contains(response.status), let location = response.location {
                guard hop < 3, let target = URL(string: location, relativeTo: url)?.absoluteURL else { throw ExecutionError.denied("网页跳转过多或无效。") }
                url = try SafeWebAddress.validate(target.absoluteString); continue
            }
            guard (200...299).contains(response.status) else { throw ExecutionError.unreadable("网页返回 HTTP \(response.status)，未取得正文。") }
            guard response.contentType.hasPrefix("text/") || response.contentType.hasPrefix("application/xhtml+xml") else { throw ExecutionError.unreadable("链接不是可读取的文字网页。") }
            var text = String(data: response.data, encoding: .utf8) ?? String(decoding: response.data, as: UTF8.self)
            if response.contentType.contains("html") {
                for pattern in ["(?is)<(script|style|noscript|svg|head)\\b[^>]*>.*?</\\1>", "(?s)<!--.*?-->", "(?s)<[^>]*>"] { text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression) }
                for (a, b) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] { text = text.replacingOccurrences(of: a, with: b) }
            }
            text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ExecutionError.unreadable("网页没有可提取的正文。") }
            return String(text.prefix(8001))
        }
        throw ExecutionError.unreadable("网页读取失败。")
    }
}

private final class WebDNSRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[String], Error>?
    private var continuation: CheckedContinuation<[String], Error>?
    func start(_ value: CheckedContinuation<[String], Error>) {
        lock.lock()
        if let result { lock.unlock(); value.resume(with: result) }
        else { continuation = value; lock.unlock() }
    }
    func finish(_ value: Result<[String], Error>) {
        lock.lock(); guard result == nil else { lock.unlock(); return }
        result = value; let waiting = continuation; continuation = nil; lock.unlock()
        waiting?.resume(with: value)
    }
}
