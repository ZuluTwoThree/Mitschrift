import Foundation
import Testing
@testable import MitschriftCore

@Suite struct BackoffAndNamingTests {
    @Test func backoffDoublesAndCaps() {
        let policy = BackoffPolicy(initial: 1, maximum: 30)
        #expect(policy.delay(forAttempt: 1) == 1)
        #expect(policy.delay(forAttempt: 2) == 2)
        #expect(policy.delay(forAttempt: 4) == 8)
        #expect(policy.delay(forAttempt: 10) == 30)
    }

    @Test func recordingNames() {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 2
        components.hour = 18; components.minute = 30; components.second = 5
        let date = Calendar(identifier: .gregorian).date(from: components)!
        #expect(RecordingNaming.recordingFileName(for: date) == "Gespräch-2026-10-02_18-30-05.wav")
        #expect(RecordingNaming.transcriptFileName(forAudioNamed: "Gespräch-2026-10-02_18-30-05.wav") == "Gespräch-2026-10-02_18-30-05-Mitschrift.txt")
        #expect(RecordingNaming.transcriptFileName(forAudioNamed: "Memo.m4a") == "Memo-Mitschrift.txt")
    }

    @Test func elapsedFormatting() {
        #expect(RecordingNaming.elapsedText(0) == "00:00")
        #expect(RecordingNaming.elapsedText(65.9) == "01:05")
        #expect(RecordingNaming.elapsedText(3661) == "1:01:01")
        #expect(RecordingNaming.elapsedText(-5) == "00:00")
    }

    @Test func endpointURLNormalization() {
        #expect(ServerEndpoint.normalizedURL(from: " asr.example.ts.net ")?.absoluteString == "https://asr.example.ts.net")
        #expect(ServerEndpoint.normalizedURL(from: "https://asr.example.ts.net:8443")?.port == 8443)
        #expect(ServerEndpoint.normalizedURL(from: "http://asr.example.ts.net") == nil, "Nur HTTPS")
        #expect(ServerEndpoint.normalizedURL(from: "") == nil)
    }
}
