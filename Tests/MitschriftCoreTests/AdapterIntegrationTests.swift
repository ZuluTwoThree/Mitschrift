import Foundation
import Testing
@testable import MitschriftCore

/// Ende-zu-Ende gegen einen laufenden Adapter. Nur aktiv, wenn `MITSCHRIFT_ADAPTER_URL`,
/// `MITSCHRIFT_ADAPTER_TOKEN` und `MITSCHRIFT_TEST_WAV` gesetzt sind.
private let integrationEnvironment = ProcessInfo.processInfo.environment
private var integrationConfigured: Bool {
    ["MITSCHRIFT_ADAPTER_URL", "MITSCHRIFT_ADAPTER_TOKEN", "MITSCHRIFT_TEST_WAV"].allSatisfy { integrationEnvironment[$0] != nil }
}

@Suite(.enabled(if: integrationConfigured))
@MainActor
struct AdapterIntegrationTests {
    static let env = integrationEnvironment

    private func endpoint() throws -> ServerEndpoint {
        let url = try #require(URL(string: Self.env["MITSCHRIFT_ADAPTER_URL"]!))
        return ServerEndpoint(baseURL: url, token: Self.env["MITSCHRIFT_ADAPTER_TOKEN"]!)
    }

    @Test func healthReportsLoadedModel() async throws {
        let transport = URLSessionLiveTransport(endpoint: try endpoint())
        let health = try await transport.health()
        #expect(health.isHealthy)
        #expect(health.modelLoaded == true)
    }

    @Test func liveSessionTranscribesClipThroughSegments() async throws {
        let wav = try Data(contentsOf: URL(fileURLWithPath: Self.env["MITSCHRIFT_TEST_WAV"]!))
        let samples = try #require(WAVEncoder.samples(from: wav))
        let transport = URLSessionLiveTransport(endpoint: try endpoint())
        let session = LiveTranscriptionSession(transport: transport, language: "de")

        var builder = SegmentBuilder()
        var sawPartial = false
        var finalsSeen = 0
        for segment in builder.append(samples) {
            let sequence = session.submit(wavData: segment)
            #expect(sequence != nil)
            // Auf die Antwort warten, wie es bei Live-Aufnahme mit 2,5-s-Takt der Fall wäre.
            try await waitUntilDrained(session)
            if !session.transcript.partialSegments.isEmpty { sawPartial = true }
            #expect(session.transcript.finalSegments.count >= finalsSeen, "Finals werden nie entfernt")
            finalsSeen = session.transcript.finalSegments.count
        }
        if let rest = builder.flush() { session.submit(wavData: rest) }
        await session.finish()

        #expect(session.status == .finished)
        #expect(session.transcript.partialSegments.isEmpty)
        let text = session.transcript.finalText.lowercased()
        #expect(text.contains("terminplanung"), "Text: \(text)")
        #expect(text.contains("werkstatt"), "Text: \(text)")
        #expect(text.contains("tagesordnung"), "Wort an Finalisierungsgrenze darf nicht abgeschnitten werden. Text: \(text)")
        #expect(sawPartial)
        #expect(finalsSeen > 0, "Während der Aufnahme sollten bereits Finals ankommen")
        #expect(session.lastDiagnostics?.serverLatencyMs != nil)
    }

    private func waitUntilDrained(_ session: LiveTranscriptionSession, timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while session.queuedCount > 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(session.queuedCount == 0, "Server hat nicht rechtzeitig geantwortet")
    }

    @Test func wrongTokenIsRejected() async throws {
        var bad = try endpoint()
        bad.token = "falsch"
        let session = LiveTranscriptionSession(transport: URLSessionLiveTransport(endpoint: bad), language: "de")
        session.submit(wavData: WAVEncoder.wavData(samples: [Int16](repeating: 0, count: 16_000)))
        await session.finish()
        #expect(session.status == .failed(LiveTranscriptionError.unauthorized.userMessage))
    }
}
