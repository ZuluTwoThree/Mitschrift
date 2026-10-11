import Foundation
import Combine
import MitschriftCore

/// Eine geöffnete Aufnahme mit ihrer Mitschrift, ihrem Protokoll und ihrer Zusammenfassung, samt den
/// Aktionen darauf: Sprecher benennen, Mitschrift kürzen und korrigieren, nachträglich übertragen,
/// Protokoll oder Zusammenfassung erstellen. Dient der Hauptansicht nach dem Stoppen genauso wie der
/// Detailansicht aus der Liste.
@MainActor
final class OpenRecording: ObservableObject {
    enum Activity: Equatable {
        case transcribing(progress: Double)
        case writing(NotesKind)
        case editing
        /// Genaue Nach-Transkription: erst Upload, dann Warten auf den Server.
        case refining(RefineStage)
    }

    enum RefineStage: Equatable {
        case uploading(Double)
        case queued
        case processing(phase: String?, elapsed: Double)
    }

    @Published private(set) var item: RecordingItem
    @Published private(set) var transcript: Transcript
    /// Protokoll und Zusammenfassung als Markdown, soweit vorhanden.
    @Published private(set) var texts: [NotesKind: String] = [:]
    @Published private(set) var incomplete: Bool
    @Published private(set) var missingSegments: Int
    @Published private(set) var activity: Activity?
    @Published private(set) var error: String?
    /// Das Modell, das einen Text in dieser Sitzung geschrieben hat; entfällt nach eigener Bearbeitung.
    @Published private(set) var models: [NotesKind: String] = [:]
    /// Texte, die noch aus der Mitschrift vor der letzten Bearbeitung stammen.
    @Published private(set) var outdated: Set<NotesKind> = []
    /// Die Audiodatei wird gerade komprimiert und darf nicht verändert werden.
    @Published var audioLocked = false
    /// Modell der genauen Nach-Transkription, wenn die Mitschrift nicht mehr die Live-Fassung ist.
    @Published private(set) var refinedModel: String?

    let language: String
    /// Letzte Bearbeitung der Mitschrift, wird im Dokument mitgespeichert.
    private var editedAt: Date?
    private let library: RecordingLibrary?
    private let fileTask = FileTranscriptionTask()
    private var cancellables: Set<AnyCancellable> = []

    var id: String { item.id }
    var isBusy: Bool { activity != nil }

    /// Aus einer frisch beendeten Aufnahme.
    init(item: RecordingItem, transcript: Transcript, language: String, incomplete: Bool, missingSegments: Int,
         editedAt: Date? = nil, refinedModel: String? = nil, library: RecordingLibrary?) {
        self.item = item
        self.transcript = transcript
        self.language = language
        self.incomplete = incomplete
        self.missingSegments = missingSegments
        self.library = library
        self.editedAt = editedAt
        self.refinedModel = refinedModel
        for kind in NotesKind.allCases {
            guard let url = item.url(for: kind) else { continue }
            texts[kind] = try? String(contentsOf: url, encoding: .utf8)
            // Ein Text, der vor der letzten Bearbeitung entstand, kann entfernte Stellen noch enthalten.
            if let editedAt, let written = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
               written < editedAt {
                outdated.insert(kind)
            }
        }
        observeFileTask()
    }

    /// Aus der Liste: Mitschrift und Protokoll werden von der Platte gelesen.
    convenience init(item: RecordingItem, language: String, library: RecordingLibrary?) {
        let document = library?.loadDocument(for: item)
        let transcript = document?.transcript ?? library?.loadTranscript(for: item) ?? Transcript()
        self.init(item: item, transcript: transcript, language: document?.language ?? language,
                  incomplete: document?.incomplete ?? false, missingSegments: document?.missingSegments ?? 0,
                  editedAt: document?.editedAt, refinedModel: document?.refinedModel, library: library)
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
        editedAt = Date()
        outdated.formUnion(texts.keys)
        saveTranscript()
    }

    // MARK: Genau transkribieren

    /// Lädt die Aufnahme hoch und lässt sie auf dem Server mit dem genaueren Modell am Stück transkribieren.
    /// Kennt der Server das noch nicht, wird wie bisher über die Live-Schnittstelle nachträglich übertragen.
    func refine(endpoint: ServerEndpoint, transport: RefineTransport? = nil, pollInterval: Duration = .seconds(2)) async {
        guard !isBusy, !audioLocked else { return }
        error = nil
        activity = .refining(.uploading(0))
        let transport = transport ?? URLSessionLiveTransport(endpoint: endpoint)
        let language = self.language
        var job: RefineJob
        do {
            job = try await transport.startRefine(audioFile: item.audioURL, language: language) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .refining(.uploading) = self.activity else { return }
                    self.activity = .refining(.uploading(fraction))
                }
            }
        } catch LiveTranscriptionError.sessionNotFound {
            // 404: älterer Adapter ohne /v1/transcriptions.
            activity = nil
            await retranscribe(endpoint: endpoint)
            return
        } catch let error as LiveTranscriptionError {
            activity = nil
            self.error = Self.explainRefine(error)
            return
        } catch {
            activity = nil
            self.error = error.localizedDescription
            return
        }

        var failures = 0
        while !job.isFinished {
            activity = job.status == "queued" ? .refining(.queued) : .refining(.processing(phase: job.phase, elapsed: job.elapsedSeconds ?? 0))
            try? await Task.sleep(for: pollInterval)
            do {
                job = try await transport.refineStatus(id: job.id)
                failures = 0
            } catch LiveTranscriptionError.sessionNotFound {
                activity = nil
                error = "Der Auftrag ist auf dem Server nicht mehr bekannt, vermutlich wurde der Adapter neu gestartet. Bitte noch einmal versuchen."
                return
            } catch {
                // Kurze Netzaussetzer überbrücken, der Server rechnet weiter.
                failures += 1
                if failures >= 15 {
                    activity = nil
                    self.error = "Die Verbindung zum Server ist abgerissen. Die genaue Transkription läuft dort eventuell weiter; bitte später noch einmal versuchen."
                    return
                }
            }
        }
        activity = nil
        guard job.status == "done", let segments = job.segments else {
            error = job.message.map { "Die genaue Transkription ist fehlgeschlagen: \($0)" } ?? "Die genaue Transkription ist fehlgeschlagen."
            return
        }
        apply(refined: segments, model: job.model ?? "unbekannt")
    }

    /// Übernimmt die genaue Fassung: Sprecherlabels passend zur bisherigen Mitschrift, damit Namen bleiben.
    func apply(refined segments: [Segment], model: String) {
        let relabeled = SpeakerMatching.relabel(segments, toMatch: transcript.finalSegments)
        let remaining = Set(relabeled.compactMap(\.speaker))
        transcript = Transcript(finalSegments: relabeled, speakerNames: transcript.speakerNames.filter { remaining.contains($0.key) })
        incomplete = false
        missingSegments = 0
        refinedModel = model
        editedAt = Date()
        outdated.formUnion(texts.keys)
        saveTranscript()
    }

    private static func explainRefine(_ error: LiveTranscriptionError) -> String {
        switch error {
        case .unavailable:
            return "Die genaue Transkription ist auf dem Server nicht eingerichtet oder gerade nicht verfügbar."
        case .payloadTooLarge:
            return "Die Aufnahme ist zu groß für die genaue Transkription."
        case .overloaded:
            return "Auf dem Server warten schon zu viele Aufträge. Bitte später noch einmal versuchen."
        case .transport:
            return "Server nicht erreichbar. Ist Tailscale auf dem iPhone verbunden?"
        default:
            return error.userMessage
        }
    }

    // MARK: Mitschrift bearbeiten

    /// Kann die Audiodatei passend zur Mitschrift gekürzt werden? Dafür braucht es Zeiten an den
    /// Abschnitten und eine Datei, die gerade nicht komprimiert wird.
    var canEditAudio: Bool { TranscriptEditing.hasTimings(transcript.finalSegments) && !audioLocked }

    /// Übernimmt eine bearbeitete Mitschrift.
    ///
    /// - Parameters:
    ///   - segments: die behaltenen Abschnitte in Reihenfolge, Texte ggf. korrigiert, Zeiten wie im Original
    ///   - removed: Zeitbereiche der entfernten Abschnitte (aus `TranscriptEditing.removedRanges`)
    ///   - cutAudio: die entfernten Bereiche auch aus der Audiodatei nehmen
    /// - Returns: `true`, wenn alles gespeichert ist.
    @discardableResult
    func applyEdit(segments: [Segment], removed: [ClosedRange<Double>], cutAudio: Bool) async -> Bool {
        guard !isBusy else { return false }
        error = nil
        var result = segments
        if cutAudio, !removed.isEmpty {
            guard canEditAudio, let duration = AudioFileReader.duration(of: item.audioURL) else {
                error = "Die Aufnahme lässt sich gerade nicht kürzen. Die Mitschrift wurde nicht geändert."
                return false
            }
            activity = .editing
            defer { activity = nil }
            let plan = TranscriptEditing.cutPlan(removing: removed, duration: duration)
            do {
                try await AudioEditor.apply(plan, to: item.audioURL)
            } catch {
                self.error = "Die Aufnahme konnte nicht gekürzt werden: \(error.localizedDescription) Die Mitschrift wurde nicht geändert."
                return false
            }
            result = TranscriptEditing.apply(plan, to: segments)
            audioMoved(to: item.audioURL)
            item.duration = plan.resultingDuration(of: duration)
        }
        let changed = result != transcript.finalSegments
        let remaining = Set(result.compactMap(\.speaker))
        transcript = Transcript(finalSegments: result, speakerNames: transcript.speakerNames.filter { remaining.contains($0.key) })
        if changed {
            editedAt = Date()
            outdated.formUnion(texts.keys)
        }
        saveTranscript()
        return error == nil
    }

    // MARK: Protokoll und Zusammenfassung

    func text(_ kind: NotesKind) -> String? { texts[kind] }

    func createNotes(kind: NotesKind, endpoint: ServerEndpoint, transport: NotesTransport? = nil) async {
        guard !isBusy, !transcript.isEmpty else { return }
        error = nil
        activity = .writing(kind)
        defer { activity = nil }
        let transport = transport ?? URLSessionLiveTransport(endpoint: endpoint)
        let request = NotesRequest(transcript: transcript.finalTextWithSpeakers, language: language == "en" ? "en" : "de",
                                   recordedAt: createdAt, kind: kind)
        do {
            let response = try await transport.notes(request)
            guard response.resolvedKind == kind else {
                error = "Der Server kennt noch keine \(kind.title). Bitte den Adapter auf dem Server aktualisieren."
                return
            }
            texts[kind] = response.notes
            models[kind] = response.model
            outdated.remove(kind)
            if let library {
                item.setURL(try library.saveNotes(response.notes, kind: kind, forAudio: item.audioURL), for: kind)
            }
        } catch let error as LiveTranscriptionError {
            self.error = Self.explain(error, kind: kind)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Übernimmt einen in der App bearbeiteten Text und schreibt ihn in die Datei; leer löscht die Datei.
    func saveNotes(_ markdown: String, kind: NotesKind) {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        texts[kind] = trimmed.isEmpty ? nil : markdown
        // Ab jetzt stammt der Text nicht mehr allein vom Modell.
        models[kind] = nil
        guard let library else { return }
        do {
            if let text = texts[kind] {
                item.setURL(try library.saveNotes(text, kind: kind, forAudio: item.audioURL), for: kind)
            } else if let url = item.url(for: kind) {
                try FileManager.default.removeItem(at: url)
                item.setURL(nil, for: kind)
                outdated.remove(kind)
            }
        } catch {
            self.error = "\(kind.title) konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    /// Hakt eine Aufgabe („- [ ]“ ↔ „- [x]“) in der angegebenen Zeile ab oder wieder auf.
    func toggleTask(atLine index: Int, kind: NotesKind) {
        guard let text = texts[kind] else { return }
        var lines = text.components(separatedBy: "\n")
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
        let model = models[kind]
        saveNotes(lines.joined(separator: "\n"), kind: kind)
        // Abhaken ändert den Inhalt nicht, das Modell bleibt die Quelle.
        models[kind] = model
    }

    private static func explain(_ error: LiveTranscriptionError, kind: NotesKind) -> String {
        switch error {
        case .unavailable:
            return "Der Notizen-Assistent ist auf dem Server nicht eingerichtet oder gerade nicht erreichbar."
        case .payloadTooLarge:
            return "Die Mitschrift ist zu lang für den Notizen-Assistenten. Kürzen hilft, oder die \(kind.title) abschnittsweise erstellen."
        case .transport:
            return "Server nicht erreichbar. Ist Tailscale auf dem iPhone verbunden?"
        default:
            return error.userMessage
        }
    }

    // MARK: Speichern

    private func saveTranscript() {
        guard let library else { return }
        let document = TranscriptDocument(createdAt: createdAt, language: language, transcript: transcript, incomplete: incomplete,
                                          missingSegments: missingSegments, editedAt: editedAt, refinedModel: refinedModel)
        do {
            let urls = try library.save(document, forAudio: item.audioURL)
            item.transcriptDocumentURL = urls.document
            item.transcriptTextURL = urls.text
        } catch {
            self.error = "Die Mitschrift konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }
}
