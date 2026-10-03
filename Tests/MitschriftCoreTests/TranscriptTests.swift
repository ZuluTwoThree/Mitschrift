import Foundation
import Testing
@testable import MitschriftCore

@Suite struct TranscriptTests {
    @Test func finalsAppendAndPartialsReplace() {
        var transcript = Transcript()
        transcript.apply(SegmentResponse(sessionId: "s", sequence: 0, finalSegments: [.make("Guten")], partialSegments: [.make("Tag al")]))
        #expect(transcript.finalText == "Guten")
        #expect(transcript.partialText == "Tag al")

        transcript.apply(SegmentResponse(sessionId: "s", sequence: 1, finalSegments: [.make("Tag")], partialSegments: [.make("allerseits")]))
        #expect(transcript.finalText == "Guten Tag")
        #expect(transcript.partialText == "allerseits")
        #expect(transcript.fullText == "Guten Tag allerseits")
    }

    @Test func finalsAreNeverRewritten() {
        var transcript = Transcript(finalSegments: [.make("Fest")])
        transcript.apply(SegmentResponse(sessionId: "s", sequence: 5, finalSegments: [], partialSegments: [.make("anders")]))
        #expect(transcript.finalSegments == [.make("Fest")])
        transcript.apply(SegmentResponse(sessionId: "s", sequence: 6, finalSegments: [], partialSegments: []))
        #expect(transcript.finalSegments == [.make("Fest")])
        #expect(transcript.partialSegments.isEmpty)
    }

    @Test func finishClearsPartials() {
        var transcript = Transcript(finalSegments: [.make("A")], partialSegments: [.make("B")])
        transcript.apply(FinishResponse(sessionId: "s", lastSequence: 3, finalSegments: [.make("B.")]))
        #expect(transcript.fullText == "A B.")
        #expect(transcript.partialSegments.isEmpty)
    }

    @Test func emptyFinalsAreSkipped() {
        var transcript = Transcript()
        transcript.apply(SegmentResponse(sessionId: "s", sequence: 0, finalSegments: [.make("  "), .make("Text")]))
        #expect(transcript.finalSegments.count == 1)
    }

    @Test func plainTextBecomesSingleFinal() {
        let transcript = Transcript.fromPlainText("  Hallo Welt \n")
        #expect(transcript.finalText == "Hallo Welt")
        #expect(Transcript.fromPlainText("  ").isEmpty)
    }
}
