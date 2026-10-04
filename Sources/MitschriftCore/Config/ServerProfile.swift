import Foundation

/// Ein gespeicherter Server: Name und private HTTPS-Adresse. Der Zugangscode liegt getrennt im `TokenStore`.
public struct ServerProfile: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: URL

    public init(id: UUID = UUID(), name: String, baseURL: URL) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
    }

    /// Konto im Schlüsselbund für den Zugangscode dieses Profils.
    public var tokenAccount: String { "asr-token.\(id.uuidString.lowercased())" }

    /// Leitet einen Anzeigenamen aus dem Host ab: `kiworkstation` aus `kiworkstation.<tailnet>.ts.net`,
    /// `127.0.0.1:8765` bei Adressen ohne Namen.
    public static func suggestedName(for url: URL) -> String {
        guard let host = url.host, !host.isEmpty else { return "Server" }
        let isNumeric = host.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" || $0 == "[" || $0 == "]" }
        if isNumeric {
            return url.port.map { "\(host):\($0)" } ?? host
        }
        return host.split(separator: ".").first.map(String.init) ?? host
    }
}

/// Verwaltung mehrerer Serverprofile und der Auswahl.
public protocol ServerProfileStore: AnyObject {
    func profiles() -> [ServerProfile]
    var selectedProfileID: UUID? { get }
    /// Speichert oder aktualisiert ein Profil. `token` `nil` behält den vorhandenen Zugangscode.
    func save(_ profile: ServerProfile, token: String?) throws
    func delete(id: UUID) throws
    func select(id: UUID?)
    func endpoint(for id: UUID) -> ServerEndpoint?
}

public extension ServerProfileStore {
    var selectedProfile: ServerProfile? {
        guard let id = selectedProfileID else { return nil }
        return profiles().first { $0.id == id }
    }

    /// Endpunkt des ausgewählten Profils, falls vollständig.
    var selectedEndpoint: ServerEndpoint? {
        selectedProfileID.flatMap(endpoint(for:))
    }
}

/// Profile als JSON in `UserDefaults`, Zugangscodes im `TokenStore` (Standard: Schlüsselbund).
///
/// Beim ersten Laden wird eine bestehende Einzelkonfiguration (`KeychainEndpointStore`) zu einem Profil
/// „Server 1“ und danach entfernt.
public final class KeychainServerProfileStore: ServerProfileStore {
    public enum Keys {
        public static let profiles = "mitschrift.server.profiles"
        public static let selected = "mitschrift.server.selected"
    }

    public enum SaveError: LocalizedError, Equatable {
        case missingToken

        public var errorDescription: String? {
            "Für diesen Server ist noch kein Zugangscode hinterlegt."
        }
    }

    private let defaults: UserDefaults
    private let tokens: TokenStore
    private let legacy: EndpointStore?
    private var cache: [ServerProfile]?

    public init(
        defaults: UserDefaults = .standard,
        tokens: TokenStore = KeychainTokenStore(),
        legacy: EndpointStore? = KeychainEndpointStore()
    ) {
        self.defaults = defaults
        self.tokens = tokens
        self.legacy = legacy
    }

    public func profiles() -> [ServerProfile] {
        if let cache { return cache }
        var list: [ServerProfile] = []
        if let data = defaults.data(forKey: Keys.profiles),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            list = decoded
        }
        if list.isEmpty, let legacy, let endpoint = legacy.load() {
            let migrated = ServerProfile(name: "Server 1", baseURL: endpoint.baseURL)
            if (try? tokens.setToken(endpoint.token, for: migrated.tokenAccount)) != nil {
                list = [migrated]
                persist(list)
                defaults.set(migrated.id.uuidString, forKey: Keys.selected)
                try? legacy.clear()
            }
        }
        cache = list
        return list
    }

    public var selectedProfileID: UUID? {
        _ = profiles() // Migration anstoßen
        return defaults.string(forKey: Keys.selected).flatMap(UUID.init(uuidString:))
    }

    public func save(_ profile: ServerProfile, token: String?) throws {
        var list = profiles()
        if let token {
            try tokens.setToken(token, for: profile.tokenAccount)
        } else if tokens.token(for: profile.tokenAccount) == nil {
            throw SaveError.missingToken
        }
        if let index = list.firstIndex(where: { $0.id == profile.id }) {
            list[index] = profile
        } else {
            list.append(profile)
        }
        persist(list)
    }

    public func delete(id: UUID) throws {
        var list = profiles()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        try tokens.removeToken(for: list[index].tokenAccount)
        list.remove(at: index)
        persist(list)
        if selectedProfileID == id {
            select(id: list.first?.id)
        }
    }

    public func select(id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: Keys.selected)
        } else {
            defaults.removeObject(forKey: Keys.selected)
        }
    }

    public func endpoint(for id: UUID) -> ServerEndpoint? {
        guard let profile = profiles().first(where: { $0.id == id }),
              let token = tokens.token(for: profile.tokenAccount) else { return nil }
        return ServerEndpoint(baseURL: profile.baseURL, token: token)
    }

    private func persist(_ list: [ServerProfile]) {
        cache = list
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Keys.profiles)
        }
    }
}

/// Profile nur im Speicher, für Tests und Vorschauen.
public final class InMemoryServerProfileStore: ServerProfileStore {
    private var list: [ServerProfile] = []
    private var tokens: [UUID: String] = [:]
    public private(set) var selectedProfileID: UUID?

    public init() {}

    public func profiles() -> [ServerProfile] { list }

    public func save(_ profile: ServerProfile, token: String?) throws {
        if let token { tokens[profile.id] = token }
        guard tokens[profile.id] != nil else { throw KeychainServerProfileStore.SaveError.missingToken }
        if let index = list.firstIndex(where: { $0.id == profile.id }) {
            list[index] = profile
        } else {
            list.append(profile)
        }
    }

    public func delete(id: UUID) throws {
        list.removeAll { $0.id == id }
        tokens[id] = nil
        if selectedProfileID == id { selectedProfileID = list.first?.id }
    }

    public func select(id: UUID?) { selectedProfileID = id }

    public func endpoint(for id: UUID) -> ServerEndpoint? {
        guard let profile = list.first(where: { $0.id == id }), let token = tokens[id] else { return nil }
        return ServerEndpoint(baseURL: profile.baseURL, token: token)
    }
}
