import Foundation

/// Schneidet einen fortlaufenden Int16-Strom in Segmente nach Vertrag: 2,5 s lang, 300 ms Überlappung.
///
/// Der Aufrufer liefert Samples in beliebigen Blöcken; sobald ein Segment voll ist, wird es als WAV
/// ausgegeben. Die letzten `overlap` Samples bleiben für das nächste Segment erhalten.
public struct SegmentBuilder: Sendable {
    public let segmentSamples: Int
    public let overlapSamples: Int
    public let sampleRate: Int

    private var buffer: [Int16] = []
    private var emittedSegments = 0

    public init(
        segmentSeconds: Double = 2.5,
        overlapSeconds: Double = 0.3,
        sampleRate: Int = WAVEncoder.sampleRate
    ) {
        precondition(segmentSeconds > 0 && overlapSeconds >= 0 && overlapSeconds < segmentSeconds)
        self.sampleRate = sampleRate
        self.segmentSamples = Int(segmentSeconds * Double(sampleRate))
        self.overlapSamples = Int(overlapSeconds * Double(sampleRate))
    }

    /// Zahl der bisher ausgegebenen Segmente.
    public var count: Int { emittedSegments }

    /// Samples, die noch auf ein volles Segment warten (ohne Überlappungsanteil).
    public var pendingSeconds: Double {
        Double(max(0, buffer.count - (emittedSegments > 0 ? overlapSamples : 0))) / Double(sampleRate)
    }

    /// Nimmt Samples auf und liefert alle dadurch fertig gewordenen Segmente als WAV-Daten.
    public mutating func append(_ samples: [Int16]) -> [Data] {
        buffer.append(contentsOf: samples)
        var output: [Data] = []
        while buffer.count >= segmentSamples {
            let segment = Array(buffer.prefix(segmentSamples))
            output.append(WAVEncoder.wavData(samples: segment, sampleRate: sampleRate))
            emittedSegments += 1
            buffer.removeFirst(segmentSamples - overlapSamples)
        }
        return output
    }

    /// Gibt den Rest als letztes, kürzeres Segment aus, sofern er über der Mindestlänge liegt.
    /// Reiner Überlappungsanteil ohne neues Audio wird verworfen.
    public mutating func flush(minimumSeconds: Double = 1.0) -> Data? {
        defer { buffer.removeAll(); }
        let newSamples = buffer.count - (emittedSegments > 0 ? overlapSamples : 0)
        guard newSamples > 0 else { return nil }
        let minimum = Int(minimumSeconds * Double(sampleRate))
        var segment = buffer
        if segment.count < minimum {
            // Mit Stille auffüllen, damit der Server das Segment nicht als zu kurz ablehnt.
            segment.append(contentsOf: [Int16](repeating: 0, count: minimum - segment.count))
        }
        emittedSegments += 1
        return WAVEncoder.wavData(samples: segment, sampleRate: sampleRate)
    }
}
