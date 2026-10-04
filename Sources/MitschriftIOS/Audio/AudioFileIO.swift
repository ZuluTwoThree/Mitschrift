import Foundation
import AVFoundation
import MitschriftCore

/// Liest beliebige von AVFoundation unterstützte Audiodateien (WAV, M4A, CAF …) als 16 kHz mono Int16.
enum AudioFileReader {
    enum Failure: LocalizedError {
        case unreadable
        case conversion

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Die Aufnahmedatei konnte nicht gelesen werden."
            case .conversion: return "Die Aufnahmedatei konnte nicht in 16 kHz mono umgewandelt werden."
            }
        }
    }

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(WAVEncoder.sampleRate),
        channels: AVAudioChannelCount(WAVEncoder.channels),
        interleaved: true
    )!

    static func samples(from url: URL) throws -> [Int16] {
        // Vertragsformat direkt lesen, ohne AVFoundation: schneller und unabhängig von Metadaten-Chunks.
        if url.pathExtension.lowercased() == "wav", let data = try? Data(contentsOf: url),
           WAVEncoder.sampleRate(of: data) == WAVEncoder.sampleRate, let samples = WAVEncoder.samples(from: data) {
            return samples
        }
        guard let file = try? AVAudioFile(forReading: url) else { throw Failure.unreadable }
        let source = file.processingFormat
        guard let converter = AVAudioConverter(from: source, to: targetFormat) else { throw Failure.conversion }
        let frameCapacity: AVAudioFrameCount = 16_384
        var result: [Int16] = []
        result.reserveCapacity(Int(Double(file.length) * targetFormat.sampleRate / source.sampleRate) + 1)
        var finished = false
        while !finished {
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { throw Failure.conversion }
            var readError: NSError?
            var endOfFile = false
            let status = converter.convert(to: output, error: &readError) { count, outStatus in
                // Am Dateiende wirft read(into:) eofErr, deshalb vorher die verbleibenden Frames prüfen.
                let remaining = file.length - file.framePosition
                guard remaining > 0, let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: min(count, AVAudioFrameCount(remaining))) else {
                    outStatus.pointee = .endOfStream
                    endOfFile = true
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: input.frameCapacity)
                } catch {
                    outStatus.pointee = .endOfStream
                    endOfFile = true
                    return nil
                }
                if input.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    endOfFile = true
                    return nil
                }
                outStatus.pointee = .haveData
                return input
            }
            if status == .error { throw readError ?? Failure.conversion }
            if output.frameLength > 0, let channel = output.int16ChannelData {
                result.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
            }
            finished = status == .endOfStream || (endOfFile && output.frameLength == 0)
        }
        return result
    }

    /// Dauer einer Audiodatei in Sekunden, `nil` wenn unlesbar.
    static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

/// Wandelt die während der Aufnahme geschriebene WAV-Datei (PCM, 115 MB je Stunde) nach dem Stopp in
/// AAC um (`.m4a`, 48 kbit/s mono, rund 22 MB je Stunde). Die WAV-Datei bleibt bis zum Erfolg bestehen,
/// damit ein Absturz während der Umwandlung kein Audio kostet.
enum AudioArchiver {
    static let bitRate = 48_000

    enum Failure: LocalizedError {
        case encoderUnavailable
        var errorDescription: String? { "Der AAC-Encoder ist nicht verfügbar." }
    }

    /// Erzeugt `…​.m4a` neben der WAV-Datei und löscht diese danach. Liefert die neue URL.
    static func compress(wavURL: URL) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try compressSync(wavURL: wavURL)
        }.value
    }

    private static func compressSync(wavURL: URL) throws -> URL {
        let targetURL = wavURL.deletingPathExtension().appendingPathExtension("m4a")
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: targetURL.path) { try fileManager.removeItem(at: targetURL) }
        do {
            try encode(from: wavURL, to: targetURL)
        } catch {
            try? fileManager.removeItem(at: targetURL)
            throw error
        }
        // Erst prüfen, dass die Ausgabe vollständig ist, dann das Original entfernen.
        guard let written = AudioFileReader.duration(of: targetURL), written > 0 else {
            try? fileManager.removeItem(at: targetURL)
            throw Failure.encoderUnavailable
        }
        try fileManager.removeItem(at: wavURL)
        return targetURL
    }

    /// Eigene Funktion, damit die Ausgabedatei beim Rücksprung geschlossen und finalisiert ist, bevor
    /// sie geprüft wird (`AVAudioFile` schreibt den Container-Kopf erst beim Freigeben).
    private static func encode(from wavURL: URL, to targetURL: URL) throws {
        let input = try AVAudioFile(forReading: wavURL)
        let source = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: source.sampleRate,
            AVNumberOfChannelsKey: Int(source.channelCount),
            AVEncoderBitRateKey: bitRate,
        ]
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: targetURL, settings: settings, commonFormat: source.commonFormat, interleaved: source.isInterleaved)
        } catch {
            throw Failure.encoderUnavailable
        }
        let capacity: AVAudioFrameCount = 32_768
        while input.framePosition < input.length {
            let remaining = AVAudioFrameCount(input.length - input.framePosition)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: min(capacity, remaining)) else { throw Failure.encoderUnavailable }
            try input.read(into: buffer, frameCount: buffer.frameCapacity)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }
}
