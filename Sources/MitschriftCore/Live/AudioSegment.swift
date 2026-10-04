import Foundation

/// Ein Audioabschnitt, der an den Server geschickt wird. `data` ist eine vollständige WAV-Datei.
public struct AudioSegment: Equatable, Sendable {
    public var sequence: Int
    public var data: Data
    public var capturedAt: Date

    public init(sequence: Int, data: Data, capturedAt: Date = Date()) {
        self.sequence = sequence
        self.data = data
        self.capturedAt = capturedAt
    }
}
