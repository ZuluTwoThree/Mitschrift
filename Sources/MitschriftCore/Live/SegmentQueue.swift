import Foundation

/// Begrenzte, geordnete Warteschlange für noch nicht bestätigte Audiosegmente.
///
/// Es ist höchstens ein Segment gleichzeitig unterwegs. Segmente verlassen die
/// Warteschlange erst, wenn der Server sie bestätigt hat. Ist die Warteschlange voll,
/// lehnt `enqueue` ab; der Aufrufer zeigt dann eine pausierte Übertragung an.
public struct SegmentQueue: Sendable {
    public enum Status: Equatable, Sendable {
        case pending
        case inFlight
    }

    public struct Entry: Equatable, Sendable {
        public var segment: AudioSegment
        public var status: Status
        public var attempts: Int
    }

    public let capacity: Int
    public private(set) var entries: [Entry] = []

    public init(capacity: Int = 60) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var isFull: Bool { entries.count >= capacity }
    public var hasInFlight: Bool { entries.contains { $0.status == .inFlight } }
    public var pendingCount: Int { entries.filter { $0.status == .pending }.count }

    /// Hängt ein Segment an. Liefert `false`, wenn kein Platz mehr ist; das Segment wird dann nicht aufgenommen.
    @discardableResult
    public mutating func enqueue(_ segment: AudioSegment) -> Bool {
        guard !isFull else { return false }
        if let last = entries.last {
            precondition(segment.sequence > last.segment.sequence, "Sequenznummern müssen steigen")
        }
        entries.append(Entry(segment: segment, status: .pending, attempts: 0))
        return true
    }

    /// Das nächste zu sendende Segment, falls gerade keines unterwegs ist. Markiert es als `inFlight`.
    public mutating func checkOut() -> AudioSegment? {
        guard !hasInFlight, let index = entries.firstIndex(where: { $0.status == .pending }) else { return nil }
        entries[index].status = .inFlight
        entries[index].attempts += 1
        return entries[index].segment
    }

    /// Entfernt ein bestätigtes Segment.
    public mutating func acknowledge(sequence: Int) {
        entries.removeAll { $0.segment.sequence == sequence }
    }

    /// Stellt ein fehlgeschlagenes Segment zurück in `pending`. Liefert die Zahl der bisherigen Versuche.
    @discardableResult
    public mutating func requeue(sequence: Int) -> Int {
        guard let index = entries.firstIndex(where: { $0.segment.sequence == sequence }) else { return 0 }
        entries[index].status = .pending
        return entries[index].attempts
    }

    /// Verwirft ein Segment endgültig, etwa nach 400 oder 413.
    public mutating func drop(sequence: Int) {
        entries.removeAll { $0.segment.sequence == sequence }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
