/// Directs when Pip blinks and performs idle motions. Shared application-wide, synchronizing left ear and panel Pips.
/// Unaware of whether currently idle, visible, or mouse position (App decides whether to query it and whether to play returned cues), and motion aesthetics (`Choreography`).
/// Time and RNG state are passed as arguments: identical seeds and call sequences produce identical outputs.
public struct IdleDirector: Sendable {
    private var nextBlink: Double
    private var nextMotion: Double
    private var rng: SplitMix64
    private var last: Motion?

    /// Blink interval 2.5-6s, 15% double blink; idle motion every 8-20s
    static let blinkGap = 2.5...6.0
    static let doubleBlink = 0.15
    static let motionGap = 8.0...20.0

    public init(seed: UInt64, now: Double) {
        rng = SplitMix64(seed: seed)
        nextBlink = 0
        nextMotion = 0
        resume(at: now)
    }

    public var nextWake: Double { min(nextBlink, nextMotion) }

    /// Cues due up to now; emitted cues rescheduled starting from now
    public mutating func cues(at now: Double) -> [Cue] {
        var out: [Cue] = []
        if now >= nextBlink {
            out.append(.blink(double: Double.random(in: 0..<1, using: &rng) < Self.doubleBlink))
            nextBlink = now + Double.random(in: Self.blinkGap, using: &rng)
        }
        if now >= nextMotion {
            let m = pick()
            last = m
            out.append(.idle(m))
            nextMotion = now + Double.random(in: Self.motionGap, using: &rng)
        }
        return out
    }

    /// When mouse is moving and Pip is tracking it, idle motions are suppressed: waits at least minimum interval after stopping
    public mutating func postponeMotions(until t: Double) {
        nextMotion = max(nextMotion, t + Self.motionGap.lowerBound)
    }

    /// Returning after being invisible: skips accumulated cues, rescheduling from now
    public mutating func resume(at now: Double) {
        nextBlink = now + Double.random(in: Self.blinkGap, using: &rng)
        nextMotion = now + Double.random(in: Self.motionGap, using: &rng)
    }

    /// Weighted selection without repeating the immediate predecessor
    private mutating func pick() -> Motion {
        let pool = Motion.allCases.filter { $0 != last && $0.idleWeight > 0 }
        var r = Double.random(in: 0..<pool.reduce(0) { $0 + $1.idleWeight }, using: &rng)
        for m in pool {
            r -= m.idleWeight
            if r < 0 { return m }
        }
        return pool[pool.count - 1]
    }
}

public enum Cue: Equatable, Sendable {
    case blink(double: Bool)
    case idle(Motion)
}

extension Motion {
    /// Idle motion weights (docs/mascot.md §5): spinAround and flip 5% each, remaining 8 divide 90% equally; finishJump excluded
    var idleWeight: Double {
        switch self {
        case .spinAround, .flip: return 5
        case .finishJump: return 0
        default: return 90.0 / 8
        }
    }
}

/// Reproducible RNG (SplitMix64)
/// @see https://prng.di.unimi.it/splitmix64.c
struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
