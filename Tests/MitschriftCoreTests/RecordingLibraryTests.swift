import Foundation
import Testing
@testable import MitschriftCore

@Suite struct RecordingLibraryTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func listsRecordingsWithSidecarsNewestFirst() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = directory.appendingPathComponent("Gespräch-2026-10-01_09-00-00.wav")
        let newer = directory.appendingPathComponent("Gespräch-2026-10-02_18-30-00.m4a")
        try WAVEncoder.wavData(samples: Array(repeating: 0, count: 16_000 * 3)).write(to: older)
        try Data([1, 2, 3]).write(to: newer)
        try "x".write(to: directory.appendingPathComponent("Gespräch-2026-10-02_18-30-00-Protokoll.md"), atomically: true, encoding: .utf8)
        try "Notiz".write(to: directory.appendingPathComponent("irgendwas.txt"), atomically: true, encoding: .utf8)

        let items = RecordingLibrary(directory: directory).items()
        #expect(items.map(\.id) == ["Gespräch-2026-10-02_18-30-00", "Gespräch-2026-10-01_09-00-00"])
        #expect(items[0].hasNotes)
        #expect(!items[0].hasTranscript)
        #expect(items[0].duration == nil, "Dauer anderer Formate kennt der Kern nicht")
        #expect(items[1].duration == 3)
        #expect(!items[1].needsRepair)
        let expected = RecordingNaming.date(fromFileName: "Gespräch-2026-10-01_09-00-00.wav")
        #expect(items[1].createdAt == expected)
    }

    @Test func detectsAndRepairsUnfinishedWAV() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Gespräch-2026-10-03_10-00-00.wav")
        let writer = try WAVFileWriter(url: url)
        try writer.append(Array(repeating: 5, count: 16_000))
        // Kein close(): wie nach einem Absturz.
        let library = RecordingLibrary(directory: directory)
        let before = try #require(library.items().first)
        #expect(before.needsRepair)
        #expect(before.duration == nil)
        #expect(library.repairUnfinishedRecordings() == 1)
        let after = try #require(library.items().first)
        #expect(!after.needsRepair)
        #expect(after.duration == 1)
        #expect(library.repairUnfinishedRecordings() == 0)
    }

    @Test func savesLoadsAndDeletesTranscriptDocument() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("Gespräch-2026-10-04_08-00-00.m4a")
        try Data([0]).write(to: audio)
        let library = RecordingLibrary(directory: directory)
        var transcript = Transcript(finalSegments: [
            Segment(start: 0, end: 1, text: "Hallo.", speaker: "1"),
            Segment(start: 1, end: 2, text: "Hi.", speaker: "2"),
        ])
        transcript.speakerNames = ["1": "Anna"]
        let document = TranscriptDocument(createdAt: Date(timeIntervalSince1970: 1_000), language: "de", transcript: transcript, incomplete: true, missingSegments: 2)
        let saved = try library.save(document, forAudio: audio)
        #expect(try String(contentsOf: saved.text, encoding: .utf8) == "Anna: Hallo.\nSprecher 2: Hi.")

        let item = try #require(library.items().first)
        #expect(item.hasTranscript)
        let loaded = try #require(library.loadDocument(for: item))
        #expect(loaded.incomplete)
        #expect(loaded.missingSegments == 2)
        #expect(loaded.transcript == transcript)
        #expect(library.loadTranscript(for: item)?.speakerName(for: "1") == "Anna")

        try library.saveNotes("# Protokoll", forAudio: audio)
        let withNotes = try #require(library.items().first)
        #expect(withNotes.hasNotes)
        try library.delete(withNotes)
        #expect(library.items().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func fallsBackToPlainTextTranscript() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("Gespräch-2026-10-04_08-00-00.wav")
        try WAVEncoder.wavData(samples: []).write(to: audio)
        try "Nur Text".write(to: directory.appendingPathComponent("Gespräch-2026-10-04_08-00-00-Mitschrift.txt"), atomically: true, encoding: .utf8)
        let library = RecordingLibrary(directory: directory)
        let item = try #require(library.items().first)
        #expect(library.loadTranscript(for: item)?.finalText == "Nur Text")
    }

    @Test func speakerNamesResolveInParagraphsAndExport() {
        var transcript = Transcript(finalSegments: [
            Segment(start: 0, end: 1, text: "Guten Tag.", speaker: "1"),
            Segment(start: 1, end: 2, text: "Hallo.", speaker: "2"),
            Segment(start: 2, end: 3, text: "Weiter.", speaker: "1"),
        ])
        #expect(transcript.speakerLabels == ["1", "2"])
        transcript.speakerNames = ["2": "  Bernd ", "1": ""]
        #expect(transcript.speakerName(for: "1") == "Sprecher 1", "leerer Name fällt auf das Label zurück")
        #expect(transcript.speakerName(for: "2") == "Bernd")
        #expect(transcript.paragraphs.map(\.name) == ["Sprecher 1", "Bernd", "Sprecher 1"])
        #expect(transcript.finalTextWithSpeakers == "Sprecher 1: Guten Tag.\nBernd: Hallo.\nSprecher 1: Weiter.")
    }

    @Test func notesRequestEncodesRecordedAtAsISO8601() throws {
        let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
        let request = NotesRequest(transcript: "Text", language: "de", title: "Jour fixe", recordedAt: Date(timeIntervalSince1970: 0), timeZone: berlin)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(object["recordedAt"] as? String == "1970-01-01T01:00:00+01:00", "Ortszeit mit Versatz")
        #expect(object["title"] as? String == "Jour fixe")
        let response = try JSONDecoder().decode(NotesResponse.self, from: Data("""
        { "notes": "# Protokoll", "model": "Qwen3-8B", "diagnostics": { "latencyMs": 12 } }
        """.utf8))
        #expect(response.diagnostics?.latencyMs == 12)
        let health = try JSONDecoder().decode(HealthResponse.self, from: Data("{ \"status\": \"ok\", \"notes\": true }".utf8))
        #expect(health.notes == true)
    }
}
