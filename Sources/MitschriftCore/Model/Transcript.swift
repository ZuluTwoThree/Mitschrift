import Foundation

/// Der Stand einer Mitschrift: bestätigte Abschnitte und das noch veränderliche Ende.
///
/// Finale Abschnitte werden nur angehängt und nie verändert. Die Partial-Liste wird
/// bei jeder Serverantwort komplett ersetzt.
public struct Transcript: Equatable, Sendable {
    public private(set) var finalSegments: [Segment]
    public private(set) var partialSegments: [Segment]

    public init(finalSegments: [Segment] = [], partialSegments: [Segment] = []) {
        self.finalSegments = finalSegments
        self.partialSegments = partialSegments
    }

    /// Text aller finalen Abschnitte, durch Leerzeichen verbunden.
    public var finalText: String {
        Self.join(finalSegments)
    }

    /// Text der vorläufigen Abschnitte.
    public var partialText: String {
        Self.join(partialSegments)
    }

    /// Finaler und vorläufiger Text zusammen, für Anzeige und Export.
    public var fullText: String {
        [finalText, partialText].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var isEmpty: Bool {
        finalSegments.isEmpty && partialSegments.isEmpty
    }

    /// Übernimmt eine Segmentantwort: neue Finals anhängen, Partials ersetzen.
    public mutating func apply(_ response: SegmentResponse) {
        append(finals: response.finalSegments)
        partialSegments = response.partialSegments
    }

    /// Übernimmt die Abschlussantwort: Rest anhängen, keine Partials mehr.
    public mutating func apply(_ response: FinishResponse) {
        append(finals: response.finalSegments)
        partialSegments = []
    }

    /// Setzt eine Mitschrift aus einer lokalen Datei-Transkription (nur ein finaler Abschnitt).
    public static func fromPlainText(_ text: String) -> Transcript {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Transcript() }
        return Transcript(finalSegments: [Segment(start: 0, end: 0, text: trimmed)])
    }

    private mutating func append(finals: [Segment]) {
        for segment in finals where !segment.text.trimmingCharacters(in: .whitespaces).isEmpty {
            finalSegments.append(segment)
        }
    }

    private static func join(_ segments: [Segment]) -> String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
