import Foundation
import Testing
@testable import MitschriftCore

@Suite @MainActor struct LiveTranscriptionSessionTests {
    private func makeSession(_ transport: FakeTransport, capacity: Int = 60) -> LiveTranscriptionSession {
        LiveTranscriptionSession(
            transport: transport,
            sessionId: "test-session",
            queueCapacity: capacity,
            backoff: BackoffPolicy(initial: 0.001, maximum: 0.002),
            sleeper: { _ in await Task.yield() }
        )
    }

    @Test func sendsInOrderAndMergesTranscript() async {
        let transport = FakeTransport()
        transport.plan(sequence: 0, .respond(finals: [], partials: [.make("Hal")]))
        transport.plan(sequence: 1, .respond(finals: [.make("Hallo")], partials: [.make("Wel")]))
        transport.plan(sequence: 2, .respond(finals: [.make("Welt.")], partials: []))
        let session = makeSession(transport)

        for _ in 0..<3 { session.submit(wavData: silence(seconds: 2.5)) }
        await session.finish()

        #expect(transport.sentSequences == [0, 1, 2])
        #expect(session.transcript.fullText == "Hallo Welt.")
        #expect(session.status == .finished)
        #expect(transport.finishCalls == 1)
        #expect(session.queuedCount == 0)
    }

    @Test func retriesOn503AndKeepsOrder() async {
        let transport = FakeTransport()
        transport.plan(sequence: 0, .fail(.unavailable), .fail(.transport("offline")), .respond(finals: [.make("A")], partials: []))
        transport.plan(sequence: 1, .respond(finals: [.make("B")], partials: []))
        let session = makeSession(transport)

        session.submit(wavData: silence(seconds: 2.5))
        session.submit(wavData: silence(seconds: 2.5))
        await session.finish()

        #expect(transport.sentSequences == [0, 0, 0, 1])
        #expect(session.transcript.finalText == "A B")
        #expect(session.status == .finished)
    }

    @Test func dropsSegmentOn413ButContinues() async {
        let transport = FakeTransport()
        transport.plan(sequence: 0, .fail(.payloadTooLarge))
        transport.plan(sequence: 1, .respond(finals: [.make("B")], partials: []))
        let session = makeSession(transport)

        session.submit(wavData: silence(seconds: 2.5))
        session.submit(wavData: silence(seconds: 2.5))
        await session.finish()

        #expect(session.droppedCount == 1)
        #expect(session.transcript.finalText == "B")
        #expect(session.status == .finished)
    }

    @Test func unauthorizedEndsSessionWithoutFinish() async {
        let transport = FakeTransport()
        transport.plan(sequence: 0, .fail(.unauthorized))
        let session = makeSession(transport)

        session.submit(wavData: silence(seconds: 2.5))
        await session.finish()

        #expect(session.status == .failed(LiveTranscriptionError.unauthorized.userMessage))
        #expect(transport.finishCalls == 0)
        #expect(session.submit(wavData: silence(seconds: 1)) == nil)
    }

    @Test func fullQueuePausesAndRejects() async {
        let transport = FakeTransport()
        transport.plan(sequence: 0, .fail(.unavailable), .fail(.unavailable), .fail(.unavailable), .fail(.unavailable), .fail(.unavailable), .fail(.unavailable))
        let session = makeSession(transport, capacity: 2)

        #expect(session.submit(wavData: silence(seconds: 1)) == 0)
        #expect(session.submit(wavData: silence(seconds: 1)) == 1)
        #expect(session.submit(wavData: silence(seconds: 1)) == nil)
        #expect(session.status == .paused)
        session.cancel()
        #expect(session.status == .finished)
    }

    @Test func finishAppliesRemainingFinals() async {
        let transport = FakeTransport()
        transport.plan(sequence: 0, .respond(finals: [], partials: [.make("unsich")]))
        transport.finishResult = .success(FinishResponse(sessionId: "test-session", lastSequence: 0, finalSegments: [.make("unsicher.")]))
        let session = makeSession(transport)

        session.submit(wavData: silence(seconds: 2.5))
        await session.finish()

        #expect(session.transcript.finalText == "unsicher.")
        #expect(session.transcript.partialSegments.isEmpty)
    }
}
