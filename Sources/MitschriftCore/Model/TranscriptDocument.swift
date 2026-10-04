import Foundation

/// Gespeicherte Form einer Mitschrift neben der Audiodatei (`…-Mitschrift.json`).
///
/// Enthält die finalen Abschnitte mit Zeiten und Sprecherlabels sowie die vergebenen Sprechernamen,
/// damit die App eine Aufnahme später wieder mit Sprecherspalte anzeigen und umbenennen kann.
/// Die `…-Mitschrift.txt` daneben ist nur der lesbare Export und wird aus diesem Dokument erzeugt.
public struct TranscriptDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var createdAt: Date
    public var language: String
    public var segments: [Segment]
    public var speakerNames: [String: String]
    /// Die Live-Übertragung endete nicht sauber oder es fehlen Abschnitte.
    public var incomplete: Bool
    /// Anzahl der lokal verworfenen oder vom Server abgelehnten Abschnitte.
    public var missingSegments: Int

    public init(createdAt: Date, language: String, transcript: Transcript, incomplete: Bool = false, missingSegments: Int = 0) {
        version = Self.currentVersion
        self.createdAt = createdAt
        self.language = language
        segments = transcript.finalSegments + transcript.partialSegments
        speakerNames = transcript.speakerNames
        self.incomplete = incomplete
        self.missingSegments = missingSegments
    }

    /// Die Mitschrift mit allen Abschnitten als final und den gespeicherten Namen.
    public var transcript: Transcript {
        Transcript(finalSegments: segments, speakerNames: speakerNames)
    }

    public static func load(from url: URL) throws -> TranscriptDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptDocument.self, from: Data(contentsOf: url))
    }

    /// Schreibt das Dokument als JSON.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
