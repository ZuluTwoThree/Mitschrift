import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://asr.<tailnet>.ts.net", text: $settings.serverAddress)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Zugangscode", text: $settings.token)
                        .textContentType(.password)
                } header: {
                    Text("Eigener ASR-Server")
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
