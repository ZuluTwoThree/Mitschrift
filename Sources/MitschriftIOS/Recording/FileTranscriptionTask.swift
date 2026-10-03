import Foundation
import Combine
import MitschriftCore

/// Überträgt eine gespeicherte WAV-Datei nachträglich segmentweise an den Server.
///
/// Für Aufnahmen, deren Live-Übertragung pausiert oder fehlgeschlagen ist. Nutzt dieselbe Session-Logik
/// wie die Live-Aufnahme, nur mit Audio aus der Datei statt vom Mikrofon.
@MainActor
final class FileTranscriptionTask: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var session: LiveTranscriptionSession?
    @Published private(set) var error: String?

    func run(audioURL: URL, endpoint: ServerEndpoint, language: String) async -> Transcript? {
        error = nil
        progress = 0
        guard let data = try? Data(contentsOf: audioURL), let samples = WAVEncoder.samples(from: data) else {
            error = "Die Aufnahmedatei konnte nicht gelesen werden."
            return nil
        }
        let session = LiveTranscriptionSession(transport: URLSessionLiveTransport(endpoint: endpoint), language: language)
        self.session = session

        var builder = SegmentBuilder()
        let chunk = WAVEncoder.sampleRate // 1 s pro Durchlauf, damit die Anzeige mitkommt
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunk, samples.count)
            for segment in builder.append(Array(samples[offset..<end])) {
                // Warteschlange begrenzt: warten, bis wieder Platz ist.
                while session.submit(wavData: segment) == nil, session.isActive {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                guard session.isActive else { break }
            }
            offset = end
            progress = Double(offset) / Double(samples.count)
            guard session.isActive else { break }
        }
        if let rest = builder.flush() {
            session.submit(wavData: rest)
        }
        await session.finish()
        if case .failed(let message) = session.status {
            error = message
            return nil
        }
        progress = 1
        return session.transcript
    }
}
