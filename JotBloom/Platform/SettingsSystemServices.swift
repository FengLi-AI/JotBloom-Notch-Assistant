import AppKit
import JotBloomCore
import Security
import ServiceManagement

enum SMLoginSettings {
    @MainActor static func open() { SMAppService.openSystemSettingsLoginItems() }
}

actor KeychainCredentialStore: CredentialStoring {
    // File-based login keychains ignore the data-protection UI parameters.
    // All of this app's keychain operations share a lock; this scope has no await.
    private static let interactionLock = NSRecursiveLock()
    private let service: String
    private let scopedKeychain: SecKeychain?
    private struct Context {
        let keychain: SecKeychain
        let metadata: NSDictionary
    }
    private var session = AuthorizedCredentialSession<Context>()
    init(service: String = "com.jotbloom.mengsheng", scopedKeychain: SecKeychain? = nil) {
        self.service = service; self.scopedKeychain = scopedKeychain
    }
    private func query(_ slot: ModelSlot) -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: slot.account, kSecAttrSynchronizable as String: false]
        if let scopedKeychain { result[kSecMatchSearchList as String] = [scopedKeychain] }
        return result
    }
    func read(_ slot: ModelSlot) async throws -> String? { try readSilently(slot) }
    func authorize(_ slot: ModelSlot) async throws -> String? { try readWithAuthorization(slot) }

    private func readWithAuthorization(_ slot: ModelSlot) throws -> String? {
        Self.interactionLock.lock(); defer { Self.interactionLock.unlock() }
        // Explicit reads must revalidate authorization, not conceal a revoked key.
        session.remove(slot)
        var request = query(slot)
        request[kSecReturnData as String] = true
        request[kSecReturnRef as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var output: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &output)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let attributes = output as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data,
              let string = String(data: data, encoding: .utf8) else { throw SettingsError.credentialUnavailable }
        if let reference = attributes[kSecValueRef as String] {
            remember(string, slot: slot, reference: reference as CFTypeRef)
        }
        return string
    }
    func write(_ secret: String, slot: ModelSlot) throws {
        Self.interactionLock.lock(); defer { Self.interactionLock.unlock() }
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !secret.contains("\n"), !secret.contains("\r") else { throw SettingsError.missingKey }
        session.remove(slot)
        let request = query(slot)
        let attributes = [kSecValueData as String: Data(secret.utf8)]
        let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = request
            addition.removeValue(forKey: kSecMatchSearchList as String)
            if let scopedKeychain { addition[kSecUseKeychain as String] = scopedKeychain }
            addition[kSecValueData as String] = Data(secret.utf8)
            try check(SecItemAdd(addition as CFDictionary, nil))
        } else { try check(status) }
        // The write was authorized. Resolve metadata without reading secret data again.
        var referenceQuery = query(slot)
        referenceQuery[kSecReturnRef as String] = true
        referenceQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var reference: CFTypeRef?
        if SecItemCopyMatching(referenceQuery as CFDictionary, &reference) == errSecSuccess,
           let reference { remember(secret, slot: slot, reference: reference) }
    }
    func remove(_ slot: ModelSlot) throws {
        Self.interactionLock.lock(); defer { Self.interactionLock.unlock() }
        session.remove(slot)
        let status = SecItemDelete(query(slot) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func remember(_ secret: String, slot: ModelSlot, reference: CFTypeRef) {
        guard CFGetTypeID(reference) == SecKeychainItemGetTypeID() else { return }
        var keychain: SecKeychain?
        let item = reference as! SecKeychainItem
        guard SecKeychainItemCopyKeychain(item, &keychain) == errSecSuccess,
              let keychain else { return }
        // Capture the post-authorization ACL, including an "Always Allow" change.
        // If metadata cannot be verified, do not create a reusable cache entry.
        guard let metadata = try? withoutInteraction({ try metadataSnapshot(slot) }) else { return }
        session.remember(secret, slot: slot, context: Context(keychain: keychain, metadata: metadata))
    }
    private func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        if status == errSecUserCanceled { throw SettingsError.credentialCancelled }
        if status == errSecInteractionNotAllowed { throw SettingsError.credentialLocked }
        if status == errSecAuthFailed { throw SettingsError.credentialDenied }
        throw SettingsError.credentialUnavailable
    }

    // Match the async protocol requirement explicitly: a synchronous overload can
    // otherwise lose overload resolution to its async default implementation.
    func readWithoutInteraction(_ slot: ModelSlot) async throws -> String? {
        try readSilently(slot)
    }

    private func readSilently(_ slot: ModelSlot) throws -> String? {
        Self.interactionLock.lock(); defer { Self.interactionLock.unlock() }
        return try withoutInteraction {
        // A previous explicit authorization can be reused without a second ACL prompt.
        // Validate the actual containing keychain, not an unrelated default keychain.
        if let cached = try session.read(slot, validate: { context in
            var status: SecKeychainStatus = 0
            let result = SecKeychainGetStatus(context.keychain, &status)
            guard result == errSecSuccess else {
                throw SettingsError.credentialUnavailable
            }
            guard status & UInt32(kSecUnlockStateStatus) != 0 else {
                throw SettingsError.credentialLocked
            }
            guard try metadataSnapshot(slot).isEqual(context.metadata) else {
                throw SettingsError.credentialDenied
            }
        }) { return cached }
        return try readWithAuthorization(slot)
        }
    }

    private func withoutInteraction<T>(_ operation: () throws -> T) throws -> T {
        var previous: DarwinBoolean = false
        try check(SecKeychainGetUserInteractionAllowed(&previous))
        try check(SecKeychainSetUserInteractionAllowed(false))
        let result: Result<T, Error>
        do { result = .success(try operation()) } catch { result = .failure(error) }
        // Restore on both success and failure before returning any credential.
        try check(SecKeychainSetUserInteractionAllowed(previous.boolValue))
        return try result.get()
    }

    /// Reads no password data. Identity, modification and every ACL entry must match.
    /// Called only with system interaction disabled and the process-wide lock held.
    private func metadataSnapshot(_ slot: ModelSlot) throws -> NSDictionary {
        var request = query(slot)
        request[kSecReturnAttributes as String] = true
        request[kSecReturnPersistentRef as String] = true
        request[kSecReturnRef as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var output: CFTypeRef?
        try check(SecItemCopyMatching(request as CFDictionary, &output))
        guard let attributes = output as? [String: Any],
              let identity = attributes[kSecValuePersistentRef as String] as? Data,
              let modified = attributes[kSecAttrModificationDate as String] as? Date,
              let reference = attributes[kSecValueRef as String],
              CFGetTypeID(reference as CFTypeRef) == SecKeychainItemGetTypeID() else { throw SettingsError.credentialUnavailable }
        let item = reference as! SecKeychainItem
        var access: SecAccess?
        try check(SecKeychainItemCopyAccess(item, &access))
        guard let access else { throw SettingsError.credentialUnavailable }
        var list: CFArray?
        try check(SecAccessCopyACLList(access, &list))
        guard let entries = list as? [SecACL] else { throw SettingsError.credentialUnavailable }
        var snapshots: [[String: Any]] = []
        for acl in entries {
            var apps: CFArray?, label: CFString?
            var selector = SecKeychainPromptSelector()
            try check(SecACLCopyContents(acl, &apps, &label, &selector))
            var applications: [Data] = []
            if let apps {
                guard let trusted = apps as? [SecTrustedApplication] else { throw SettingsError.credentialUnavailable }
                for app in trusted {
                    var data: CFData?
                    try check(SecTrustedApplicationCopyData(app, &data))
                    guard let data else { throw SettingsError.credentialUnavailable }
                    applications.append(data as Data)
                }
            }
            snapshots.append(["allApps": apps == nil, "apps": applications, "label": label as String? ?? "",
                              "promptFlags": selector.rawValue,
                              "authorizations": SecACLCopyAuthorizations(acl) as NSArray])
        }
        return ["identity": identity, "modified": modified, "acl": snapshots] as NSDictionary
    }
}

@MainActor
protocol LoginItemServicing {
    var statusText: String { get }
    var enabled: Bool { get }
    func setEnabled(_ enabled: Bool) async throws
}

@MainActor
final class LoginItemService: LoginItemServicing {
    var enabled: Bool { SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval }
    var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已启用"
        case .notRegistered: return "已关闭"
        case .requiresApproval: return "等待系统批准，请在系统设置的登录项中允许"
        case .notFound: return "登录项不可用，请检查应用安装位置"
        @unknown default: return "系统状态未知"
        }
    }
    func setEnabled(_ enabled: Bool) async throws {
        if enabled {
            let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
            guard !path.hasPrefix("/private/tmp/"), !path.hasPrefix("/var/folders/"), !path.hasPrefix("/private/var/folders/") else {
                throw LoginItemError.temporaryApplication
            }
            try SMAppService.mainApp.register()
        } else { try await SMAppService.mainApp.unregister() }
    }
    enum LoginItemError: Error, LocalizedError {
        case temporaryApplication
        var errorDescription: String? { "请先将此版本放到稳定的应用目录，再开启登录项；临时构建目录会被系统清理。" }
    }
}

@MainActor
final class IsolatedLoginItemService: LoginItemServicing {
    private(set) var enabled = false
    var statusText: String { "隔离测试：" + (enabled ? "已启用（未注册系统）" : "已关闭") }
    func setEnabled(_ enabled: Bool) async throws { self.enabled = enabled }
}
