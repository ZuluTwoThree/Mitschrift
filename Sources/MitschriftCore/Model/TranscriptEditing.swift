import Foundation

/// Wie eine Audiodatei gekürzt wird, in Sekunden auf der ursprünglichen Zeitachse.
///
/// Vorne und hinten wird abgeschnitten, Bereiche dazwischen werden stummgeschaltet. So bleiben die
/// Zeiten aller behaltenen Abschnitte gültig; sie verschieben sich nur um `leadingCut`.
public struct AudioCutPlan: Equatable, Sendable {
    /// So viele Sekunden fallen am Anfang weg.
    public var leadingCut: Double
    /// Ab hier fällt der Rest weg; `nil` = bis zum Ende behalten.
    public var end: Double?
    /// Stummzuschaltende Bereiche zwischen `leadingCut` und `end`, sortiert und überschneidungsfrei.
    public var muted: [ClosedRange<Double>]

    public init(leadingCut: Double = 0, end: Double? = nil, muted: [ClosedRange<Double>] = []) {
        self.leadingCut = leadingCut
        self.end = end
        self.muted = muted
    }

    public var isEmpty: Bool { leadingCut <= 0 && end == nil && muted.isEmpty }

    /// Länge der gekürzten Datei bei gegebener Originallänge.
    public func resultingDuration(of duration: Double) -> Double {
        max(0, min(end ?? duration, duration) - leadingCut)
    }
}

/// Reine Hilfsfunktionen zum Bearbeiten einer gespeicherten Mitschrift: entfernte Abschnitte in
/// Zeitbereiche der Aufnahme übersetzen, daraus einen Schnittplan machen und die Zeiten anpassen.
public enum TranscriptEditing {
    /// Haben die Abschnitte echte Zeiten? Eine aus reinem Text geladene Mitschrift hat keine, dann
    /// lässt sich die Aufnahme nicht passend kürzen.
    public static func hasTimings(_ segments: [Segment]) -> Bool {
        segments.contains { $0.end > 0 }
    }

    /// Die Zeitbereiche der Aufnahme, die zu entfernten Abschnitten gehören.
    ///
    /// Eine Folge entfernter Abschnitte deckt auch die Pausen bis zu den behaltenen Nachbarn ab, damit
    /// kein Rest des Nebengesprächs übrig bleibt, der nicht erkannt wurde. Zu den Nachbarn bleibt
    /// `padding` Abstand, damit deren erstes und letztes Wort nicht angeschnitten wird. Am Anfang
    /// beginnt der Bereich bei 0, am Ende reicht er bis `duration`.
    ///
    /// - Parameters:
    ///   - segments: die ursprünglichen Abschnitte, nach Startzeit sortiert
    ///   - keep: je Abschnitt, ob er bleibt (gleiche Länge wie `segments`)
    ///   - duration: Länge der Aufnahme in Sekunden
    public static func removedRanges(segments: [Segment], keep: [Bool], duration: Double, padding: Double = 0.25) -> [ClosedRange<Double>] {
        precondition(segments.count == keep.count, "keep braucht einen Eintrag je Abschnitt")
        guard duration > 0 else { return [] }
        var ranges: [ClosedRange<Double>] = []
        var index = 0
        while index < segments.count {
            guard !keep[index] else { index += 1; continue }
            let first = index
            while index < segments.count, !keep[index] { index += 1 }
            let last = index - 1
            let previous = first > 0 ? segments[first - 1] : nil
            let next = index < segments.count ? segments[index] : nil

            var lower = 0.0
            if let previous {
                lower = max(previous.end, min(previous.end + padding, segments[first].start))
            }
            var upper = duration
            if let next {
                upper = min(next.start, max(next.start - padding, segments[last].end))
            }
            lower = min(max(lower, 0), duration)
            upper = min(max(upper, 0), duration)
            if upper > lower { ranges.append(lower...upper) }
        }
        return merge(ranges)
    }

    /// Macht aus entfernten Bereichen einen Schnittplan: Was am Anfang oder Ende liegt, wird
    /// abgeschnitten, alles dazwischen stummgeschaltet.
    public static func cutPlan(removing ranges: [ClosedRange<Double>], duration: Double, tolerance: Double = 0.01) -> AudioCutPlan {
        var remaining = merge(ranges).filter { $0.upperBound > 0 && $0.lowerBound < duration }
        var plan = AudioCutPlan()
        if let first = remaining.first, first.lowerBound <= tolerance {
            plan.leadingCut = min(first.upperBound, duration)
            remaining.removeFirst()
        }
        if let last = remaining.last, last.upperBound >= duration - tolerance {
            plan.end = max(last.lowerBound, plan.leadingCut)
            remaining.removeLast()
        }
        plan.muted = remaining
        return plan
    }

    /// Verschiebt die behaltenen Abschnitte um den Schnitt am Anfang und kappt sie am neuen Ende.
    public static func apply(_ plan: AudioCutPlan, to segments: [Segment]) -> [Segment] {
        segments.map { segment in
            var shifted = segment
            let end = plan.end ?? .infinity
            shifted.start = max(0, min(segment.start, end) - plan.leadingCut)
            shifted.end = max(shifted.start, min(segment.end, end) - plan.leadingCut)
            return shifted
        }
    }

    /// Fasst überlappende oder aneinanderstoßende Bereiche zusammen.
    public static func merge(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
