import Foundation

/// Exponentieller Backoff: 1 s, 2 s, 4 s, … bis zum Maximum.
public struct BackoffPolicy: Equatable, Sendable {
    public var initial: TimeInterval
    public var maximum: TimeInterval
    public var multiplier: Double

    public init(initial: TimeInterval = 1, maximum: TimeInterval = 30, multiplier: Double = 2) {
        self.initial = initial
        self.maximum = maximum
        self.multiplier = multiplier
    }

    /// Wartezeit vor dem `attempt`-ten Wiederholungsversuch (1-basiert).
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return initial }
        let raw = initial * pow(multiplier, Double(attempt - 1))
        return min(raw, maximum)
    }
}
