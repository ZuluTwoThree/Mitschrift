import Foundation
import Combine
import MitschriftCore

/// Hält Server-URL, Token und Sprache; prüft die Verbindung über `/v1/health`.
@MainActor
final class SettingsStore: ObservableObject {
    enum ConnectionState: Equatable {
        case unknown
        case testing
        case ok(model: String, version: String)
        case failed(String)
    }

    @Published var serverAddress: String
    @Published var token: String
    @Published var language: String {
        didSet { defaults.set(language, forKey: Keys.language) }
    }
    @Published private(set) var connection: ConnectionState = .unknown
    @Published private(set) var saveError: String?
    @Published var privacyNoticeAccepted: Bool {
        didSet { defaults.set(privacyNoticeAccepted, forKey: Keys.privacyAccepted) }
    }

    private enum Keys {
        static let language = "mitschrift.language"
        static let privacyAccepted = "mitschrift.privacyNoticeAccepted"
    }

    private let store: EndpointStore
    private let defaults: UserDefaults

    init(store: EndpointStore = KeychainEndpointStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        let endpoint = store.load()
        serverAddress = endpoint?.baseURL.absoluteString ?? (store as? KeychainEndpointStore)?.storedURL?.absoluteString ?? ""
        token = endpoint?.token ?? ""
        language = defaults.string(forKey: Keys.language) ?? "de"
        privacyNoticeAccepted = defaults.bool(forKey: Keys.privacyAccepted)
    }

    /// Der gespeicherte Endpunkt, falls vollständig.
    var endpoint: ServerEndpoint? { store.load() }
    var isConfigured: Bool { endpoint != nil }

    /// Prüft Eingaben, speichert und meldet Fehler lesbar.
    @discardableResult
    func save() -> Bool {
        guard let url = ServerEndpoint.normalizedURL(from: serverAddress) else {
            saveError = "Bitte eine HTTPS-Adresse eingeben, z. B. https://asr.<tailnet>.ts.net"
            return false
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            saveError = "Bitte den Zugangscode des Servers eingeben."
            return false
        }
        do {
            try store.save(ServerEndpoint(baseURL: url, token: trimmedToken))
            serverAddress = url.absoluteString
            token = trimmedToken
            saveError = nil
            return true
        } catch {
            saveError = "Speichern fehlgeschlagen: \(error.localizedDescription)"
            return false
        }
    }

    func testConnection() async {
        guard save(), let endpoint else {
            connection = .failed(saveError ?? "Keine Konfiguration")
            return
        }
        connection = .testing
        let transport = URLSessionLiveTransport(endpoint: endpoint)
        do {
            let health = try await transport.health()
            if health.isHealthy {
                connection = .ok(model: health.model ?? "unbekannt", version: health.version ?? "?")
            } else {
                connection = .failed("Server meldet Status „\(health.status)“. Modell lädt noch oder whisper-server antwortet nicht.")
            }
        } catch let error as LiveTranscriptionError {
            connection = .failed(Self.explain(error))
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    private static func explain(_ error: LiveTranscriptionError) -> String {
        switch error {
        case .transport:
            return "Server nicht erreichbar. Ist Tailscale auf dem iPhone verbunden und die Adresse richtig?"
        case .unauthorized:
            return "Der Server lehnt den Zugangscode ab."
        default:
            return error.userMessage
        }
    }
}
