import Foundation

/// Schreibt PCM-Samples fortlaufend in eine WAV-Datei; der Header wird beim Schließen vervollständigt.
///
/// Nach einem Absturz bleibt eine Datei mit Platzhalter-Header zurück; `repairHeader` setzt die Längen nach.
public final class WAVFileWriter {
    public let url: URL
    public let sampleRate: Int
    private let handle: FileHandle
    private var sampleCount = 0
    private var closed = false

    public init(url: URL, sampleRate: Int = WAVEncoder.sampleRate) throws {
        self.url = url
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: WAVEncoder.wavData(samples: [], sampleRate: sampleRate))
    }

    public var durationSeconds: Double {
        WAVEncoder.duration(sampleCount: sampleCount, sampleRate: sampleRate)
    }

    public func append(_ samples: [Int16]) throws {
        guard !closed, !samples.isEmpty else { return }
        try samples.withUnsafeBufferPointer { buffer in
            try handle.write(contentsOf: Data(buffer: buffer))
        }
        sampleCount += samples.count
    }

    /// Schreibt die endgültigen Längen in den Header und schließt die Datei.
    public func close() throws {
        guard !closed else { return }
        closed = true
        try Self.writeLengths(handle: handle, sampleCount: sampleCount)
        try handle.close()
    }

    /// Setzt die Längenfelder einer unvollständig geschlossenen Datei anhand der Dateigröße.
    public static func repairHeader(at url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        guard size >= WAVEncoder.headerSize else { return }
        try writeLengths(handle: handle, sampleCount: (size - WAVEncoder.headerSize) / 2)
    }

    private static func writeLengths(handle: FileHandle, sampleCount: Int) throws {
        let dataSize = UInt32(sampleCount * 2)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Self.littleEndian(36 + dataSize))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Self.littleEndian(dataSize))
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }
}
