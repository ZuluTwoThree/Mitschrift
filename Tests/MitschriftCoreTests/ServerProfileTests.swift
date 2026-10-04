import Foundation
import Testing
@testable import MitschriftCore

@Suite struct ServerProfileTests {
    private let url = URL(string: "https://asr.example.ts.net")!

    @Test func suggestedNames() {
        #expect(ServerProfile.suggestedName(for: URL(string: "https://kiworkstation.example.ts.net")!) == "kiworkstation")
        #expect(ServerProfile.suggestedName(for: URL(string: "http://127.0.0.1:8765")!) == "127.0.0.1:8765")
        #expect(ServerProfile.suggestedName(for: URL(string: "https://asr")!) == "asr")
    }

    @Test func codableRoundTrip() throws {
        let profile = ServerProfile(name: "Büro", baseURL: url)
        let data = try JSONEncoder().encode([profile])
        let decoded = try JSONDecoder().decode([ServerProfile].self, from: data)
        #expect(decoded == [profile])
        #expect(profile.tokenAccount == "asr-token.\(profile.id.uuidString.lowercased())")
    }

    @Test func inMemorySaveSelectDelete() throws {
        let store = InMemoryServerProfileStore()
        let a = ServerProfile(name: "A", baseURL: url)
        let b = ServerProfile(name: "B", baseURL: URL(string: "https://b.example")!)
        try store.save(a, token: "ta")
        try store.save(b, token: "tb")
        store.select(id: b.id)
        #expect(store.profiles().map(\.name) == ["A", "B"])
        #expect(store.selectedProfile == b)
        #expect(store.selectedEndpoint == ServerEndpoint(baseURL: b.baseURL, token: "tb"))

        var renamed = a
        renamed.name = "A2"
        try store.save(renamed, token: nil)
        #expect(store.profiles().first?.name == "A2")
        #expect(store.endpoint(for: a.id)?.token == "ta", "Token bleibt ohne Neueingabe erhalten")

        try store.delete(id: b.id)
        #expect(store.profiles().count == 1)
        #expect(store.selectedProfileID == a.id, "Nach Löschen des gewählten Profils fällt die Auswahl auf das erste")

        #expect(throws: KeychainServerProfileStore.SaveError.missingToken) {
            try store.save(ServerProfile(name: "ohne", baseURL: url), token: nil)
        }
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func persistsProfilesInDefaultsAndTokensInTokenStore() throws {
        let defaults = freshDefaults()
        let tokens = InMemoryTokenStore()
        let store = KeychainServerProfileStore(defaults: defaults, tokens: tokens, legacy: nil)
        let profile = ServerProfile(name: "Büro", baseURL: url)
        try store.save(profile, token: "geheim")
        store.select(id: profile.id)

        let reloaded = KeychainServerProfileStore(defaults: defaults, tokens: tokens, legacy: nil)
        #expect(reloaded.profiles() == [profile])
        #expect(reloaded.selectedProfileID == profile.id)
        #expect(reloaded.selectedEndpoint?.token == "geheim")
        #expect(tokens.tokens[profile.tokenAccount] == "geheim")

        try reloaded.delete(id: profile.id)
        #expect(reloaded.profiles().isEmpty)
        #expect(tokens.tokens[profile.tokenAccount] == nil)
        #expect(reloaded.selectedProfileID == nil)
    }

    @Test func migratesLegacySingleEndpoint() throws {
        let defaults = freshDefaults()
        let tokens = InMemoryTokenStore()
        let legacy = InMemoryEndpointStore(ServerEndpoint(baseURL: url, token: "alt"))
        let store = KeychainServerProfileStore(defaults: defaults, tokens: tokens, legacy: legacy)

        let profiles = store.profiles()
        #expect(profiles.count == 1)
        #expect(profiles.first?.name == "Server 1")
        #expect(profiles.first?.baseURL == url)
        #expect(store.selectedProfileID == profiles.first?.id)
        #expect(store.selectedEndpoint?.token == "alt")
        #expect(legacy.load() == nil, "Alte Konfiguration wird nach der Migration entfernt")

        // Zweites Laden migriert nicht erneut
        let again = KeychainServerProfileStore(defaults: defaults, tokens: tokens, legacy: InMemoryEndpointStore(ServerEndpoint(baseURL: url, token: "neu")))
        #expect(again.profiles().count == 1)
    }
}
