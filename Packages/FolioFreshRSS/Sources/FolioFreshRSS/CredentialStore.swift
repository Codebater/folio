import Foundation

/// Saved connection to one FreshRSS account. The server address and username
/// are not secret and live in app preferences; the API password lives only in
/// the credential store (the iOS Keychain in the app).
public struct AccountConfiguration: Hashable, Sendable, Codable {
    public var endpoint: ServerEndpoint
    public var username: String

    public init(endpoint: ServerEndpoint, username: String) {
        self.endpoint = endpoint
        self.username = username
    }

    /// Keychain account key: one entry per server + user.
    public var credentialKey: String { "\(username)@\(endpoint.apiBase.absoluteString)" }
}

public protocol CredentialStore: Sendable {
    func password(for key: String) throws -> String?
    func setPassword(_ password: String, for key: String) throws
    func removePassword(for key: String) throws
}

/// For tests, previews and the demo account.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func password(for key: String) throws -> String? { lock.withLock { storage[key] } }
    public func setPassword(_ password: String, for key: String) throws { lock.withLock { storage[key] = password } }
    public func removePassword(for key: String) throws { lock.withLock { _ = storage.removeValue(forKey: key) } }
}

#if canImport(Security)
import Security

public struct KeychainError: Error, Sendable, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "Keychain error \(status)" }
}

/// Generic-password Keychain items, readable after first unlock so background
/// refresh can sync, never synced to iCloud, never in backups to other devices.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String

    public init(service: String = "com.codebater.folio.freshrss") { self.service = service }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func password(for key: String) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String, for key: String) throws {
        let data = Data(password.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(key)
            add.merge(update) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func removePassword(for key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
#endif
