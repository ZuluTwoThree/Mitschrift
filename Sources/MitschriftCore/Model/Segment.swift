import Foundation

/// Ein transkribierter Abschnitt mit Zeiten in Sekunden ab Sessionbeginn.
public struct Segment: Codable, Equatable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}
