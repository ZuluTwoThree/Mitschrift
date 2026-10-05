import Foundation
import Combine
import MitschriftCore

/// Eine geöffnete Aufnahme mit ihrer Mitschrift und ihrem Protokoll, samt den Aktionen darauf:
/// Sprecher benennen, nachträglich übertragen, Protokoll erstellen. Dient der Hauptansicht nach dem
/// Stoppen genauso wie der Detailansicht aus der Liste.
@MainActor
final class OpenRecording: ObservableObject {
    enum Activity: Equatable {
        case transcribing(progress: Double)
        case writingNotes
    }

    @Published private(set) var item: RecordingItem
    @Published private(set) var transcript: Transcript
    @Published private(set) var notes: String?
    @Published private(set) var incomplete: Bool
    @Published private(set) var missingSegments: Int
    @Published private(set) var activity: Activity?
    @Published private(set) var error: String?
    @Published private(set) var notesModel: String?

    let language: String
    private let library: RecordingLibrary?
    private let fileTask = FileTranscriptionTask()
    private var cancellables: Set<AnyCancellable> = []

    var id: String { item.id }
    var isBusy: Bool { activity != nil }

    /// Aus einer frisch beendeten Aufnahme.
    init(item: RecordingItem, transcript: Transcript, language: String, incomplete: Bool, missingSegments: Int, library: RecordingLibrary?) {
        self.item = item
        self.transcript = transcript
        self.language = language
        self.incomplete = incomplete
        self.missingSegments = missingSegments
        self.library = library
        notes = item.notesURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        observeFileTask()
    }

    /// Aus der Liste: Mitschrift und Protokoll werden von der Platte gelesen.
    convenience init(item: RecordingItem, language: String, library: RecordingLibrary?) {
        let document = library?.loadDocument(for: item)
        let transcript = document?.transcript ?? library?.loadTranscript(for: item) ?? Transcript()
        self.init(item: item, transcript: transcript, language: document?.language ?? language,
                  incomplete: document?.incomplete ?? false, missingSegments: document?.missingSegments ?? 0, library: library)
    }

    private func observeFileTask() {
        fileTask.$progress
            .receive(on: RunLoop.main)
            .sink { [weak self] progress in
                guard let self, case .transcribing = self.activity else { return }
                self.activity = .transcribing(progress: progress)
            }
            .store(in: &cancellables)
    }

    /// Die Audiodatei wurde umbenannt (etwa nach der Umwandlung in AAC).
    func audioMoved(to url: URL) {
        item.audioURL = url
        item.fileSize = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? item.fileSize
    }

    var canRetranscribe: Bool { incomplete || transcript.isEmpty }
    var createdAt: Date { item.createdAt }

    // MARK: Sprecher

    func rename(speakers names: [String: String]) {
        transcript.speakerNames = names.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        saveTranscript()
    }

    // MARK: Nachträglich übertragen

    func retranscribe(endpoint: ServerEndpoint) async {
        guard !isBusy else { return }
        error = nil
        activity = .transcribing(progress: 0)
        defer { activity = nil }
        guard let result = await fileTask.run(audioURL: item.audioURL, endpoint: endpoint, language: language) else {
            error = fileTask.error
            return
        }
        var updated = result
        updated.speakerNames = transcript.speakerNames
        transcript = updated
        incomplete = false
        missingSegments = 0
        saveTranscript()
    }

    // MARK: Protokoll

    func createNotes(endpoint: ServerEndpoint, transport: NotesTransport? = nil) async {
        guard !isBusy, !transcript.isEmpty else { return }
        error = nil
        activity = .writingNotes
        defer { activity = nil }
        let transport = transport ?? URLSessionLiveTransport(endpoint: endpoint)
        let request = NotesRequest(transcript: transcript.finalTextWithSpeakers, language: language == "en" ? "en" : "de", recordedAt: createdAt)
        do {
            let response = try await transport.notes(request)
            notes = response.notes
            notesModel = response.model
            if let library {
                item.notesURL = try library.saveNotes(response.notes, forAudio: item.audioURL)
            }
        } catch let error as LiveTranscriptionError {
            self.error = Self.explain(error)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Übernimmt ein in der App bearbeitetes Protokoll und schreibt es in die Datei.
    func saveNotes(_ markdown: String) {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        notes = trimmed.isEmpty ? nil : markdown
        // Ab jetzt stammt der Text nicht mehr allein vom Modell.
        notesModel = nil
        guard let library else { return }
        do {
            if let notes {
                item.notesURL = try library.saveNotes(notes, forAudio: item.audioURL)
            } else if let url = item.notesURL {
                try FileManager.default.removeItem(at: url)
                item.notesURL = nil
            }
        } catch {
            self.error = "Das Protokoll konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    /// Hakt eine Aufgabe („- [ ]“ ↔ „- [x]“) in der angegebenen Zeile ab oder wieder auf.
    func toggleTask(atLine index: Int) {
        guard let notes else { return }
        var lines = notes.components(separatedBy: "\n")
        guard lines.indices.contains(index) else { return }
        let line = lines[index]
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let body = line.dropFirst(leading.count)
        if body.hasPrefix("- [ ] ") {
            lines[index] = leading + "- [x] " + body.dropFirst(6)
        } else if body.lowercased().hasPrefix("- [x] ") {
            lines[index] = leading + "- [ ] " + body.dropFirst(6)
        } else {
            return
        }
        saveNotes(lines.joined(separator: "\n"))
    }

    private static func explain(_ error: LiveTranscriptionError) -> String {
        switch error {
        case .unavailable:
            return "Der Protokoll-Assistent ist auf dem Server nicht eingerichtet oder gerade nicht erreichbar."
        case .payloadTooLarge:
            return "Die Mitschrift ist zu lang für den Protokoll-Assistenten."
        case .transport:
            return "Server nicht erreichbar. Ist Tailscale auf dem iPhone verbunden?"
        default:
            return error.userMessage
        }
    }

    // MARK: Speichern

    private func saveTranscript() {
        guard let library else { return }
        let document = TranscriptDocument(createdAt: createdAt, language: language, transcript: transcript, incomplete: incomplete, missingSegments: missingSegments)
        do {
            let urls = try library.save(document, forAudio: item.audioURL)
            item.transcriptDocumentURL = urls.document
            item.transcriptTextURL = urls.text
        } catch {
            self.error = "Die Mitschrift konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }
}
