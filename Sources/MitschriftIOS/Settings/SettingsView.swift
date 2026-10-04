import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Server", selection: $settings.selection) {
                        ForEach(settings.profiles) { profile in
                            Text(profile.name).tag(SettingsStore.Selection.profile(profile.id))
                        }
                        Text("Neuer Server …").tag(SettingsStore.Selection.new)
                    }
                    .pickerStyle(.menu)
                } footer: {
                    if settings.profiles.isEmpty {
                        Text("Nach dem ersten Speichern erscheint der Server hier im Menü.")
                    }
                }

                Section {
                    TextField(settings.selectedProfile == nil ? "Name (optional)" : "Name", text: $settings.profileName)
                        .autocorrectionDisabled()
                    TextField("https://asr.<tailnet>.ts.net", text: $settings.serverAddress)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField(settings.selectedProfile == nil ? "Zugangscode" : "Zugangscode (leer = beibehalten)", text: $settings.token)
                        .textContentType(.password)
                } header: {
                    Text(settings.selectedProfile == nil ? "Neuer Server" : "Eigener ASR-Server")
                } footer: {
                    Text("Die Adresse ist nur im privaten Tailnet erreichbar. Der Zugangscode wird im Schlüsselbund gespeichert.")
                }

                Section("Sprache") {
                    Picker("Sprache", selection: $settings.language) {
                        Text("Deutsch").tag("de")
                        Text("Englisch").tag("en")
                        Text("Automatisch").tag("auto")
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button {
                        Task { await settings.testConnection() }
                    } label: {
                        HStack {
                            Text("Speichern und Verbindung testen")
                            Spacer()
                            if settings.connection == .testing { ProgressView() }
                        }
                    }
                    .disabled(settings.connection == .testing)
                    connectionRow
                }

                if let error = settings.saveError {
                    Section {
                        Text(error).foregroundStyle(.orange)
                    }
                }

                if let profile = settings.selectedProfile {
                    Section {
                        Button("Server entfernen", role: .destructive) {
                            confirmDelete = true
                        }
                        .confirmationDialog(
                            "„\(profile.name)“ samt Zugangscode entfernen?",
                            isPresented: $confirmDelete,
                            titleVisibility: .visible
                        ) {
                            Button("Entfernen", role: .destructive) { settings.deleteSelectedProfile() }
                            Button("Abbrechen", role: .cancel) {}
                        }
                    }
                }
            }
            .navigationTitle("Server")
        }
    }

    @ViewBuilder
    private var connectionRow: some View {
        switch settings.connection {
        case .unknown:
            EmptyView()
        case .testing:
            Label("Verbindung wird geprüft …", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        case .ok(let model, let version, let diarization):
            Label("Verbunden · Modell \(model) · Version \(version)" + (diarization ? " · Sprechertrennung" : ""), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
