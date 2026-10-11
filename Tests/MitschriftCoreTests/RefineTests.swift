import Foundation
import Testing
@testable import MitschriftCore

@Suite struct RefineTests {
    private let live = [
        Segment(start: 0, end: 5, text: "a", speaker: "1"),
        Segment(start: 5, end: 9, text: "b", speaker: "2"),
        Segment(start: 9, end: 15, text: "c", speaker: "1"),
        Segment(start: 15, end: 20, text: "d", speaker: "3"),
    ]

    @Test func relabelKeepsNamesWithTheRightVoice() {
        // Die Nach-Transkription nummeriert anders: „2“ ist der bisherige „1“, „1“ der bisherige „2“.
        let refined = [
            Segment(start: 0.2, end: 4.8, text: "A", speaker: "2"),
            Segment(start: 5.1, end: 8.9, text: "B", speaker: "1"),
            Segment(start: 9.0, end: 14.7, text: "C", speaker: "2"),
            Segment(start: 15.2, end: 19.8, text: "D", speaker: "3"),
        ]
        #expect(SpeakerMatching.relabel(refined, toMatch: live).map(\.speaker) == ["1", "2", "1", "3"])
    }

    @Test func relabelGivesNewSpeakersFreshNumbers() {
        // Die Nach-Transkription erkennt einen Sprecher mehr; der darf keinen fremden Namen erben.
        let refined = [
            Segment(start: 0, end: 5, text: "A", speaker: "1"),
            Segment(start: 5, end: 7, text: "B", speaker: "2"),
            Segment(start: 7, end: 9, text: "B2", speaker: "3"),
            Segment(start: 9, end: 15, text: "C", speaker: "1"),
            Segment(start: 15, end: 20, text: "D", speaker: "4"),
        ]
        #expect(SpeakerMatching.relabel(refined, toMatch: live).map(\.speaker) == ["1", "2", "4", "1", "3"])
    }

    @Test func relabelLeavesSegmentsWithoutReferenceAlone() {
        let refined = [Segment(start: 0, end: 5, text: "A", speaker: "1"), Segment(start: 5, end: 6, text: "B")]
        #expect(SpeakerMatching.relabel(refined, toMatch: []) == refined)
        #expect(SpeakerMatching.relabel(refined, toMatch: Transcript.fromPlainText("x").finalSegments) == refined)
        #expect(SpeakerMatching.relabel(refined, toMatch: live).last?.speaker == nil)
    }

    @Test func refineJobDecodesServerShape() throws {
        let json = #"{"id":"j1","status":"done","model":"ggml-large-v3.bin","elapsedSeconds":8.2,"durationSeconds":136.7,"diarization":true,"segments":[{"start":0.1,"end":1.6,"text":"Hallo.","speaker":"1"},{"start":2,"end":3,"text":"Ohne.","speaker":null}]}"#
        let job = try JSONDecoder().decode(RefineJob.self, from: Data(json.utf8))
        #expect(job.isFinished && job.segments?.count == 2)
        #expect(job.segments?[1].speaker == nil)
        #expect(RefineJob.displayName(forModel: job.model ?? "") == "large-v3")
        #expect(RefineJob.displayName(forModel: "whisper") == "whisper")
        let running = try JSONDecoder().decode(RefineJob.self, from: Data(#"{"id":"j2","status":"running","phase":"transcribing"}"#.utf8))
        #expect(!running.isFinished && running.phase == "transcribing")
    }

    @Test func healthCarriesRefineFields() throws {
        let health = try JSONDecoder().decode(HealthResponse.self, from: Data(#"{"status":"ok","refine":true,"refineModel":"ggml-large-v3.bin"}"#.utf8))
        #expect(health.refine == true && health.refineModel == "ggml-large-v3.bin")
    }

    @Test func uploadContentTypeFollowsExtension() {
        #expect(URLSessionLiveTransport.contentType(for: URL(fileURLWithPath: "/a/Gespräch.m4a")) == "audio/mp4")
        #expect(URLSessionLiveTransport.contentType(for: URL(fileURLWithPath: "/a/Gespräch.WAV")) == "audio/wav")
        #expect(URLSessionLiveTransport.contentType(for: URL(fileURLWithPath: "/a/x.ogg")) == "application/octet-stream")
    }

    @Test func documentStoresRefinedModel() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("refined-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try TranscriptDocument(createdAt: Date(timeIntervalSince1970: 0), language: "de", transcript: Transcript(finalSegments: live),
                               refinedModel: "ggml-large-v3.bin").write(to: url)
        #expect(try TranscriptDocument.load(from: url).refinedModel == "ggml-large-v3.bin")
    }
}
