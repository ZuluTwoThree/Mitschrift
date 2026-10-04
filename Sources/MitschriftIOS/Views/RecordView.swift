import SwiftUI
import MitschriftCore

/// Hauptansicht: Statusleiste, Protokollblatt und Transportleiste. Einstellungen liegen als Blatt darüber.
struct RecordView: View {
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var retry = FileTranscriptionTask()
    @State private var showPrivacyNotice = false
    @State private var showSettings = false
    @State private var retrying = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 8)
            paper
                .padding(.horizontal, Theme.gutter)
            if let result = recorder.result, !recorder.state.isRecording {
                ResultActions(result: result, retrying: retrying, retryProgress: retry.progress, retryError: retry.error,
                              canRetry: settings.isConfigured && (result.liveIncomplete || result.transcript.isEmpty),
                              onRetry: { Task { await retryTranscription(result) } })
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, 10)
            }
            if recorder.permissionDenied {
                permissionHint
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, 10)
            }
            transportBar
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 12)
        }
        .themedScreen()
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
        }
        .sheet(isPresented: $showPrivacyNotice) {
            PrivacyNoticeView {
                settings.privacyNoticeAccepted = true
                showPrivacyNotice = false
                Task { await startRecording() }
            }
        }
        .onAppear(perform: seedSampleIfRequested)
    }

    // MARK: Kopf

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Mitschrift")
                    .font(Theme.Fonts.title)
                    .foregroundStyle(Theme.paper)
                Spacer()
                stateChip
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "server.rack")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.mist)
                        .frame(width: 36, height: 36)
                        .background(Theme.ink, in: Circle())
                }
                .accessibilityLabel("Server einstellen")
                .disabled(recorder.state.isRecording)
            }
            Text(serverText)
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.mist)
        }
    }

    private var stateChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(chipColor)
                .frame(width: 8, height: 8)
                .modifier(PulseWhen(active: recorder.state == .recording && !reduceMotion))
            Text(chipText)
                .font(Theme.Fonts.footnote)
                .foregroundStyle(chipColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.ink, in: Capsule())
    }

    private var chipText: String {
        switch recorder.state {
        case .recording: return settings.isConfigured ? "Live" : "Aufnahme"
        case .interrupted: return "Unterbrochen"
        case .stopping: return "Abschluss"
        case .finished: return "Gespeichert"
        case .failed: return "Fehler"
        case .idle: return "Bereit"
        }
    }

    private var chipColor: Color {
        switch recorder.state {
        case .recording: return settings.isConfigured ? Theme.mint : Theme.coral
        case .interrupted, .stopping: return Theme.amber
        case .failed: return Theme.coral
        default: return Theme.mist
        }
    }

    private var serverText: String {
        if case .failed(let message) = recorder.state { return message }
        guard settings.isConfigured else { return "Kein Server eingerichtet, die Aufnahme bleibt auf diesem iPhone." }
        let name = settings.selectedServerName ?? "eigenen Server"
        if recorder.state.isRecording || recorder.state == .stopping {
            return "Live über \(name), \(recorder.segmentCount) Abschnitte gesendet"
        }
        return "Live über \(name)"
    }

    // MARK: Blatt

    @ViewBuilder
    private var paper: some View {
        if let session = recorder.liveSession, recorder.state.isRecording || recorder.state == .stopping {
            LiveTranscriptView(session: session)
        } else if let result = recorder.result {
            TranscriptPaper(transcript: result.transcript, emptyText: "Keine Mitschrift entstanden. Die Aufnahme ist gespeichert.")
        } else if recorder.state.isRecording {
            TranscriptPaper(transcript: Transcript(), emptyText: "Die Aufnahme läuft und wird auf diesem iPhone gespeichert.")
        } else {
            TranscriptPaper(transcript: Transcript(), emptyText: idleText)
        }
    }

    private var idleText: String {
        settings.isConfigured
            ? "Noch keine Mitschrift. Starte eine Aufnahme, der Text erscheint hier, während gesprochen wird."
            : "Noch keine Mitschrift. Richte zuerst einen Server ein, damit der Text live erscheint, oder nimm nur lokal auf."
    }

    // MARK: Transport

    private var transportBar: some View {
        HStack(spacing: 16) {
            recordButton
            VStack(alignment: .leading, spacing: 2) {
                Text(recorder.elapsedText)
                    .font(Theme.Fonts.timer)
                    .foregroundStyle(recorder.state.isRecording ? Theme.coral : Theme.paper)
                    .contentTransition(.numericText())
                Text(transportText)
                    .font(Theme.Fonts.status)
                    .foregroundStyle(Theme.mist)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var transportText: String {
        switch recorder.state {
        case .idle, .finished, .failed: return "Aufnahme starten"
        case .recording: return "Aufnahme läuft"
        case .interrupted: return "Pausiert, wird fortgesetzt"
        case .stopping: return "Wird abgeschlossen"
        }
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
                    .fill(Theme.coral)
                    .frame(width: 60, height: 60)
                if recorder.state.isRecording {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.night)
                        .frame(width: 22, height: 22)
                } else {
                    Circle()
                        .strokeBorder(Theme.night, lineWidth: 3)
                        .frame(width: 26, height: 26)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(recorder.state == .stopping || retrying)
        .opacity(recorder.state == .stopping || retrying ? 0.5 : 1)
        .accessibilityLabel(recorder.state.isRecording ? "Aufnahme stoppen" : "Aufnahme starten")
    }

    private var permissionHint: some View {
        HStack(spacing: 10) {
            Text("Ohne Mikrofonzugriff kann Mitschrift nichts aufnehmen.")
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.amber)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Einstellungen öffnen", destination: url)
                    .font(Theme.Fonts.footnote.weight(.semibold))
                    .foregroundStyle(Theme.paper)
            }
        }
    }

    // MARK: Aktionen

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

    /// Nur für Gestaltungs-Screenshots im Simulator: `SIMCTL_CHILD_MITSCHRIFT_DEV_SAMPLE=1`.
    private func seedSampleIfRequested() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MITSCHRIFT_DEV_SHOW_SETTINGS"] == "1" { showSettings = true }
        guard ProcessInfo.processInfo.environment["MITSCHRIFT_DEV_SAMPLE"] == "1", recorder.result == nil else { return }
        let transcript = Transcript(finalSegments: [
            Segment(start: 0, end: 1.6, text: "Und es rührt an die Grundfesten auch der Union.", speaker: "1"),
            Segment(start: 1.9, end: 13.4, text: "Ja, wir haben die Form, wir haben das Thema. Er selbst hat eine Erklärung abgegeben am Samstag, kleiner Ausschnitt daraus, von dem, was Jens Spahn seiner Fraktion geschrieben hat.", speaker: "2"),
            Segment(start: 13.5, end: 29.8, text: "Die zunehmende Unerbittlichkeit in der öffentlichen Auseinandersetzung hat mich sehr nachdenklich gemacht. Lasst uns doch bei aller Klarheit und Entschiedenheit in der Sache immer im Ton auch menschlich bleiben.", speaker: "2"),
            Segment(start: 30.4, end: 37.0, text: "Herr Neubacher, spricht Ihnen das ein bisschen aus dem Herzen?", speaker: "1"),
            Segment(start: 37.2, end: 52.4, text: "Ja, also Jens Spahn hätte viele Gründe gehabt, zurückzutreten, meiner Ansicht nach. Die Maskenaffäre ist mir gut in Erinnerung geblieben.", speaker: "3")
        ], partialSegments: [Segment(start: 52.6, end: 55.0, text: "Deswegen muss man mit ihm kein großes")])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sample.wav")
        recorder.update(result: RecordingController.Result(audioURL: url, transcriptURL: nil, transcript: transcript, liveIncomplete: false))
        #endif
    }
}

/// Pulsierender Punkt während der Aufnahme; still bei reduzierter Bewegung.
private struct PulseWhen: ViewModifier {
    var active: Bool
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .opacity(active ? (on ? 0.35 : 1) : 1)
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: on)
            .onChange(of: active, initial: true) { _, isActive in on = isActive }
    }
}

/// Aktionen zum Ergebnis: Hinweis auf Lücken, Nachreichen, Export.
private struct ResultActions: View {
    var result: RecordingController.Result
    var retrying: Bool
    var retryProgress: Double
    var retryError: String?
    var canRetry: Bool
    var onRetry: () -> Void

    private var incompleteText: String {
        if result.missingSegments > 0 {
            return "Live-Übertragung unvollständig, \(result.missingSegments) Abschnitte fehlen. Die Aufnahme ist gesichert."
        }
        return "Live-Übertragung unvollständig. Die Aufnahme ist gesichert."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if result.liveIncomplete {
                Text(incompleteText)
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.amber)
            }
            if retrying {
                ProgressView(value: retryProgress) {
                    Text("Aufnahme wird nachträglich übertragen")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.mist)
                }
                .tint(Theme.mint)
            } else if let retryError {
                Text(retryError)
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.amber)
            }
            HStack(spacing: 10) {
                if canRetry && !retrying {
                    Button("Nachträglich transkribieren", action: onRetry)
                        .buttonStyle(PaperButtonStyle(prominent: true))
                }
                if let transcriptURL = result.transcriptURL {
                    ShareLink(item: transcriptURL) {
                        Label("Mitschrift teilen", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PaperButtonStyle(prominent: false))
                }
                ShareLink(item: result.audioURL) {
                    Label("Audio teilen", systemImage: "waveform")
                }
                .buttonStyle(PaperButtonStyle(prominent: false))
            }
        }
    }
}

/// Ruhige Knöpfe auf dem Blatt: Umriss in Nebel, hervorgehoben in Mint.
struct PaperButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.footnote.weight(.semibold))
            .foregroundStyle(prominent ? Theme.night : Theme.paper)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(prominent ? Theme.mint : Theme.ink)
            )
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : Theme.mist.opacity(0.35)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
