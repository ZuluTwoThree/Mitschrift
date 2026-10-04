import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

@main
struct MitschriftApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 720, minHeight: 610)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

@MainActor
private final class RecorderTranscriber: NSObject, ObservableObject {
    @Published var state: RecordingWorkState = .idle
    @Published var transcript = ""
    @Published var elapsed: TimeInterval = 0
    @Published var language = "de"
    @Published var modelName = "small"

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private var currentAudioURL: URL?

    var isRecording: Bool { state.isRecording }
    var isBusy: Bool { state.isBusy }
    var statusText: String { state.statusText }
    var elapsedText: String { RecordingNaming.elapsedText(elapsed) }

    func toggleRecording() {
        isRecording ? stopRecording() : requestPermissionAndStart()
    }

    private func requestPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    if granted {
                        self?.startRecording()
                    } else {
                        self?.state = .failed("Mikrofonzugriff wurde nicht erlaubt.")
                    }
                }
            }
        default:
            state = .failed("Bitte erlaube den Mikrofonzugriff in Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon.")
        }
    }

    private func startRecording() {
        do {
            let directory = try RecordingsDirectory.url()
            let url = directory.appendingPathComponent(RecordingNaming.recordingFileName(for: Date()))
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: Double(WAVEncoder.sampleRate),
                AVNumberOfChannelsKey: WAVEncoder.channels,
                AVLinearPCMBitDepthKey: WAVEncoder.bitsPerSample,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]

            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            newRecorder.prepareToRecord()
            guard newRecorder.record() else {
                throw NSError(domain: "Mitschrift", code: 1, userInfo: [NSLocalizedDescriptionKey: "Die Aufnahme konnte nicht gestartet werden."])
            }

            recorder = newRecorder
            currentAudioURL = url
            transcript = ""
            elapsed = 0
            startedAt = Date()
            state = .recording
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let startedAt = self.startedAt else { return }
                    self.elapsed = Date().timeIntervalSince(startedAt)
                }
            }
        } catch {
            state = .failed("Aufnahmefehler: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        guard let audioURL = currentAudioURL else {
            state = .failed("Die Aufnahmedatei wurde nicht gefunden.")
            return
        }
        transcribe(audioURL)
    }

    func chooseAudioFile() {
        let panel = NSOpenPanel()
        panel.title = "Audiodatei transkribieren"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        currentAudioURL = url
        transcript = ""
        transcribe(url)
    }

    private func transcribe(_ audioURL: URL) {
        let outputDirectory: URL
        do {
            outputDirectory = try RecordingsDirectory.url()
        } catch {
            state = .failed("Der Mitschrift-Ordner konnte nicht angelegt werden: \(error.localizedDescription)")
            return
        }

        let engine = LocalWhisperEngine(modelName: modelName, outputDirectory: outputDirectory)
        let selectedLanguage = language
        state = .transcribing

        Task { [weak self] in
            do {
                let text = try await engine.transcribe(fileURL: audioURL, language: selectedLanguage)
                self?.transcript = text
                self?.state = .done
            } catch {
                self?.state = .failed("Transkriptionsfehler: \(error.localizedDescription)")
            }
        }
    }

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    func saveTranscriptAs() {
        guard !transcript.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Mitschrift speichern"
        panel.nameFieldStringValue = "Mitschrift.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try transcript.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            state = .failed("Speichern fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    func showRecordings() {
        if let directory = try? RecordingsDirectory.url() {
            NSWorkspace.shared.open(directory)
        }
    }
}

private struct ContentView: View {
    @StateObject private var engine = RecorderTranscriber()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.055, green: 0.075, blue: 0.12), Color(red: 0.10, green: 0.12, blue: 0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                header
                recorderCard
                transcriptCard
            }
            .padding(30)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("Mitschrift")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Gespräche lokal aufnehmen und mit Whisper transkribieren")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 12) {
                Picker("Modell", selection: $engine.modelName) {
                    Text("Small · genauer").tag("small")
                    Text("Base · schneller").tag("base")
                }
                .pickerStyle(.menu)
                .frame(width: 160)

                Picker("Sprache", selection: $engine.language) {
                    Text("Deutsch").tag("de")
                    Text("Automatisch").tag("auto")
                    Text("Englisch").tag("en")
                }
                .pickerStyle(.menu)
                .frame(width: 135)
            }
            .disabled(engine.isRecording || engine.isBusy)
        }
    }

    private var recorderCard: some View {
        HStack(spacing: 22) {
            Button(action: engine.toggleRecording) {
                ZStack {
                    Circle()
                        .fill(engine.isRecording ? Color.red.opacity(0.2) : Color.cyan.opacity(0.16))
                        .frame(width: 86, height: 86)
                    if engine.isRecording {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.red)
                            .frame(width: 32, height: 32)
                    } else {
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 42, height: 42)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(engine.isBusy)
            .help(engine.isRecording ? "Aufnahme stoppen" : "Aufnahme starten")

            VStack(alignment: .leading, spacing: 7) {
                Text(engine.elapsedText)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                HStack(spacing: 8) {
                    if engine.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Circle()
                            .fill(engine.isRecording ? Color.red : Color.green)
                            .frame(width: 8, height: 8)
                    }
                    Text(engine.statusText)
                        .foregroundStyle(engine.state.isFailed ? Color.orange : Color.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                Button("Audiodatei öffnen …", action: engine.chooseAudioFile)
                    .disabled(engine.isRecording || engine.isBusy)
                Button("Aufnahmen anzeigen", action: engine.showRecordings)
                    .buttonStyle(.link)
            }
        }
        .padding(22)
        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.09)))
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Mitschrift", systemImage: "text.alignleft")
                    .font(.headline)
                Spacer()
                Button(action: engine.copyTranscript) {
                    Label("Kopieren", systemImage: "doc.on.doc")
                }
                .disabled(engine.transcript.isEmpty)
                Button(action: engine.saveTranscriptAs) {
                    Label("Speichern …", systemImage: "square.and.arrow.down")
                }
                .disabled(engine.transcript.isEmpty)
            }

            TextEditor(text: $engine.transcript)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    if engine.transcript.isEmpty && !engine.isBusy {
                        Text("Nach dem Stoppen erscheint die Transkription hier.")
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(20)
        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.09)))
        .frame(maxHeight: .infinity)
    }
}
