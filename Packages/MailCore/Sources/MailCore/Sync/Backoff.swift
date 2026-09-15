import Foundation

/// Exponential backoff with proportional jitter. `attempt` = failures so far (≥ 1; values < 1 treated as 1).
public struct Backoff: Sendable, Equatable {
    public var base: TimeInterval
    public var factor: Double
    public var cap: TimeInterval
    public var jitter: Double

    public init(base: TimeInterval, factor: Double, cap: TimeInterval, jitter: Double) {
        self.base = base
        self.factor = factor
        self.cap = cap
        self.jitter = jitter
    }

    /// `retryAfter` non-nil → returned unchanged (no jitter, no cap); else
    /// `min(cap, base × factor^(attempt−1)) × (1 + jitter × (2·random − 1))`.
    public func delay(attempt: Int, retryAfter: TimeInterval?, random: Double) -> TimeInterval {
        if let retryAfter { return retryAfter }
        let n = max(1, attempt)
        let raw = min(cap, base * pow(factor, Double(n - 1)))
        return raw * (1 + jitter * (2 * random - 1))
    }

    public static let transient = Backoff(base: 1, factor: 2, cap: 16, jitter: 0.25)
    public static let outbox = Backoff(base: 2, factor: 2, cap: 300, jitter: 0.25)
}
