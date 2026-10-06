import Foundation
import Testing
@testable import MitschriftCore

@Suite struct TranscriptEditingTests {
    /// Fünf Abschnitte mit Pausen: [0–2] [3–5] [6–8] [10–12] [14–16], Aufnahme 20 s lang.
    private let segments = [
        Segment(start: 0, end: 2, text: "a", speaker: "1"),
        Segment(start: 3, end: 5, text: "b", speaker: "1"),
        Segment(start: 6, end: 8, text: "c", speaker: "2"),
        Segment(start: 10, end: 12, text: "d", speaker: "2"),
        Segment(start: 14, end: 16, text: "e", speaker: "1"),
    ]

    @Test func nothingRemovedGivesNoRanges() {
        let ranges = TranscriptEditing.removedRanges(segments: segments, keep: Array(repeating: true, count: 5), duration: 20)
        #expect(ranges.isEmpty)
        #expect(TranscriptEditing.cutPlan(removing: ranges, duration: 20).isEmpty)
    }

    @Test func trailingRunCutsToEndIncludingGap() {
        // Nebengespräch am Ende: d und e weg → ab kurz nach c bis zum Dateiende.
        let ranges = TranscriptEditing.removedRanges(segments: segments, keep: [true, true, true, false, false], duration: 20)
        #expect(ranges == [8.25...20])
        let plan = TranscriptEditing.cutPlan(removing: ranges, duration: 20)
        #expect(plan == AudioCutPlan(leadingCut: 0, end: 8.25, muted: []))
        #expect(plan.resultingDuration(of: 20) == 8.25)
    }

    @Test func leadingRunCutsFromStartAndShiftsTimes() {
        let keep = [false, false, true, true, true]
        let ranges = TranscriptEditing.removedRanges(segments: segments, keep: keep, duration: 20)
        #expect(ranges == [0...5.75])
        let plan = TranscriptEditing.cutPlan(removing: ranges, duration: 20)
        #expect(plan.leadingCut == 5.75 && plan.end == nil && plan.muted.isEmpty)
        let kept = TranscriptEditing.apply(plan, to: zip(segments, keep).filter(\.1).map(\.0))
        #expect(kept.map(\.start) == [0.25, 4.25, 8.25])
        #expect(kept.map(\.end) == [2.25, 6.25, 10.25])
    }

    @Test func middleRunIsMutedNotCut() {
        let ranges = TranscriptEditing.removedRanges(segments: segments, keep: [true, false, false, true, true], duration: 20)
        #expect(ranges == [2.25...9.75])
        let plan = TranscriptEditing.cutPlan(removing: ranges, duration: 20)
        #expect(plan == AudioCutPlan(leadingCut: 0, end: nil, muted: [2.25...9.75]))
        // Behaltene Zeiten bleiben unverändert.
        #expect(TranscriptEditing.apply(plan, to: [segments[3]]) == [segments[3]])
    }

    @Test func separateRunsCombineIntoOnePlan() {
        let ranges = TranscriptEditing.removedRanges(segments: segments, keep: [false, true, false, true, false], duration: 20)
        #expect(ranges == [0...2.75, 5.25...9.75, 12.25...20])
        let plan = TranscriptEditing.cutPlan(removing: ranges, duration: 20)
        #expect(plan.leadingCut == 2.75 && plan.end == 12.25 && plan.muted == [5.25...9.75])
        #expect(plan.resultingDuration(of: 20) == 9.5)
    }

    @Test func paddingNeverEatsIntoRemovedSegmentOrNeighbour() {
        // Abschnitte stoßen direkt aneinander: der Bereich ist genau der entfernte Abschnitt.
        let tight = [Segment(start: 0, end: 2, text: "a"), Segment(start: 2, end: 4, text: "b"), Segment(start: 4, end: 6, text: "c")]
        #expect(TranscriptEditing.removedRanges(segments: tight, keep: [true, false, true], duration: 6) == [2...4])
    }

    @Test func rangesAreClampedToDuration() {
        // Die Live-Zeiten können die Dateilänge leicht überschreiten.
        let ranges = TranscriptEditing.removedRanges(segments: segments, keep: [true, true, true, true, false], duration: 15)
        #expect(ranges == [12.25...15])
        #expect(TranscriptEditing.cutPlan(removing: ranges, duration: 15).end == 12.25)
    }

    @Test func mergeJoinsOverlaps() {
        #expect(TranscriptEditing.merge([5...6, 1...2, 1.5...3, 6...7]) == [1...3, 5...7])
    }

    @Test func plainTextTranscriptHasNoTimings() {
        #expect(!TranscriptEditing.hasTimings(Transcript.fromPlainText("Hallo").finalSegments))
        #expect(TranscriptEditing.hasTimings(segments))
    }

    @Test func summaryFileIsListedSavedAndDeleted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("Gespräch-2026-10-06_10-00-00.m4a")
        try Data([1]).write(to: audio)
        let library = RecordingLibrary(directory: directory)
        let url = try library.saveNotes("# Zusammenfassung", kind: .summary, forAudio: audio)
        #expect(url.lastPathComponent == "Gespräch-2026-10-06_10-00-00-Zusammenfassung.md")
        let item = try #require(library.items().first)
        #expect(item.hasSummary && !item.hasNotes)
        #expect(item.url(for: .summary) == url)
        try library.delete(item)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func notesRequestCarriesKindAndResponseResolvesIt() throws {
        let request = NotesRequest(transcript: "x", language: "de", kind: .summary)
        let json = try #require(String(data: JSONEncoder().encode(request), encoding: .utf8))
        #expect(json.contains("\"kind\":\"summary\""))
        let old = try JSONDecoder().decode(NotesResponse.self, from: Data(##"{"notes":"# Protokoll"}"##.utf8))
        #expect(old.resolvedKind == .minutes)
        let summary = try JSONDecoder().decode(NotesResponse.self, from: Data(#"{"notes":"x","kind":"summary","diagnostics":{"chunks":2}}"#.utf8))
        #expect(summary.resolvedKind == .summary && summary.diagnostics?.chunks == 2)
        let unknown = try JSONDecoder().decode(NotesResponse.self, from: Data(#"{"notes":"x","kind":"poem"}"#.utf8))
        #expect(unknown.resolvedKind == nil)
    }

    @Test func documentEditedAtIsOptionalAndRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("doc-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: directory) }
        var document = TranscriptDocument(createdAt: Date(timeIntervalSince1970: 0), language: "de", transcript: Transcript(finalSegments: segments))
        try document.write(to: directory)
        #expect(try TranscriptDocument.load(from: directory).editedAt == nil)
        document.editedAt = Date(timeIntervalSince1970: 1_000)
        try document.write(to: directory)
        #expect(try TranscriptDocument.load(from: directory).editedAt == Date(timeIntervalSince1970: 1_000))
    }
}
