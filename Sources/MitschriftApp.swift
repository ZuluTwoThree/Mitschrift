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

private enum WorkState: Equatable {
    case idle
    case recording
    case transcribing
    case done
    case failed(String)
}

@MainActor
private final class RecorderTranscriber: NSObject, ObservableObject {
    @Published var state: WorkState = .idle
    @Published var transcript = ""
    @Published var elapsed: TimeInterval = 0
    @Published var language = "de"
    @Published var modelName = "small"

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private var currentAudioURL: URL?

    var isRecording: Bool { state == .recording }
    var isBusy: Bool { state == .transcribing }

    var statusText: String {
        switch state {
        case .idle: return "Bereit für eine neue Aufnahme"
        case .recording: return "Aufnahme läuft"
        case .transcribing: return "Whisper erstellt die Mitschrift …"
        case .done: return "Mitschrift fertig und automatisch gespeichert"
        case .failed(let message): return message
        }
    }

    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

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
            let directory = try recordingsDirectory()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "de_DE")
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let url = directory.appendingPathComponent("Gespräch-\(formatter.string(from: Date())).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
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
        guard let executable = whisperExecutable() else {
            state = .failed("Die lokale Whisper-Engine wurde nicht gefunden. Bitte installiere whisper.cpp mit Homebrew.")
            return
        }
        guard let model = modelURL(named: modelName) else {
            state = .failed("Das gewählte Whisper-Sprachmodell fehlt im App-Paket.")
            return
        }

        let nativeFormats = Set(["wav", "mp3", "flac", "ogg"])
        let needsConversion = !nativeFormats.contains(audioURL.pathExtension.lowercased())
        let converter = needsConversion ? ffmpegExecutable() : nil
        if needsConversion && converter == nil {
            state = .failed("Für M4A-Dateien wird FFmpeg benötigt. Bitte installiere es mit Homebrew.")
            return
        }

        let outputURL: URL
        do {
            let directory = try recordingsDirectory()
            let sourceName = audioURL.deletingPathExtension().lastPathComponent
            outputURL = directory.appendingPathComponent("\(sourceName)-Mitschrift.txt")
        } catch {
            state = .failed("Der Mitschrift-Ordner konnte nicht angelegt werden: \(error.localizedDescription)")
            return
        }

        state = .transcribing
        let outputPrefix = outputURL.deletingPathExtension().path
        try? FileManager.default.removeItem(at: outputURL)
        let selectedLanguage = language

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var temporaryAudioURL: URL?
            do {
                let whisperInput: URL
                if let converter {
                    let converted = FileManager.default.temporaryDirectory
                        .appendingPathComponent("Mitschrift-\(UUID().uuidString).wav")
                    temporaryAudioURL = converted
                    try Self.runProcess(
                        executable: converter,
                        arguments: [
                            "-y", "-hide_banner", "-loglevel", "error",
                            "-i", audioURL.path,
                            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                            converted.path
                        ],
                        failureMessage: "Die Audiodatei konnte nicht in WAV umgewandelt werden."
                    )
                    whisperInput = converted
                } else {
                    whisperInput = audioURL
                }

                try Self.runProcess(
                    executable: executable,
                    arguments: [
                        "-m", model.path,
                        "-f", whisperInput.path,
                        "-l", selectedLanguage,
                        "-otxt", "-of", outputPrefix,
                        "-nt", "-np", "-ng"
                    ],
                    failureMessage: "Whisper konnte die Audiodatei nicht transkribieren."
                )

                let text = try String(contentsOf: outputURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let temporaryAudioURL {
                    try? FileManager.default.removeItem(at: temporaryAudioURL)
                }
                Task { @MainActor in
                    self?.transcript = text
                    self?.state = .done
                }
            } catch {
                if let temporaryAudioURL {
                    try? FileManager.default.removeItem(at: temporaryAudioURL)
                }
                Task { @MainActor in
                    self?.state = .failed("Transkriptionsfehler: \(error.localizedDescription)")
                }
            }
        }
    }

    nonisolated private static func runProcess(
        executable: URL,
        arguments: [String],
        failureMessage: String
    ) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let diagnostics = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(
                domain: "Mitschrift",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: diagnostics.isEmpty ? failureMessage : "\(failureMessage)\n\(diagnostics)"]
            )
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
        if let directory = try? recordingsDirectory() {
            NSWorkspace.shared.open(directory)
        }
    }

    private func recordingsDirectory() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Mitschrift", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func whisperExecutable() -> URL? {
        let candidates = [
            Bundle.main.url(forResource: "whisper-cli", withExtension: nil, subdirectory: "bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"),
            URL(fileURLWithPath: "/usr/local/bin/whisper-cli")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func ffmpegExecutable() -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func modelURL(named name: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: "ggml-\(name)", withExtension: "bin", subdirectory: "models") {
            return bundled
        }
        return nil
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
                        .foregroundStyle(statusColor)
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

    private var statusColor: Color {
        if case .failed = engine.state { return .orange }
        return .secondary
    }
}
