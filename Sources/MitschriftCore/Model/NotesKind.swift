import Foundation

/// Die Textarten des Notizen-Assistenten (`POST /v1/notes`, Feld `kind`).
public enum NotesKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Besprechungsprotokoll mit Entscheidungen und Aufgaben.
    case minutes
    /// Zusammenfassung zum Nachlesen, etwa für Trainings und Informationsveranstaltungen.
    case summary

    public var id: String { rawValue }

    /// Anzeigename und Namensteil der Datei (`…-Protokoll.md`, `…-Zusammenfassung.md`).
    public var title: String {
        switch self {
        case .minutes: return "Protokoll"
        case .summary: return "Zusammenfassung"
        }
    }
}
