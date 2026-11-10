import Foundation

/// Countdown for temporary cards: pauses when mouse hovers over card, resumes from remaining time when mouse leaves
public struct CardCountdown: Equatable, Sendable {
    public let total: TimeInterval
    private var remainingAtResume: TimeInterval
    /// nil means paused
    private var resumedAt: Date?

    public init(total: TimeInterval, now: Date) {
        self.total = total
        remainingAtResume = total
        resumedAt = now
    }

    public var isPaused: Bool { resumedAt == nil }

    public func remaining(at now: Date) -> TimeInterval {
        guard let r = resumedAt else { return remainingAtResume }
        return max(0, remainingAtResume - now.timeIntervalSince(r))
    }

    public mutating func pause(at now: Date) {
        guard !isPaused else { return }
        remainingAtResume = remaining(at: now)
        resumedAt = nil
    }

    public mutating func resume(at now: Date) {
        guard isPaused else { return }
        resumedAt = now
    }
}
