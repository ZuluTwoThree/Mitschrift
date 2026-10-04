import Foundation
import Combine
import MitschriftCore

/// Verwaltet gespeicherte Serverprofile, das ausgewählte Profil, das Eingabeformular und die Sprache;
/// prüft die Verbindung über `/v1/health`.
@MainActor
final class SettingsStore: ObservableObject {
    enum ConnectionState: Equatable {
        case unknown
        case testing
        case ok(model: String, version: String, diarization: Bool)
        case failed(String)
    }

    /// Auswahl im Server-Menü: ein gespeichertes Profil oder „Neuer Server …“.
    enum Selection: Hashable {
        case profile(UUID)
        case new
    }

    @Published private(set) var profiles: [ServerProfile] = []
    @Published var selection: Selection = .new {
        didSet { if selection != oldValue { selectionChanged() } }
    }

    // Formularfelder für das ausgewählte oder ein neues Profil
    @Published var profileName: String = ""
    @Published var serverAddress: String = ""
    /// Leer lassen behält bei einem bestehenden Profil den gespeicherten Zugangscode.
    @Published var token: String = ""

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

    private let store: ServerProfileStore
    private let defaults: UserDefaults

    init(store: ServerProfileStore = KeychainServerProfileStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        language = defaults.string(forKey: Keys.language) ?? "de"
        privacyNoticeAccepted = defaults.bool(forKey: Keys.privacyAccepted)
        reload()
        #if DEBUG
        applyDevelopmentOverrides()
        #endif
    }

    // MARK: Auswahl

    /// Das ausgewählte Profil, falls eines gespeichert und gewählt ist.
    var selectedProfile: ServerProfile? {
        guard case .profile(let id) = selection else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Endpunkt des ausgewählten Profils, falls vollständig.
    var endpoint: ServerEndpoint? {
        guard case .profile(let id) = selection else { return nil }
        return store.endpoint(for: id)
    }

    var isConfigured: Bool { endpoint != nil }

    /// Anzeigename für die Aufnahme-Ansicht.
    var selectedServerName: String? { selectedProfile?.name }

    private func reload() {
        profiles = store.profiles()
        if let id = store.selectedProfileID, profiles.contains(where: { $0.id == id }) {
            selection = .profile(id)
        } else if let first = profiles.first {
            selection = .profile(first.id)
            store.select(id: first.id)
        } else {
            selection = .new
        }
        fillForm()
    }

    private func selectionChanged() {
        if case .profile(let id) = selection {
            store.select(id: id)
        }
        connection = .unknown
        saveError = nil
        fillForm()
    }

    private func fillForm() {
        if let profile = selectedProfile {
            profileName = profile.name
            serverAddress = profile.baseURL.absoluteString
        } else {
            profileName = ""
            serverAddress = ""
        }
        token = ""
    }

    // MARK: Speichern, Löschen, Prüfen

    /// Prüft die Eingaben, legt das Profil an oder aktualisiert es, wählt es aus. Meldet Fehler lesbar.
    @discardableResult
    func save() -> Bool {
        guard let url = ServerEndpoint.normalizedURL(from: serverAddress) else {
            saveError = "Bitte eine HTTPS-Adresse eingeben, z. B. https://asr.<tailnet>.ts.net"
            return false
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? ServerProfile.suggestedName(for: url) : trimmedName

        var profile: ServerProfile
        if let existing = selectedProfile {
            profile = existing
            profile.name = name
            profile.baseURL = url
        } else {
            guard !trimmedToken.isEmpty else {
                saveError = "Bitte den Zugangscode des Servers eingeben."
                return false
            }
            profile = ServerProfile(name: name, baseURL: url)
        }
        do {
            try store.save(profile, token: trimmedToken.isEmpty ? nil : trimmedToken)
            store.select(id: profile.id)
            profiles = store.profiles()
            if selection != .profile(profile.id) {
                selection = .profile(profile.id)
            } else {
                fillForm()
            }
            saveError = nil
            return true
        } catch {
            saveError = "Speichern fehlgeschlagen: \(error.localizedDescription)"
            return false
        }
    }

    /// Entfernt das ausgewählte Profil samt Zugangscode.
    func deleteSelectedProfile() {
        guard case .profile(let id) = selection else { return }
        do {
            try store.delete(id: id)
            saveError = nil
            reload()
        } catch {
            saveError = "Entfernen fehlgeschlagen: \(error.localizedDescription)"
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
                connection = .ok(model: health.model ?? "unbekannt", version: health.version ?? "?", diarization: health.diarization ?? false)
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

    #if DEBUG
    /// Für Simulator-Tests: `SIMCTL_CHILD_MITSCHRIFT_DEV_ENDPOINT` und `…_TOKEN` beim Start setzen.
    /// Legt ein Profil „Entwicklung“ an oder aktualisiert es und wählt es aus.
    private func applyDevelopmentOverrides() {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["MITSCHRIFT_DEV_ENDPOINT"], let devToken = env["MITSCHRIFT_DEV_TOKEN"] else {
            NSLog("Mitschrift: keine Dev-Overrides (MITSCHRIFT_DEV_ENDPOINT/TOKEN) gesetzt")
            return
        }
        if let existing = profiles.first(where: { $0.name == "Entwicklung" }) {
            selection = .profile(existing.id)
        } else {
            selection = .new
        }
        profileName = "Entwicklung"
        serverAddress = address
        token = devToken
        privacyNoticeAccepted = true
        let saved = save()
        NSLog("Mitschrift: Dev-Override %@ für %@ (%@)", saved ? "gespeichert" : "fehlgeschlagen", address, saveError ?? "ok")
    }
    #endif
}
