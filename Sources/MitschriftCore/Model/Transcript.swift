import Foundation

/// Der Stand einer Mitschrift: bestätigte Abschnitte und das noch veränderliche Ende.
///
/// Finale Abschnitte werden nur angehängt und nie verändert. Die Partial-Liste wird
/// bei jeder Serverantwort komplett ersetzt.
public struct Transcript: Equatable, Sendable {
    public private(set) var finalSegments: [Segment]
    public private(set) var partialSegments: [Segment]
    /// Vom Nutzer vergebene Namen je Sprecherlabel („1“ → „Anna“). Ohne Eintrag heißt ein Sprecher „Sprecher N“.
    public var speakerNames: [String: String]

    public init(finalSegments: [Segment] = [], partialSegments: [Segment] = [], speakerNames: [String: String] = [:]) {
        self.finalSegments = finalSegments
        self.partialSegments = partialSegments
        self.speakerNames = speakerNames
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

    /// Gibt es mindestens einen finalen Abschnitt mit Sprecherlabel?
    public var hasSpeakers: Bool {
        finalSegments.contains { $0.speaker != nil }
    }

    /// Alle Sprecherlabels in Reihenfolge des ersten Auftretens.
    public var speakerLabels: [String] {
        var seen: [String] = []
        for segment in finalSegments {
            if let speaker = segment.speaker, !seen.contains(speaker) { seen.append(speaker) }
        }
        return seen
    }

    /// Anzeigename eines Labels: der vergebene Name oder „Sprecher N“.
    public func speakerName(for label: String) -> String {
        if let name = speakerNames[label]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return "Sprecher \(label)"
    }

    /// Ein Absatz der Mitschrift: alle aufeinanderfolgenden Abschnitte desselben Sprechers.
    public struct Paragraph: Equatable, Sendable {
        /// Sprecherlabel („1“), `nil` für Text ohne Sprecher.
        public var label: String?
        /// Anzeigename des Sprechers, `nil` ohne Label.
        public var name: String?
        public var text: String
    }

    /// Finale Abschnitte als Absätze nach Sprecherwechseln, Namen bereits aufgelöst.
    public var paragraphs: [Paragraph] {
        Self.groupBySpeaker(finalSegments).map { group in
            Paragraph(label: group.speaker, name: group.speaker.map(speakerName(for:)), text: group.words.joined(separator: " "))
        }
    }

    /// Finaler Text als Absätze nach Sprechern: Jeder Sprecherwechsel beginnt eine neue Zeile mit
    /// „Name: “ („Sprecher N“ ohne vergebenen Namen). Abschnitte ohne Label hängen an der laufenden
    /// Zeile; folgt ein Abschnitt ohne Label auf einen Sprecher, bekommt er einen eigenen Absatz ohne
    /// Präfix. Ohne Labels gleich `finalText`.
    public var finalTextWithSpeakers: String {
        guard hasSpeakers else { return finalText }
        return paragraphs.map { paragraph in
            guard let name = paragraph.name else { return paragraph.text }
            return "\(name): \(paragraph.text)"
        }.joined(separator: "\n")
    }

    /// Text für Anzeige und Export: Sprecherabsätze der Finals, dahinter der vorläufige Text.
    public var exportText: String {
        [finalTextWithSpeakers, partialText].filter { !$0.isEmpty }.joined(separator: hasSpeakers ? "\n" : " ")
    }

    /// Absätze aus Sprecherwechseln als Text mit „Sprecher N: “-Präfix (ohne vergebene Namen).
    public static func speakerParagraphs(_ segments: [Segment]) -> [String] {
        groupBySpeaker(segments).map { paragraph in
            let body = paragraph.words.joined(separator: " ")
            guard let speaker = paragraph.speaker else { return body }
            return "Sprecher \(speaker): \(body)"
        }
    }

    private static func groupBySpeaker(_ segments: [Segment]) -> [(speaker: String?, words: [String])] {
        var paragraphs: [(speaker: String?, words: [String])] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = paragraphs.last, last.speaker == segment.speaker || (segment.speaker == nil && last.speaker == nil) {
                paragraphs[paragraphs.count - 1].words.append(text)
            } else if segment.speaker == nil, paragraphs.isEmpty {
                paragraphs.append((nil, [text]))
            } else {
                paragraphs.append((segment.speaker, [text]))
            }
        }
        return paragraphs
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
