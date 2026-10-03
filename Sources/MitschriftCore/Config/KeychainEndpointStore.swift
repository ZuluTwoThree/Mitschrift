import Foundation
import Security

/// Speichert die Server-URL in `UserDefaults` und den Token im Schlüsselbund.
public final class KeychainEndpointStore: EndpointStore {
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

    private let defaults: UserDefaults
    private let urlKey: String
    private let service: String
    private let account: String

    public init(
        defaults: UserDefaults = .standard,
        urlKey: String = "mitschrift.server.url",
        service: String = "io.github.zulutwothree.mitschrift",
        account: String = "asr-token"
    ) {
        self.defaults = defaults
        self.urlKey = urlKey
        self.service = service
        self.account = account
    }

    public var storedURL: URL? {
        defaults.string(forKey: urlKey).flatMap(URL.init(string:))
    }

    public func load() -> ServerEndpoint? {
        guard let url = storedURL, let token = readToken() else { return nil }
        return ServerEndpoint(baseURL: url, token: token)
    }

    public func save(_ endpoint: ServerEndpoint) throws {
        defaults.set(endpoint.baseURL.absoluteString, forKey: urlKey)
        try writeToken(endpoint.token)
    }

    public func clear() throws {
        defaults.removeObject(forKey: urlKey)
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }

    private func readToken() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeToken(_ token: String) throws {
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery()
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
