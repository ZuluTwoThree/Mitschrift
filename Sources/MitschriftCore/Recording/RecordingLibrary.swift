import Foundation

/// Eine gespeicherte Aufnahme im Ordner `Documents/Mitschrift`: Audiodatei plus die Dateien daneben.
public struct RecordingItem: Identifiable, Equatable, Sendable {
    public var audioURL: URL
    public var createdAt: Date
    public var fileSize: Int
    /// Dauer, falls aus der Datei bekannt (WAV: aus der Größe; andere Formate setzt die App).
    public var duration: TimeInterval?
    public var transcriptDocumentURL: URL?
    public var transcriptTextURL: URL?
    public var notesURL: URL?
    /// Die WAV-Datei wurde nicht sauber geschlossen (Absturz während der Aufnahme).
    public var needsRepair: Bool

    public var id: String { RecordingNaming.baseName(audioURL.lastPathComponent) }
    public var hasTranscript: Bool { transcriptDocumentURL != nil || transcriptTextURL != nil }
    public var hasNotes: Bool { notesURL != nil }

    public init(audioURL: URL, createdAt: Date, fileSize: Int, duration: TimeInterval? = nil,
                transcriptDocumentURL: URL? = nil, transcriptTextURL: URL? = nil, notesURL: URL? = nil, needsRepair: Bool = false) {
        self.audioURL = audioURL
        self.createdAt = createdAt
        self.fileSize = fileSize
        self.duration = duration
        self.transcriptDocumentURL = transcriptDocumentURL
        self.transcriptTextURL = transcriptTextURL
        self.notesURL = notesURL
        self.needsRepair = needsRepair
    }

    /// Alle Dateien dieser Aufnahme, zum Löschen.
    public var allURLs: [URL] {
        [audioURL, transcriptDocumentURL, transcriptTextURL, notesURL].compactMap { $0 }
    }
}

/// Liest und verwaltet den Aufnahmeordner: Liste, Reparatur unvollständiger WAV-Dateien, Löschen.
public struct RecordingLibrary: Sendable {
    public static let audioExtensions: Set<String> = ["wav", "m4a", "caf", "flac"]

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Alle Aufnahmen, neueste zuerst.
    public func items(fileManager: FileManager = .default) -> [RecordingItem] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        let existing = Set(names)
        return names
            .filter { Self.audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .compactMap { name -> RecordingItem? in
                let url = directory.appendingPathComponent(name)
                let attributes = (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
                let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                let modified = attributes[.modificationDate] as? Date
                let created = RecordingNaming.date(fromFileName: name) ?? (attributes[.creationDate] as? Date) ?? modified ?? Date()
                func sidecar(_ fileName: String) -> URL? {
                    existing.contains(fileName) ? directory.appendingPathComponent(fileName) : nil
                }
                let isWAV = (name as NSString).pathExtension.lowercased() == "wav"
                let needsRepair = isWAV && WAVFileWriter.needsRepair(at: url)
                let duration: TimeInterval? = isWAV && !needsRepair && size >= WAVEncoder.headerSize
                    ? WAVEncoder.duration(sampleCount: (size - WAVEncoder.headerSize) / 2)
                    : nil
                return RecordingItem(
                    audioURL: url,
                    createdAt: created,
                    fileSize: size,
                    duration: duration,
                    transcriptDocumentURL: sidecar(RecordingNaming.transcriptDocumentFileName(forAudioNamed: name)),
                    transcriptTextURL: sidecar(RecordingNaming.transcriptFileName(forAudioNamed: name)),
                    notesURL: sidecar(RecordingNaming.notesFileName(forAudioNamed: name)),
                    needsRepair: needsRepair
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Repariert alle WAV-Dateien mit unvollständigem Header, etwa nach einem Absturz. Liefert die Anzahl.
    @discardableResult
    public func repairUnfinishedRecordings(fileManager: FileManager = .default) -> Int {
        var repaired = 0
        for item in items(fileManager: fileManager) where item.needsRepair {
            if (try? WAVFileWriter.repairHeader(at: item.audioURL)) != nil { repaired += 1 }
        }
        return repaired
    }

    /// Löscht Audio, Mitschrift und Protokoll einer Aufnahme.
    public func delete(_ item: RecordingItem, fileManager: FileManager = .default) throws {
        for url in item.allURLs where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Speichert die Mitschrift als JSON-Dokument und als lesbaren Text neben der Audiodatei.
    @discardableResult
    public func save(_ document: TranscriptDocument, forAudio audioURL: URL) throws -> (document: URL, text: URL) {
        let name = audioURL.lastPathComponent
        let documentURL = directory.appendingPathComponent(RecordingNaming.transcriptDocumentFileName(forAudioNamed: name))
        let textURL = directory.appendingPathComponent(RecordingNaming.transcriptFileName(forAudioNamed: name))
        try document.write(to: documentURL)
        try document.transcript.exportText.write(to: textURL, atomically: true, encoding: .utf8)
        return (documentURL, textURL)
    }

    /// Speichert das Protokoll als Markdown neben der Audiodatei.
    @discardableResult
    public func saveNotes(_ markdown: String, forAudio audioURL: URL) throws -> URL {
        let url = directory.appendingPathComponent(RecordingNaming.notesFileName(forAudioNamed: audioURL.lastPathComponent))
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Lädt die Mitschrift einer Aufnahme: bevorzugt das JSON-Dokument, sonst den Text.
    public func loadTranscript(for item: RecordingItem) -> Transcript? {
        if let url = item.transcriptDocumentURL, let document = try? TranscriptDocument.load(from: url) {
            return document.transcript
        }
        if let url = item.transcriptTextURL, let text = try? String(contentsOf: url, encoding: .utf8) {
            return Transcript.fromPlainText(text)
        }
        return nil
    }

    public func loadDocument(for item: RecordingItem) -> TranscriptDocument? {
        guard let url = item.transcriptDocumentURL else { return nil }
        return try? TranscriptDocument.load(from: url)
    }
}
