import Foundation

/// Dateinamen und Zeitformate, gemeinsam für macOS und iOS.
public enum RecordingNaming {
    /// `Gespräch-2026-10-02_18-30-00.wav`
    public static func recordingFileName(for date: Date, fileExtension: String = "wav") -> String {
        "Gespräch-\(timestamp(date)).\(fileExtension)"
    }

    /// `Gespräch-…-Mitschrift.txt` zu einer Audiodatei: der lesbare Export.
    public static func transcriptFileName(forAudioNamed audioName: String) -> String {
        "\(baseName(audioName))-Mitschrift.txt"
    }

    /// `Gespräch-…-Mitschrift.json`: die gespeicherte Mitschrift mit Abschnitten und Sprechernamen.
    public static func transcriptDocumentFileName(forAudioNamed audioName: String) -> String {
        "\(baseName(audioName))-Mitschrift.json"
    }

    /// `Gespräch-…-Protokoll.md` bzw. `Gespräch-…-Zusammenfassung.md`: der vom Assistenten erstellte Text.
    public static func notesFileName(forAudioNamed audioName: String, kind: NotesKind = .minutes) -> String {
        "\(baseName(audioName))-\(kind.title).md"
    }

    /// Der gemeinsame Namensstamm aller Dateien einer Aufnahme (`Gespräch-2026-10-02_18-30-00`).
    public static func baseName(_ fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }

    /// Der Zeitpunkt aus einem Dateinamen der Form `Gespräch-yyyy-MM-dd_HH-mm-ss…`, falls vorhanden.
    public static func date(fromFileName fileName: String) -> Date? {
        let base = baseName(fileName)
        guard let dash = base.firstIndex(of: "-") else { return nil }
        let stamp = String(base[base.index(after: dash)...].prefix(19))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.date(from: stamp)
    }

    /// `mm:ss`, ab einer Stunde `h:mm:ss`.
    public static func elapsedText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
}

/// Der Ordner `Documents/Mitschrift`, auf beiden Plattformen.
public enum RecordingsDirectory {
    public static func url(fileManager: FileManager = .default) throws -> URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Mitschrift", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
