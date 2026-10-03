import SwiftUI
import MitschriftCore

struct RecordView: View {
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var settings: SettingsStore
    @State private var showPrivacyNotice = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                Text(recorder.elapsedText)
                    .font(.system(size: 54, weight: .semibold, design: .monospaced))
                    .contentTransition(.numericText())
                statusLine
                recordButton
                serverLine
                Spacer()
                if recorder.permissionDenied {
                    permissionHint
                }
            }
            .padding()
            .navigationTitle("Mitschrift")
            .sheet(isPresented: $showPrivacyNotice) {
                PrivacyNoticeView {
                    settings.privacyNoticeAccepted = true
                    showPrivacyNotice = false
                    Task { await recorder.start() }
                }
            }
        }
    }

    private var recordButton: some View {
        Button {
            if recorder.state.isRecording {
                Task { await recorder.stop() }
            } else if !settings.privacyNoticeAccepted {
                showPrivacyNotice = true
            } else {
                Task { await recorder.start() }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(recorder.state.isRecording ? Color.red.opacity(0.2) : Color.accentColor.opacity(0.18))
                    .frame(width: 120, height: 120)
                if recorder.state.isRecording {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.red)
                        .frame(width: 44, height: 44)
                } else {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 60, height: 60)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(recorder.state == .stopping)
        .accessibilityLabel(recorder.state.isRecording ? "Aufnahme stoppen" : "Aufnahme starten")
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusText)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .font(.callout)
    }

    private var serverLine: some View {
        Group {
            if settings.isConfigured {
                Label("Server eingerichtet · Segmente: \(recorder.segmentCount)", systemImage: "network")
            } else {
                Label("Kein Server eingerichtet. Aufnahme wird nur lokal gespeichert.", systemImage: "externaldrive")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var permissionHint: some View {
        VStack(spacing: 8) {
            Text("Ohne Mikrofonzugriff kann Mitschrift nichts aufnehmen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Einstellungen öffnen", destination: url)
                    .font(.footnote)
            }
        }
    }

    private var statusText: String {
        switch recorder.state {
        case .idle: return "Bereit für eine neue Aufnahme"
        case .recording: return "Aufnahme läuft"
        case .interrupted: return "Aufnahme unterbrochen, wird fortgesetzt"
        case .stopping: return "Aufnahme wird abgeschlossen …"
        case .finished(let fileName): return "Gespeichert als \(fileName)"
        case .failed(let message): return message
        }
    }

    private var statusColor: Color {
        switch recorder.state {
        case .recording: return .red
        case .interrupted, .stopping: return .orange
        case .failed: return .orange
        default: return .green
        }
    }
}
