import Foundation
import Testing
@testable import MitschriftCore

@Suite struct SegmentBuilderTests {
    private func ramp(_ count: Int, from start: Int = 0) -> [Int16] {
        (0..<count).map { Int16(truncatingIfNeeded: start + $0) }
    }

    @Test func emitsSegmentsWithOverlap() throws {
        var builder = SegmentBuilder(segmentSeconds: 1.0, overlapSeconds: 0.25, sampleRate: 100)
        // 100 Samples pro Segment, 25 Überlappung → neues Segment alle 75 Samples.
        let first = builder.append(ramp(99))
        #expect(first.isEmpty)
        let second = builder.append(ramp(1, from: 99))
        #expect(second.count == 1)
        let samples1 = try #require(WAVEncoder.samples(from: second[0]))
        #expect(samples1 == ramp(100))

        let third = builder.append(ramp(75, from: 100))
        #expect(third.count == 1)
        let samples2 = try #require(WAVEncoder.samples(from: third[0]))
        #expect(samples2.first == 75, "Zweites Segment beginnt 25 Samples vor Ende des ersten")
        #expect(samples2.count == 100)
        #expect(builder.count == 2)
    }

    @Test func handlesLargeBlocks() {
        var builder = SegmentBuilder(segmentSeconds: 1.0, overlapSeconds: 0.25, sampleRate: 100)
        let output = builder.append(ramp(100 + 75 * 3))
        #expect(output.count == 4)
    }

    @Test func flushEmitsRemainderPaddedToMinimum() throws {
        var builder = SegmentBuilder(segmentSeconds: 1.0, overlapSeconds: 0.25, sampleRate: 100)
        _ = builder.append(ramp(100))
        _ = builder.append(ramp(10, from: 100))
        #expect(builder.pendingSeconds == 0.1)
        let flushed = builder.flush(minimumSeconds: 0.5)
        let data = try #require(flushed)
        let samples = try #require(WAVEncoder.samples(from: data))
        #expect(samples.count == 50)
        #expect(Array(samples.prefix(35)) == ramp(35, from: 75), "Überlappung plus neue Samples")
        #expect(samples.suffix(15).allSatisfy { $0 == 0 })
        let again = builder.flush()
        #expect(again == nil)
    }

    @Test func flushWithoutNewAudioReturnsNil() {
        var builder = SegmentBuilder(segmentSeconds: 1.0, overlapSeconds: 0.25, sampleRate: 100)
        _ = builder.append(ramp(100))
        let flushed = builder.flush()
        #expect(flushed == nil, "Nur der Überlappungsrest ist übrig")
    }

    @Test func contractDefaults() {
        let builder = SegmentBuilder()
        #expect(builder.segmentSamples == 40_000)
        #expect(builder.overlapSamples == 4_800)
    }
}
