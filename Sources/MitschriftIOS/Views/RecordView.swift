import SwiftUI
import MitschriftCore

struct RecordView: View {
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var retry = FileTranscriptionTask()
    @State private var showPrivacyNotice = false
    @State private var retrying = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(recorder.elapsedText)
                    .font(.system(size: 48, weight: .semibold, design: .monospaced))
                    .contentTransition(.numericText())
                statusLine
                recordButton
                serverLine
                if let session = recorder.liveSession, recorder.state.isRecording || recorder.state == .stopping {
                    LiveTranscriptView(session: session)
                } else if let result = recorder.result {
                    ResultView(result: result, retrying: retrying, retryProgress: retry.progress, retryError: retry.error,
                               canRetry: settings.isConfigured && (result.liveIncomplete || result.transcript.isEmpty),
                               onRetry: { Task { await retryTranscription(result) } })
                } else {
                    Spacer()
                }
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
                    Task { await startRecording() }
                }
            }
        }
    }

    private func startRecording() async {
        await recorder.start(endpoint: settings.endpoint, language: settings.language)
    }

    private func retryTranscription(_ result: RecordingController.Result) async {
        guard let endpoint = settings.endpoint else { return }
        retrying = true
        defer { retrying = false }
        guard let transcript = await retry.run(audioURL: result.audioURL, endpoint: endpoint, language: settings.language) else { return }
        var updated = result
        updated.transcript = transcript
        updated.liveIncomplete = false
        let url = result.audioURL.deletingLastPathComponent()
            .appendingPathComponent(RecordingNaming.transcriptFileName(forAudioNamed: result.audioURL.lastPathComponent))
        if (try? transcript.exportText.write(to: url, atomically: true, encoding: .utf8)) != nil {
            updated.transcriptURL = url
        }
        recorder.update(result: updated)
    }

    private var recordButton: some View {
        Button {
            if recorder.state.isRecording {
                Task { await recorder.stop() }
            } else if !settings.privacyNoticeAccepted {
                showPrivacyNotice = true
            } else {
                Task { await startRecording() }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(recorder.state.isRecording ? Color.red.opacity(0.2) : Color.accentColor.opacity(0.18))
                    .frame(width: 104, height: 104)
                if recorder.state.isRecording {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.red)
                        .frame(width: 38, height: 38)
                } else {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 52, height: 52)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(recorder.state == .stopping || retrying)
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
                Label("Live über \(settings.selectedServerName ?? "eigenen Server") · Segmente: \(recorder.segmentCount)", systemImage: "network")
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
        case .finished: return "Aufnahme gespeichert"
        case .failed(let message): return message
        }
    }

    private var statusColor: Color {
        switch recorder.state {
        case .recording: return .red
        case .interrupted, .stopping, .failed: return .orange
        default: return .green
        }
    }
}

/// Ergebnis nach dem Stoppen: Text, Hinweis auf Lücken, Export, nachträgliche Übertragung.
private struct ResultView: View {
    var result: RecordingController.Result

    private var resultText: Text {
        if result.transcript.isEmpty { return Text("Keine Mitschrift vorhanden.") }
        var text = LiveTranscriptView.finalText(for: result.transcript)
        // Vorläufiger Rest (z. B. wenn finish scheiterte) bleibt sichtbar, wie im Export.
        let partial = result.transcript.partialText
        if !partial.isEmpty {
            let separator = result.transcript.finalSegments.isEmpty ? "" : (result.transcript.hasSpeakers ? "\n" : " ")
            text = text + Text(separator + partial).italic().foregroundColor(.secondary)
        }
        return text
    }

    private var incompleteText: String {
        if result.missingSegments > 0 {
            return "Die Live-Übertragung war unvollständig: \(result.missingSegments) Abschnitt(e) fehlen. Die Aufnahme ist lokal gesichert."
        }
        return "Die Live-Übertragung war unvollständig. Die Aufnahme ist lokal gesichert."
    }
    var retrying: Bool
    var retryProgress: Double
    var retryError: String?
    var canRetry: Bool
    var onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if result.liveIncomplete {
                Label(incompleteText, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            ScrollView {
                resultText
                    .foregroundStyle(result.transcript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

            if retrying {
                ProgressView(value: retryProgress) { Text("Aufnahme wird nachträglich übertragen …") }
            } else if let retryError {
                Text(retryError).font(.footnote).foregroundStyle(.orange)
            }

            HStack {
                if canRetry && !retrying {
                    Button("Nachträglich transkribieren", action: onRetry)
                        .buttonStyle(.bordered)
                }
                Spacer()
                if let transcriptURL = result.transcriptURL {
                    ShareLink(item: transcriptURL) { Label("Mitschrift", systemImage: "square.and.arrow.up") }
                }
                ShareLink(item: result.audioURL) { Label("Audio", systemImage: "waveform") }
            }
            .font(.callout)
        }
    }
}
