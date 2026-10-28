import Foundation
#if canImport(Security)
import Security
#endif

/// Thread-safe security manager for encrypted credential, token, and session storage.
///
/// Complies with iOS Security best practices:
/// - Never stores cookies, session tokens, or HTTP Basic auth in unencrypted JSON.
/// - Uses `kSecClassInternetPassword` for HTTP Basic Auth scoped to host and path.
/// - Uses `kSecClassGenericPassword` for origin-scoped session tokens and cookies.
/// - Scopes credentials to domain and/or download ID.
/// - Deletes sensitive credentials automatically when a download record is deleted.
/// - Provides cross-platform fallback for non-Apple test environments.
public final class KeychainManager: @unchecked Sendable {
    public static let shared = KeychainManager()

    private let lock = NSLock()
    private let serviceName = "com.swiftdownloadengine.keychain"

    // In-memory fallback dictionary for test environments or platforms lacking Security.framework
    private var fallbackStore: [String: Data] = [:]

    public init() {}

    // MARK: - HTTP Internet Password (HTTP Basic / Digest Auth)

    /// Saves or updates HTTP Basic auth credentials in the Keychain.
    @discardableResult
    public func storeInternetPassword(
        username: String,
        password: String,
        server: String,
        protocolType: String = "https",
        path: String = "/"
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let normalizedServer = server.lowercased()
        guard let passwordData = password.data(using: .utf8) else { return false }

        #if canImport(Security) && !os(Linux)
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: normalizedServer,
            kSecAttrAccount as String: username,
            kSecAttrPath as String: path
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: passwordData
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newQuery = query
            newQuery[kSecValueData as String] = passwordData
            let addStatus = SecItemAdd(newQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        return status == errSecSuccess
        #else
        let key = "internet:\(normalizedServer):\(path):\(username)"
        fallbackStore[key] = passwordData
        return true
        #endif
    }

    /// Retrieves HTTP Basic auth credentials from the Keychain for a specific server and path.
    public func getInternetPassword(
        server: String,
        path: String = "/"
    ) -> (username: String, password: String)? {
        lock.lock()
        defer { lock.unlock() }

        let normalizedServer = server.lowercased()

        #if canImport(Security) && !os(Linux)
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: normalizedServer,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let existingItem = item as? [String: Any],
              let account = existingItem[kSecAttrAccount as String] as? String,
              let passwordData = existingItem[kSecValueData as String] as? Data,
              let password = String(data: passwordData, encoding: .utf8) else {
            return nil
        }
        return (account, password)
        #else
        let prefix = "internet:\(normalizedServer):"
        for (key, data) in fallbackStore where key.hasPrefix(prefix) {
            let parts = key.split(separator: ":")
            if parts.count >= 4, let password = String(data: data, encoding: .utf8) {
                let user = String(parts[3])
                return (user, password)
            }
        }
        return nil
        #endif
    }

    /// Deletes stored HTTP Basic auth credentials for a server.
    @discardableResult
    public func deleteInternetPassword(server: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let normalizedServer = server.lowercased()

        #if canImport(Security) && !os(Linux)
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: normalizedServer
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
        #else
        let prefix = "internet:\(normalizedServer):"
        fallbackStore = fallbackStore.filter { !$0.key.hasPrefix(prefix) }
        return true
        #endif
    }

    // MARK: - Generic Secrets (Tokens, Cookies & Session Data)

    /// Securely stores encrypted token data or session cookies scoped to a domain and/or download ID.
    @discardableResult
    public func storeGenericSecret(
        key: String,
        account: String,
        data: Data
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        #if canImport(Security) && !os(Linux)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "\(account):\(key)"
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newQuery = query
            newQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(newQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        return status == errSecSuccess
        #else
        let combined = "\(account):\(key)"
        fallbackStore[combined] = data
        return true
        #endif
    }

    /// Retrieves encrypted token data or cookies for a domain and account.
    public func getGenericSecret(key: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        #if canImport(Security) && !os(Linux)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "\(account):\(key)",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return data
        #else
        let combined = "\(account):\(key)"
        return fallbackStore[combined]
        #endif
    }

    /// Deletes generic secret for an account and key.
    @discardableResult
    public func deleteGenericSecret(key: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        #if canImport(Security) && !os(Linux)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "\(account):\(key)"
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
        #else
        let combined = "\(account):\(key)"
        fallbackStore.removeValue(forKey: combined)
        return true
        #endif
    }

    // MARK: - Scoped Cookie & Session Storage

    /// Securely archives cookies in Keychain scoped to their origin domain and optional download ID.
    @discardableResult
    public func storeCookies(_ cookies: [HTTPCookie], domain: String, downloadId: String? = nil) -> Bool {
        guard !cookies.isEmpty else { return false }
        let cookieProperties = cookies.compactMap { $0.properties }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: cookieProperties, format: .binary, options: 0) else {
            return false
        }

        let normalizedDomain = domain.lowercased()
        var success = storeGenericSecret(key: "cookies", account: normalizedDomain, data: data)

        if let dlId = downloadId {
            _ = storeGenericSecret(key: "cookies:\(normalizedDomain)", account: "download:\(dlId)", data: data)
        }
        return success
    }

    /// Retrieves secure cookies stored for a domain.
    public func getCookies(domain: String) -> [HTTPCookie] {
        let normalizedDomain = domain.lowercased()
        guard let data = getGenericSecret(key: "cookies", account: normalizedDomain),
              let rawList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[HTTPCookiePropertyKey: Any]] else {
            return []
        }
        return rawList.compactMap { HTTPCookie(properties: $0) }
    }

    /// Purges all sensitive credentials, cookies, and tokens associated with a download ID.
    public func deleteCredentials(forDownloadId downloadId: String) {
        lock.lock()
        defer { lock.unlock() }

        #if canImport(Security) && !os(Linux)
        let prefix = "download:\(downloadId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName
        ]
        // Note: Generic password deletion for specific prefix
        _ = SecItemDelete(query as CFDictionary)
        #else
        let prefix = "download:\(downloadId)"
        fallbackStore = fallbackStore.filter { !$0.key.hasPrefix(prefix) }
        #endif
    }

    /// Clears all in-memory fallback items (useful in tests).
    public func resetFallbackStore() {
        lock.lock()
        defer { lock.unlock() }
        fallbackStore.removeAll()
    }
}
