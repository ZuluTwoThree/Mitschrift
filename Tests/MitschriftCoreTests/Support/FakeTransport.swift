import Foundation
@testable import MitschriftCore

/// Skriptbarer Transport: pro Sequenznummer eine Liste von Ergebnissen (Fehler oder Antwort).
final class FakeTransport: LiveTranscriptionTransport, @unchecked Sendable {
    enum Step {
        case fail(LiveTranscriptionError)
        case respond(finals: [Segment], partials: [Segment])
    }

    private let lock = NSLock()
    private var script: [Int: [Step]] = [:]
    private(set) var sentSequences: [Int] = []
    private(set) var finishCalls = 0
    var finishResult: Result<FinishResponse, LiveTranscriptionError>?

    func plan(sequence: Int, _ steps: Step...) {
        lock.lock(); defer { lock.unlock() }
        script[sequence] = steps
    }

    func sendSegment(_ segment: AudioSegment, sessionId: String, language: String) async throws -> SegmentResponse {
        lock.lock()
        sentSequences.append(segment.sequence)
        var steps = script[segment.sequence] ?? []
        let step = steps.isEmpty ? Step.respond(finals: [], partials: []) : steps.removeFirst()
        script[segment.sequence] = steps
        lock.unlock()
        switch step {
        case .fail(let error):
            throw error
        case .respond(let finals, let partials):
            return SegmentResponse(sessionId: sessionId, sequence: segment.sequence, finalSegments: finals, partialSegments: partials)
        }
    }

    func finish(sessionId: String) async throws -> FinishResponse {
        lock.lock(); finishCalls += 1; lock.unlock()
        switch finishResult {
        case .failure(let error): throw error
        case .success(let response): return response
        case nil: return FinishResponse(sessionId: sessionId)
        }
    }

    func health() async throws -> HealthResponse {
        HealthResponse(status: "ok", version: "test", model: "fake", modelLoaded: true, activeSessions: 0, maxSessions: 4, language: "de")
    }
}

extension Segment {
    static func make(_ text: String, at start: Double = 0, length: Double = 1) -> Segment {
        Segment(start: start, end: start + length, text: text)
    }
}

func silence(seconds: Double) -> Data {
    WAVEncoder.wavData(samples: [Int16](repeating: 0, count: Int(seconds * Double(WAVEncoder.sampleRate))))
}
