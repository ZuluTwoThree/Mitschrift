import Foundation
import Testing
@testable import MitschriftCore

@Suite struct WAVEncoderTests {
    @Test func headerIs44BytesAndRoundTrips() throws {
        let samples: [Int16] = [0, 1, -1, 32767, -32768, 1234]
        let data = WAVEncoder.wavData(samples: samples)
        #expect(data.count == 44 + samples.count * 2)
        #expect(String(data: data[0..<4], encoding: .ascii) == "RIFF")
        #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")
        let decoded = try #require(WAVEncoder.samples(from: data))
        #expect(decoded == samples)
    }

    @Test func contractSegmentSize() {
        let data = silence(seconds: 2.5)
        #expect(data.count == 44 + 40_000 * 2)
        #expect(data.count < 1_048_576)
        #expect(WAVEncoder.duration(sampleCount: 40_000) == 2.5)
    }

    @Test func rejectsForeignFormat() {
        var data = WAVEncoder.wavData(samples: [1, 2, 3])
        data[22] = 2 // zwei Kanäle
        #expect(WAVEncoder.samples(from: data) == nil)
        #expect(WAVEncoder.samples(from: Data([1, 2, 3])) == nil)
    }
}
