import Foundation

/// Schreibt und liest WAV-Dateien im Vertragsformat: PCM 16 Bit, mono, 16 kHz.
public enum WAVEncoder {
    public static let sampleRate = 16_000
    public static let channels = 1
    public static let bitsPerSample = 16
    public static let headerSize = 44

    /// Erzeugt eine vollständige WAV-Datei aus Int16-Samples.
    public static func wavData(samples: [Int16], sampleRate: Int = WAVEncoder.sampleRate) -> Data {
        let dataSize = samples.count * MemoryLayout<Int16>.size
        var data = Data(capacity: headerSize + dataSize)
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        data.append(ascii: "RIFF")
        data.append(uint32: UInt32(36 + dataSize))
        data.append(ascii: "WAVE")
        data.append(ascii: "fmt ")
        data.append(uint32: 16)
        data.append(uint16: 1) // PCM
        data.append(uint16: UInt16(channels))
        data.append(uint32: UInt32(sampleRate))
        data.append(uint32: UInt32(byteRate))
        data.append(uint16: UInt16(blockAlign))
        data.append(uint16: UInt16(bitsPerSample))
        data.append(ascii: "data")
        data.append(uint32: UInt32(dataSize))
        samples.withUnsafeBufferPointer { buffer in
            data.append(UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
        }
        return data
    }

    /// Dauer einer Sample-Anzahl in Sekunden.
    public static func duration(sampleCount: Int, sampleRate: Int = WAVEncoder.sampleRate) -> Double {
        Double(sampleCount) / Double(sampleRate)
    }

    /// Abtastrate einer PCM-16-Mono-WAV-Datei, `nil` bei fremdem Format.
    public static func sampleRate(of data: Data) -> Int? {
        parse(data)?.sampleRate
    }

    /// Liest die Samples aus einer PCM-16-Mono-WAV-Datei. Zusätzliche Chunks (z. B. `LIST` von ffmpeg)
    /// werden übersprungen. Liefert `nil` bei anderem Format.
    public static func samples(from data: Data) -> [Int16]? {
        guard let parsed = parse(data) else { return nil }
        let payload = data.subdata(in: parsed.dataRange)
        let count = payload.count / MemoryLayout<Int16>.size
        return payload.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self).prefix(count))
        }
    }

    private struct Parsed {
        var sampleRate: Int
        var dataRange: Range<Int>
    }

    /// Geht die RIFF-Chunks durch und prüft `fmt ` auf PCM, mono, 16 Bit.
    private static func parse(_ data: Data) -> Parsed? {
        guard data.count >= 12,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else { return nil }
        var offset = 12
        var sampleRate: Int?
        while offset + 8 <= data.count {
            let id = String(data: data[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = Int(data.uint32(at: offset + 4))
            let body = offset + 8
            switch id {
            case "fmt ":
                guard body + 16 <= data.count,
                      data.uint16(at: body) == 1,
                      data.uint16(at: body + 2) == UInt16(channels),
                      data.uint16(at: body + 14) == UInt16(bitsPerSample) else { return nil }
                sampleRate = Int(data.uint32(at: body + 4))
            case "data":
                guard let sampleRate else { return nil }
                let end = min(data.count, body + size)
                return Parsed(sampleRate: sampleRate, dataRange: body..<end)
            default:
                break
            }
            offset = body + size + (size % 2) // Chunks sind auf gerade Länge aufgefüllt.
        }
        return nil
    }
}

private extension Data {
    mutating func append(ascii: String) {
        append(contentsOf: Array(ascii.utf8))
    }

    mutating func append(uint32 value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func append(uint16 value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func uint32(at offset: Int) -> UInt32 {
        let slice = self[(startIndex + offset)..<(startIndex + offset + 4)]
        return slice.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    func uint16(at offset: Int) -> UInt16 {
        let slice = self[(startIndex + offset)..<(startIndex + offset + 2)]
        return slice.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) }
    }
}
