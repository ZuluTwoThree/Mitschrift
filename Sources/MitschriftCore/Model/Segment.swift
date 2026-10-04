import Foundation

/// Ein transkribierter Abschnitt mit Zeiten in Sekunden ab Sessionbeginn.
///
/// `speaker` ist ein generisches Label („1“, „2“, …) in Reihenfolge des ersten Auftretens innerhalb
/// einer Session; es kommt nur bei finalen Abschnitten und nur mit aktiver Sprechertrennung.
public struct Segment: Codable, Equatable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: String?

    public init(start: Double, end: Double, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}
