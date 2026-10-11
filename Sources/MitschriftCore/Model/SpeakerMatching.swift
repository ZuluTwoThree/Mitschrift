import Foundation

/// Ordnet die Sprecherlabels einer neuen Mitschrift (etwa der genauen Nach-Transkription) den Labels einer
/// bisherigen zu, damit vergebene Namen beim richtigen Sprecher bleiben. Grundlage ist die gemeinsame
/// Sprechzeit: Je neues Label gewinnt das bisherige mit der größten Überlappung, jedes höchstens einmal.
public enum SpeakerMatching {
    public static func relabel(_ segments: [Segment], toMatch reference: [Segment]) -> [Segment] {
        let newLabels = orderedLabels(segments)
        let oldLabels = Set(reference.compactMap(\.speaker))
        guard !newLabels.isEmpty, !oldLabels.isEmpty, TranscriptEditing.hasTimings(reference) else { return segments }

        var overlap: [String: [String: Double]] = [:]
        for new in segments {
            guard let newLabel = new.speaker else { continue }
            for old in reference {
                guard let oldLabel = old.speaker else { continue }
                let shared = min(new.end, old.end) - max(new.start, old.start)
                if shared > 0 { overlap[newLabel, default: [:]][oldLabel, default: 0] += shared }
            }
        }
        // Größte Überlappungen zuerst vergeben, jedes Label nur einmal.
        let pairs = overlap.flatMap { new, olds in olds.map { (new: new, old: $0.key, seconds: $0.value) } }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : ($0.new, $0.old) < ($1.new, $1.old) }
        var mapping: [String: String] = [:]
        var used: Set<String> = []
        for pair in pairs where mapping[pair.new] == nil && !used.contains(pair.old) {
            mapping[pair.new] = pair.old
            used.insert(pair.old)
        }
        // Übrige neue Sprecher bekommen freie Nummern hinter den bisherigen.
        var next = (oldLabels.compactMap(Int.init).max() ?? 0) + 1
        for label in newLabels where mapping[label] == nil {
            while oldLabels.contains(String(next)) || used.contains(String(next)) { next += 1 }
            mapping[label] = String(next)
            used.insert(String(next))
            next += 1
        }
        return segments.map { segment in
            var copy = segment
            copy.speaker = segment.speaker.flatMap { mapping[$0] }
            return copy
        }
    }

    private static func orderedLabels(_ segments: [Segment]) -> [String] {
        var seen: [String] = []
        for label in segments.compactMap(\.speaker) where !seen.contains(label) { seen.append(label) }
        return seen
    }
}
