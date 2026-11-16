import Foundation

/// Reading time uses monotonic samples, independently of the animation driver's
/// deliberately capped scrolling delta. Inactive boundaries accrue no time; long stalls are capped at two seconds.
public struct ActiveReadingClock: Sendable {
    private var last: Double?
    private var wasEligible = false
    public init() {}
    public mutating func sample(now: Double, eligible: Bool) -> Double {
        defer { last = now.isFinite ? now : nil; wasEligible = eligible && now.isFinite }
        guard eligible, wasEligible, now.isFinite, let last, now >= last else { return 0 }
        return min(2, now - last)
    }
    public mutating func reset() { last = nil; wasEligible = false }
}
