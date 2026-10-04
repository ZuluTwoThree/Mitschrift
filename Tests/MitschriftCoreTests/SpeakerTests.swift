import Foundation
import Testing
@testable import MitschriftCore

@Suite struct SpeakerTests {
    @Test func decodesSegmentsWithAndWithoutSpeaker() throws {
        let json = """
        { "sessionId": "s", "sequence": 1,
          "final": [ { "start": 0, "end": 1, "text": "Hallo", "speaker": "1" }, { "start": 1, "end": 2, "text": "Welt" } ],
          "partial": [ { "start": 2, "end": 3, "text": "und" } ] }
        """
        let response = try JSONDecoder().decode(SegmentResponse.self, from: Data(json.utf8))
        #expect(response.finalSegments[0].speaker == "1")
        #expect(response.finalSegments[1].speaker == nil)
        #expect(response.partialSegments[0].speaker == nil)
    }

    @Test func encodesSpeakerOnlyWhenPresent() throws {
        let data = try JSONEncoder().encode(Segment(start: 0, end: 1, text: "a"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["speaker"] == nil)
    }

    @Test func exportStartsNewLinePerSpeakerChange() {
        let transcript = Transcript(finalSegments: [
            .init(start: 0, end: 1, text: "Guten Tag.", speaker: "1"),
            .init(start: 1, end: 2, text: "Wir beginnen.", speaker: "1"),
            .init(start: 2, end: 3, text: "Ja, gern.", speaker: "2"),
            .init(start: 3, end: 4, text: "Dann los.", speaker: "1"),
        ])
        #expect(transcript.hasSpeakers)
        #expect(transcript.finalTextWithSpeakers == "Sprecher 1: Guten Tag. Wir beginnen.\nSprecher 2: Ja, gern.\nSprecher 1: Dann los.")
        #expect(transcript.finalText == "Guten Tag. Wir beginnen. Ja, gern. Dann los.", "fullText bleibt ohne Präfixe")
    }

    @Test func mixedSegmentsWithoutSpeakerJoinOrStartParagraph() {
        let transcript = Transcript(finalSegments: [
            .init(start: 0, end: 1, text: "Vorspann ohne Label."),
            .init(start: 1, end: 2, text: "Hallo.", speaker: "1"),
            .init(start: 2, end: 3, text: "Ohne Label danach."),
            .init(start: 3, end: 4, text: "Weiter.", speaker: "2"),
        ], partialSegments: [.init(start: 4, end: 5, text: "vorläufig")])
        #expect(transcript.finalTextWithSpeakers == "Vorspann ohne Label.\nSprecher 1: Hallo.\nOhne Label danach.\nSprecher 2: Weiter.")
        #expect(transcript.exportText == "Vorspann ohne Label.\nSprecher 1: Hallo.\nOhne Label danach.\nSprecher 2: Weiter.\nvorläufig")
    }

    @Test func withoutSpeakersExportEqualsFullText() {
        let transcript = Transcript(finalSegments: [.init(start: 0, end: 1, text: "A")], partialSegments: [.init(start: 1, end: 2, text: "b")])
        #expect(!transcript.hasSpeakers)
        #expect(transcript.exportText == transcript.fullText)
        #expect(transcript.exportText == "A b")
    }

    @Test func healthDecodesDiarizationAndBackend() throws {
        let health = try JSONDecoder().decode(HealthResponse.self, from: Data("""
        { "status": "ok", "backend": "nemo", "diarization": true }
        """.utf8))
        #expect(health.diarization == true)
        #expect(health.backend == "nemo")
        let plain = try JSONDecoder().decode(HealthResponse.self, from: Data("""
        { "status": "ok" }
        """.utf8))
        #expect(plain.diarization == nil)
    }
}
