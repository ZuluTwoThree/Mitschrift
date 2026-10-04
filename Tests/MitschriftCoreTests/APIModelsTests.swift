import Foundation
import Testing
@testable import MitschriftCore

@Suite struct APIModelsTests {
    @Test func decodesSegmentResponseFromContractExample() throws {
        let json = """
        {
          "sessionId": "9b6c2c1e-9d4a-4c4e-9f3c-2a2f1d5c7e10",
          "sequence": 42,
          "windowStart": 97.5,
          "windowEnd": 105.0,
          "final": [ { "start": 97.8, "end": 100.1, "text": "Wir beginnen mit dem zweiten Punkt." } ],
          "partial": [ { "start": 100.4, "end": 104.6, "text": "Dabei geht es um die" } ],
          "diagnostics": { "serverLatencyMs": 420, "realtimeFactor": 0.17, "queuedSegments": 0 }
        }
        """
        let response = try JSONDecoder().decode(SegmentResponse.self, from: Data(json.utf8))
        #expect(response.sequence == 42)
        #expect(response.finalSegments.count == 1)
        #expect(response.partialSegments.first?.text == "Dabei geht es um die")
        #expect(response.diagnostics?.serverLatencyMs == 420)
        #expect(response.windowEnd == 105.0)
    }

    @Test func decodesFinishAndHealth() throws {
        let finish = try JSONDecoder().decode(FinishResponse.self, from: Data("""
        { "sessionId": "x", "lastSequence": 118, "final": [ { "start": 1, "end": 2, "text": "Ende." } ], "partial": [] }
        """.utf8))
        #expect(finish.lastSequence == 118)
        #expect(finish.finalSegments.first?.text == "Ende.")

        let health = try JSONDecoder().decode(HealthResponse.self, from: Data("""
        { "status": "ok", "version": "0.1.0", "model": "ggml-small.bin", "modelLoaded": true, "activeSessions": 1, "maxSessions": 4, "language": "de" }
        """.utf8))
        #expect(health.isHealthy)
        #expect(health.model == "ggml-small.bin")
    }

    @Test func encodesFinalKeyNames() throws {
        let response = SegmentResponse(sessionId: "s", sequence: 1, finalSegments: [.make("a")], partialSegments: [])
        let data = try JSONEncoder().encode(response)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["final"] != nil)
        #expect(object["partial"] != nil)
        #expect(object["finalSegments"] == nil)
    }

    @Test func errorMappingFollowsContract() {
        #expect(LiveTranscriptionError(status: 401, body: nil) == .unauthorized)
        #expect(LiveTranscriptionError(status: 409, body: APIErrorBody(error: "sequence_gap", message: "x")) == .sessionConflict("x"))
        #expect(LiveTranscriptionError(status: 503, body: nil).isRetryable)
        #expect(LiveTranscriptionError(status: 413, body: nil).dropsSegment)
        #expect(LiveTranscriptionError(status: 401, body: nil).endsSession)
        #expect(!LiveTranscriptionError(status: 429, body: nil).endsSession)
        #expect(LiveTranscriptionError(status: 502, body: nil) == .server(status: 502))
        #expect(LiveTranscriptionError(status: 502, body: nil).isRetryable)
        #expect(LiveTranscriptionError(status: 422, body: nil) == .clientError(status: 422))
        #expect(!LiveTranscriptionError(status: 422, body: nil).isRetryable, "4xx außer 429 nie wiederholen")
        #expect(LiveTranscriptionError(status: 403, body: nil).endsSession)
    }
}
