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

/// Kürzt eine gespeicherte Aufnahme nach einem `AudioCutPlan`: Anfang und Ende fallen weg, Bereiche
/// dazwischen werden still. Die Datei behält Namen und Format (M4A bleibt AAC 48 kbit/s, WAV bleibt
/// PCM), damit Mitschrift und Protokoll daneben weiter zur Aufnahme passen. Das Original wird erst
/// ersetzt, wenn die neue Datei vollständig lesbar ist.
enum AudioEditor {
    enum Failure: LocalizedError {
        case unreadable
        case writeFailed
        case nothingLeft

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Die Aufnahmedatei konnte nicht gelesen werden."
            case .writeFailed: return "Die gekürzte Aufnahme konnte nicht geschrieben werden."
            case .nothingLeft: return "Nach dem Kürzen bliebe von der Aufnahme nichts übrig."
            }
        }
    }

    static func apply(_ plan: AudioCutPlan, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try applySync(plan, to: url)
        }.value
    }

    private static func applySync(_ plan: AudioCutPlan, to url: URL) throws {
        guard !plan.isEmpty else { return }
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
            .appendingPathComponent("schnitt-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        defer { try? fileManager.removeItem(at: temporary) }
        try write(plan, from: url, to: temporary)
        guard let written = AudioFileReader.duration(of: temporary), written > 0 else { throw Failure.writeFailed }
        _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
    }

    /// Eigene Funktion, damit die Ausgabedatei beim Rücksprung geschlossen und finalisiert ist.
    private static func write(_ plan: AudioCutPlan, from sourceURL: URL, to targetURL: URL) throws {
        guard let input = try? AVAudioFile(forReading: sourceURL) else { throw Failure.unreadable }
        let format = input.processingFormat
        let rate = format.sampleRate
        func frame(_ seconds: Double) -> AVAudioFramePosition {
            min(input.length, max(0, AVAudioFramePosition((seconds * rate).rounded())))
        }
        let first = frame(plan.leadingCut)
        let last = plan.end.map(frame) ?? input.length
        guard last > first else { throw Failure.nothingLeft }
        let muted = plan.muted.map { frame($0.lowerBound)..<frame($0.upperBound) }

        let settings: [String: Any]
        if sourceURL.pathExtension.lowercased() == "m4a" {
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: Int(format.channelCount),
                AVEncoderBitRateKey: AudioArchiver.bitRate,
            ]
        } else {
            settings = input.fileFormat.settings
        }
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: targetURL, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        } catch {
            throw Failure.writeFailed
        }

        input.framePosition = first
        let capacity: AVAudioFrameCount = 32_768
        while input.framePosition < last {
            let start = input.framePosition
            let count = AVAudioFrameCount(min(AVAudioFramePosition(capacity), last - start))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { throw Failure.writeFailed }
            try input.read(into: buffer, frameCount: count)
            if buffer.frameLength == 0 { break }
            let chunk = start..<(start + AVAudioFramePosition(buffer.frameLength))
            for range in muted where range.overlaps(chunk) {
                let lower = Int(max(range.lowerBound, chunk.lowerBound) - start)
                let upper = Int(min(range.upperBound, chunk.upperBound) - start)
                silence(buffer, from: lower, to: upper)
            }
            try output.write(from: buffer)
        }
    }

    /// Setzt die Frames `lower..<upper` aller Kanäle auf Stille.
    private static func silence(_ buffer: AVAudioPCMBuffer, from lower: Int, to upper: Int) {
        guard upper > lower else { return }
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let stride = interleaved ? channels : 1
        let planes = interleaved ? 1 : channels
        let start = lower * stride
        let count = (upper - lower) * stride
        if let data = buffer.floatChannelData {
            for plane in 0..<planes { (data[plane] + start).update(repeating: 0, count: count) }
        } else if let data = buffer.int16ChannelData {
            for plane in 0..<planes { (data[plane] + start).update(repeating: 0, count: count) }
        } else if let data = buffer.int32ChannelData {
            for plane in 0..<planes { (data[plane] + start).update(repeating: 0, count: count) }
        }
    }
}
