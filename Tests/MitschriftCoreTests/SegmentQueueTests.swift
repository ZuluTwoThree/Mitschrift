import Foundation
import Testing
@testable import MitschriftCore

@Suite struct SegmentQueueTests {
    @Test func enqueuesInOrderAndChecksOutOneAtATime() {
        var queue = SegmentQueue(capacity: 3)
        let accepted0 = queue.enqueue(AudioSegment(sequence: 0, data: Data()))
        let accepted1 = queue.enqueue(AudioSegment(sequence: 1, data: Data()))
        #expect(accepted0 && accepted1)
        let first = queue.checkOut()
        #expect(first?.sequence == 0)
        let none = queue.checkOut()
        #expect(none == nil, "Nur ein Segment darf unterwegs sein")
        queue.acknowledge(sequence: 0)
        let second = queue.checkOut()
        #expect(second?.sequence == 1)
    }

    @Test func rejectsWhenFull() {
        var queue = SegmentQueue(capacity: 2)
        let accepted0 = queue.enqueue(AudioSegment(sequence: 0, data: Data()))
        let accepted1 = queue.enqueue(AudioSegment(sequence: 1, data: Data()))
        let accepted2 = queue.enqueue(AudioSegment(sequence: 2, data: Data()))
        #expect(accepted0 && accepted1)
        #expect(!accepted2)
        #expect(queue.count == 2)
        #expect(queue.isFull)
    }

    @Test func requeueCountsAttemptsAndKeepsOrder() {
        var queue = SegmentQueue(capacity: 5)
        queue.enqueue(AudioSegment(sequence: 0, data: Data()))
        queue.enqueue(AudioSegment(sequence: 1, data: Data()))
        _ = queue.checkOut()
        let firstAttempts = queue.requeue(sequence: 0)
        #expect(firstAttempts == 1)
        _ = queue.checkOut()
        let secondAttempts = queue.requeue(sequence: 0)
        #expect(secondAttempts == 2)
        let next = queue.checkOut()
        #expect(next?.sequence == 0, "Nach Fehler bleibt das Segment vorn")
    }

    @Test func dropRemovesWithoutAcknowledge() {
        var queue = SegmentQueue(capacity: 5)
        queue.enqueue(AudioSegment(sequence: 0, data: Data()))
        queue.enqueue(AudioSegment(sequence: 1, data: Data()))
        _ = queue.checkOut()
        queue.drop(sequence: 0)
        #expect(queue.count == 1)
        #expect(!queue.hasInFlight)
        let next = queue.checkOut()
        #expect(next?.sequence == 1)
    }
}
