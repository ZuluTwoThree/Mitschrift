import Foundation
import Security

/// Ablage von Zugangscodes je Konto. Der Schlüsselbund ist die Standardumsetzung; Tests nutzen `InMemoryTokenStore`.
public protocol TokenStore: AnyObject {
    func token(for account: String) -> String?
    func setToken(_ token: String, for account: String) throws
    func removeToken(for account: String) throws
}

/// Zugangscodes als generische Passwörter im Schlüsselbund, ein Eintrag je Konto.
public final class KeychainTokenStore: TokenStore {
    public enum Failure: LocalizedError, Equatable {
        case keychain(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let text = SecCopyErrorMessageString(status, nil) as String? ?? "unbekannt"
                return "Schlüsselbund-Fehler \(status): \(text)"
            }
        }
    }

    public let service: String

    public init(service: String = "io.github.zulutwothree.mitschrift") {
        self.service = service
    }

    public func token(for account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setToken(_ token: String, for account: String) throws {
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(account: account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    public func removeToken(for account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// Zugangscodes nur im Speicher, für Tests und Vorschauen.
public final class InMemoryTokenStore: TokenStore {
    public private(set) var tokens: [String: String] = [:]

    public init(_ tokens: [String: String] = [:]) {
        self.tokens = tokens
    }

    public func token(for account: String) -> String? { tokens[account] }
    public func setToken(_ token: String, for account: String) throws { tokens[account] = token }
    public func removeToken(for account: String) throws { tokens[account] = nil }
}
