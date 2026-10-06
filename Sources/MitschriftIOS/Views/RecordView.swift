import SwiftUI
import MitschriftCore

/// Hauptansicht: Statusleiste, Protokollblatt und Transportleiste. Einstellungen und die Liste der
/// Aufnahmen liegen als Blätter darüber.
struct RecordView: View {
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: RecordingLibraryModel
    @State private var showPrivacyNotice = false
    @State private var showSettings = false
    @State private var showRecordings = false
    /// Die zuletzt beendete Aufnahme mit ihren Aktionen.
    @State private var current: OpenRecording?
    /// Ergebnis der Erreichbarkeitsprüfung beim Start einer Live-Aufnahme.
    @State private var reachabilityHint: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 8)
            paper
                .padding(.horizontal, Theme.gutter)
            if let current, !recorder.state.isRecording, recorder.state != .stopping {
                RecordingPanel(recording: current)
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
        .sheet(isPresented: $showRecordings) {
            RecordingsListView()
                .environmentObject(library)
                .environmentObject(settings)
        }
        .onChange(of: recorder.result) { _, result in
            syncCurrent(with: result)
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
                headerButton("list.bullet.rectangle", label: "Aufnahmen") { showRecordings = true }
                headerButton("server.rack", label: "Server einstellen") { showSettings = true }
                    .disabled(recorder.state.isRecording)
            }
            Text(serverText)
                .font(Theme.Fonts.footnote)
                .foregroundStyle(reachabilityHint != nil && recorder.state.isRecording ? Theme.amber : Theme.mist)
        }
    }

    private func headerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.mist)
                .frame(width: 36, height: 36)
                .background(Theme.ink, in: Circle())
        }
        .accessibilityLabel(label)
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
            if let reachabilityHint, recorder.state.isRecording { return reachabilityHint }
            return "Live über \(name), \(recorder.segmentCount) Abschnitte gesendet"
        }
        if let current, current.item.audioURL.pathExtension == "wav", recorder.result?.compressing == true {
            return "Aufnahme wird komprimiert …"
        }
        return "Live über \(name)"
    }

    // MARK: Blatt

    @ViewBuilder
    private var paper: some View {
        if let session = recorder.liveSession, recorder.state.isRecording || recorder.state == .stopping {
            LiveTranscriptView(session: session)
        } else if let current {
            TranscriptPaper(transcript: current.transcript, emptyText: "Keine Mitschrift entstanden. Die Aufnahme ist gespeichert.")
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
        .disabled(recorder.state == .stopping || current?.isBusy == true)
        .opacity(recorder.state == .stopping || current?.isBusy == true ? 0.5 : 1)
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
        reachabilityHint = nil
        let endpoint = settings.endpoint
        await recorder.start(endpoint: endpoint, language: settings.language)
        if let endpoint, recorder.state.isRecording {
            Task { await checkReachability(endpoint) }
        }
    }

    /// Prüft beim Start, ob der Server antwortet. Die Aufnahme läuft unabhängig davon; der Hinweis soll
    /// nur verhindern, dass ein vergessenes Tailscale erst nach einer halben Stunde auffällt.
    private func checkReachability(_ endpoint: ServerEndpoint) async {
        let transport = URLSessionLiveTransport(endpoint: endpoint)
        do {
            let health = try await transport.health()
            reachabilityHint = health.isHealthy ? nil : "Server antwortet, Modell lädt noch. Die Aufnahme wird gesichert und später übertragen."
        } catch let error as LiveTranscriptionError {
            switch error {
            case .transport:
                reachabilityHint = "Server nicht erreichbar, ist Tailscale auf dem iPhone an? Die Aufnahme wird gesichert, die Übertragung versucht es weiter."
            case .unauthorized:
                reachabilityHint = "Der Server lehnt den Zugangscode ab. Die Aufnahme wird gesichert."
            default:
                reachabilityHint = error.userMessage
            }
        } catch {
            reachabilityHint = error.localizedDescription
        }
    }

    /// Hält das Aufnahme-Objekt der Hauptansicht mit dem Ergebnis des Controllers in Deckung.
    private func syncCurrent(with result: RecordingController.Result?) {
        guard let result else { current = nil; return }
        let id = RecordingNaming.baseName(result.audioURL.lastPathComponent)
        if let current, current.id == id {
            if current.item.audioURL != result.audioURL { current.audioMoved(to: result.audioURL) }
            current.audioLocked = result.compressing
            if !result.compressing { library.reload() }
            return
        }
        let directory = result.audioURL.deletingLastPathComponent()
        let library = RecordingLibrary(directory: directory)
        var item = library.items().first { $0.id == id }
            ?? RecordingItem(audioURL: result.audioURL, createdAt: result.createdAt, fileSize: 0)
        item.createdAt = result.createdAt
        current = OpenRecording(item: item, transcript: result.transcript, language: result.language,
                                incomplete: result.liveIncomplete, missingSegments: result.missingSegments, library: library)
        current?.audioLocked = result.compressing
        self.library.reload()
    }

    /// Nur für Gestaltungs-Screenshots im Simulator: `SIMCTL_CHILD_MITSCHRIFT_DEV_SAMPLE=1`.
    private func seedSampleIfRequested() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MITSCHRIFT_DEV_SHOW_SETTINGS"] == "1" { showSettings = true }
        if let flag = ProcessInfo.processInfo.environment["MITSCHRIFT_DEV_SHOW_RECORDINGS"], !flag.isEmpty { showRecordings = true }
        guard ProcessInfo.processInfo.environment["MITSCHRIFT_DEV_SAMPLE"] == "1", recorder.result == nil else { return }
        let transcript = Transcript(finalSegments: [
            Segment(start: 0, end: 1.6, text: "Und es rührt an die Grundfesten auch der Union.", speaker: "1"),
            Segment(start: 1.9, end: 13.4, text: "Ja, wir haben die Form, wir haben das Thema. Er selbst hat eine Erklärung abgegeben am Samstag, kleiner Ausschnitt daraus, von dem, was Jens Spahn seiner Fraktion geschrieben hat.", speaker: "2"),
            Segment(start: 13.5, end: 29.8, text: "Die zunehmende Unerbittlichkeit in der öffentlichen Auseinandersetzung hat mich sehr nachdenklich gemacht. Lasst uns doch bei aller Klarheit und Entschiedenheit in der Sache immer im Ton auch menschlich bleiben.", speaker: "2"),
            Segment(start: 30.4, end: 37.0, text: "Herr Neubacher, spricht Ihnen das ein bisschen aus dem Herzen?", speaker: "1"),
            Segment(start: 37.2, end: 52.4, text: "Ja, also Jens Spahn hätte viele Gründe gehabt, zurückzutreten, meiner Ansicht nach. Die Maskenaffäre ist mir gut in Erinnerung geblieben.", speaker: "3")
        ], partialSegments: [Segment(start: 52.6, end: 55.0, text: "Deswegen muss man mit ihm kein großes")])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Gespräch-2026-10-04_09-30-00.wav")
        try? WAVEncoder.wavData(samples: Array(repeating: 0, count: 16_000)).write(to: url)
        recorder.update(result: RecordingController.Result(audioURL: url, createdAt: Date(), language: "de", transcript: transcript, liveIncomplete: false))
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
