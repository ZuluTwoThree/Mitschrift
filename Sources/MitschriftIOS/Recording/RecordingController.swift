import Foundation
import Combine
import MitschriftCore

/// Zustand der iOS-Aufnahme: Berechtigung, Start/Stopp, Dauer, lokale WAV-Datei, Segmentbildung.
///
/// In WP4 landet das Audio nur in `Documents/Mitschrift`; die fertigen Segmente werden gezählt.
/// WP5 reicht sie an `LiveTranscriptionSession` weiter.
@MainActor
final class RecordingController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case interrupted
        case stopping
        case finished(fileName: String)
        case failed(String)

        var isRecording: Bool { self == .recording || self == .interrupted }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var segmentCount = 0
    @Published private(set) var permissionDenied = false

    var elapsedText: String { RecordingNaming.elapsedText(elapsed) }

    /// Wird für jedes fertige Segment (WAV-Daten) aufgerufen, auf dem Main-Actor.
    var onSegment: ((Data) -> Void)?

    private let capture = AudioCaptureEngine()
    private let sampleQueue = DispatchQueue(label: "mitschrift.samples")
    private let sink = SampleSink()
    private var timer: Timer?
    private var startedAt: Date?

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

    func toggle() async {
        if state.isRecording {
            await stop()
        } else {
            await start()
        }
    }

    func start() async {
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
            segmentCount = 0
            elapsed = 0
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
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        guard state.isRecording else { return }
        state = .stopping
        timer?.invalidate()
        timer = nil
        capture.stop()
        let sink = self.sink
        let (fileName, rest) = sampleQueue.sync { sink.finish() }
        if let rest {
            deliver([rest])
        }
        state = .finished(fileName: fileName)
    }

    private func deliver(_ segments: [Data]) {
        for segment in segments {
            segmentCount += 1
            onSegment?(segment)
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

    func finish() -> (fileName: String, rest: Data?) {
        let rest = builder.flush()
        let name = writer?.url.lastPathComponent ?? ""
        try? writer?.close()
        writer = nil
        return (name, rest)
    }
}
