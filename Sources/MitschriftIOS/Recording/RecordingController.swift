import Foundation
import Combine
import MitschriftCore

/// Zustand der iOS-Aufnahme: Berechtigung, Start/Stopp, Dauer, lokale WAV-Datei, Segmentbildung
/// und, falls ein Server eingerichtet ist, die Live-Übertragung über `LiveTranscriptionSession`.
/// Nach dem Stopp wird die WAV-Datei im Hintergrund in AAC umgewandelt (`AudioArchiver`).
@MainActor
final class RecordingController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case interrupted
        case stopping
        case finished
        case failed(String)

        var isRecording: Bool { self == .recording || self == .interrupted }
    }

    struct Result: Equatable {
        var audioURL: URL
        var createdAt: Date
        var language: String
        var transcript: Transcript
        var liveIncomplete: Bool
        /// Segmente, die lokal nicht eingereiht oder vom Server abgelehnt wurden.
        var missingSegments: Int = 0
        /// Die Umwandlung der WAV-Datei in AAC läuft noch.
        var compressing = false
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var segmentCount = 0
    @Published private(set) var permissionDenied = false
    @Published private(set) var liveSession: LiveTranscriptionSession?
    @Published private(set) var result: Result?
    /// Segmente, die wegen voller Warteschlange nicht eingereiht werden konnten. Audio bleibt in der Datei.
    @Published private(set) var lostSegments = 0

    var elapsedText: String { RecordingNaming.elapsedText(elapsed) }

    private let capture = AudioCaptureEngine()
    private let sampleQueue = DispatchQueue(label: "mitschrift.samples")
    private let sink = SampleSink()
    private var timer: Timer?
    private var startedAt: Date?
    private var audioURL: URL?
    private var language = "de"

    init() {
        let sink = self.sink
        let queue = self.sampleQueue
        capture.onSamples = { [weak self] samples in
            queue.async {
                let (segments, writeError) = sink.consume(samples)
                if let writeError {
                    Task { @MainActor in self?.fail("Die Aufnahme konnte nicht gespeichert werden: \(writeError.localizedDescription)") }
                    return
                }
                guard !segments.isEmpty else { return }
                Task { @MainActor in self?.deliver(segments) }
            }
        }
        capture.onInterruption = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        capture.onFailure = { [weak self] error in
            Task { @MainActor in self?.fail("Die Aufnahme wurde abgebrochen: \(error.localizedDescription)") }
        }
    }

    /// Bricht eine laufende Aufnahme mit sichtbarem Fehler ab. Bereits geschriebenes Audio bleibt erhalten.
    private func fail(_ message: String) {
        guard state.isRecording else { return }
        timer?.invalidate()
        timer = nil
        capture.stop()
        let sink = self.sink
        _ = sampleQueue.sync { sink.finish() }
        state = .failed(message)
    }

    /// Startet die Aufnahme. Mit `endpoint` läuft parallel die Live-Übertragung.
    func start(endpoint: ServerEndpoint?, language: String) async {
        guard !state.isRecording else { return }
        if AudioCaptureEngine.permissionStatus != .granted {
            let granted = await AudioCaptureEngine.requestPermission()
            guard granted else {
                permissionDenied = true
                state = .failed("Mikrofonzugriff wurde nicht erlaubt. Bitte in den Einstellungen freigeben.")
                return
            }
        }
        permissionDenied = false
        do {
            let directory = try RecordingsDirectory.url()
            let url = directory.appendingPathComponent(RecordingNaming.recordingFileName(for: Date()))
            let newWriter = try WAVFileWriter(url: url)
            let sink = self.sink
            sampleQueue.sync { sink.begin(writer: newWriter) }
            audioURL = url
            self.language = language
            result = nil
            segmentCount = 0
            lostSegments = 0
            elapsed = 0
            liveSession = endpoint.map { endpoint in
                LiveTranscriptionSession(transport: URLSessionLiveTransport(endpoint: endpoint), language: language)
            }
            try capture.start()
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
            liveSession = nil
            state = .failed(error.localizedDescription)
        }
    }

    /// Stoppt die Aufnahme, wartet auf den Server und speichert Audio und Mitschrift.
    func stop() async {
        guard state.isRecording else { return }
        state = .stopping
        timer?.invalidate()
        timer = nil
        capture.stop()
        let sink = self.sink
        let rest = sampleQueue.sync { sink.finish() }
        if let rest {
            deliver([rest])
        }

        var transcript = Transcript()
        var incomplete = false
        if let session = liveSession {
            await session.finish()
            transcript = session.transcript
            // Unvollständig, wenn die Session nicht sauber endete, Segmente lokal verworfen wurden
            // (Warteschlange voll) oder der Server einzelne Segmente abgelehnt hat (400/413).
            if case .finished = session.status {} else { incomplete = true }
            if lostSegments > 0 || session.droppedCount > 0 { incomplete = true }
        }

        guard let audioURL else {
            state = .failed("Die Aufnahmedatei wurde nicht gefunden.")
            return
        }
        let missing = lostSegments + (liveSession?.droppedCount ?? 0)
        let createdAt = startedAt ?? Date()
        if !transcript.isEmpty {
            let document = TranscriptDocument(createdAt: createdAt, language: language, transcript: transcript, incomplete: incomplete, missingSegments: missing)
            let library = RecordingLibrary(directory: audioURL.deletingLastPathComponent())
            if (try? library.save(document, forAudio: audioURL)) == nil {
                incomplete = true
            }
        }
        result = Result(audioURL: audioURL, createdAt: createdAt, language: language, transcript: transcript,
                        liveIncomplete: incomplete, missingSegments: missing, compressing: true)
        state = .finished
        Task { await compress(wavURL: audioURL) }
    }

    /// Wandelt die WAV-Datei nach dem Stopp in AAC um. Scheitert das, bleibt die WAV-Datei bestehen.
    private func compress(wavURL: URL) async {
        let compressed = try? await AudioArchiver.compress(wavURL: wavURL)
        guard var current = result, current.audioURL == wavURL else { return }
        current.compressing = false
        if let compressed { current.audioURL = compressed }
        result = current
    }

    /// Ersetzt das Ergebnis, etwa für Gestaltungs-Vorschauen.
    func update(result: Result) {
        self.result = result
    }

    private func deliver(_ segments: [Data]) {
        for segment in segments {
            segmentCount += 1
            guard let liveSession else { continue }
            if liveSession.submit(wavData: segment) == nil {
                // Warteschlange voll oder Session beendet: Das Audio ist in der WAV-Datei gesichert und
                // kann nachträglich übertragen werden; das Ergebnis wird als unvollständig markiert.
                lostSegments += 1
            }
        }
    }

    private func handle(_ event: AudioCaptureEngine.InterruptionEvent) {
        switch event {
        case .began:
            if state == .recording { state = .interrupted }
        case .ended(let shouldResume):
            guard state == .interrupted else { return }
            if shouldResume, (try? capture.resume()) != nil {
                state = .recording
            } else {
                Task { await stop() }
            }
        }
    }
}

/// Besitzt Datei-Writer und Segment-Builder. Wird ausschließlich auf der Sample-Queue benutzt.
private final class SampleSink: @unchecked Sendable {
    private var writer: WAVFileWriter?
    private var builder = SegmentBuilder()

    func begin(writer: WAVFileWriter) {
        self.writer = writer
        builder = SegmentBuilder()
        failed = false
    }

    private var failed = false

    /// Liefert fertige Segmente und, falls das Schreiben scheitert, den Fehler. Nach einem Fehler wird
    /// nicht weiter geschrieben, damit der Fehler nur einmal gemeldet wird.
    func consume(_ samples: [Int16]) -> (segments: [Data], error: Error?) {
        guard !failed else { return ([], nil) }
        do {
            try writer?.append(samples)
        } catch {
            failed = true
            return ([], error)
        }
        return (builder.append(samples), nil)
    }

    func finish() -> Data? {
        let rest = builder.flush()
        try? writer?.close()
        writer = nil
        return rest
    }
}
