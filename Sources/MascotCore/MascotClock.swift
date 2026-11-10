/// Answers: when the shared Pip clock wakes next and what it does upon waking - blinks and idle motions (`IdleDirector`), gaze re-centering after mouse stops,
/// falling drowsy when mouse stays away from the notch, and becoming dizzy briefly when poked (docs/mascot.md §2, §5).
/// Unaware of mouse screen coordinates (App reports proximity and whether Pip looks at it) or Pip visibility (when invisible, App suspends clock ticks, but mouse proximity still resets drowsiness).
/// Time is monotonic seconds passed as arguments; App sets a single timer matching `nextWake` and invokes `tick`.
public struct MascotClock: Sendable {
    /// Mouse absent from notch for this duration induces drowsiness (docs/mascot.md §2)
    public static let drowsyAfter = 120.0
    /// Duration of dizziness after poke
    public static let dizzyFor = 1.6

    public private(set) var drowsy = false
    public var dizzy: Bool { dizzyUntil != nil }

    private var idle: IdleDirector
    private var lastNear: Double
    private var dizzyUntil: Double?
    /// Timestamp when eyes re-center after mouse stops; nil = not tracking mouse
    private var restAt: Double?

    public init(seed: UInt64, now: Double) {
        idle = IdleDirector(seed: seed, now: now)
        lastNear = now
    }

    public var nextWake: Double {
        min(idle.nextWake, restAt ?? .infinity, dizzyUntil ?? .infinity, drowsy ? .infinity : lastNear + Self.drowsyAfter)
    }

    public struct Tick: Equatable, Sendable {
        public var cues: [Cue]
        /// Whether gaze should re-center at this moment: invisible Pips also re-center so they don't glance at stale coordinates when restored
        public var gazeRested: Bool
    }

    /// mouseNear: whether mouse is currently near the notch. Stationary mouse does not generate move events, maintained here
    public mutating func tick(now: Double, mouseNear: Bool) -> Tick {
        if mouseNear { approached(now) }
        if !drowsy, now >= lastNear + Self.drowsyAfter { drowsy = true }
        if let d = dizzyUntil, now >= d { dizzyUntil = nil }
        var rested = false
        if let r = restAt, now >= r {
            restAt = nil
            rested = true
        }
        return Tick(cues: idle.cues(at: now), gazeRested: rested)
    }

    /// near: mouse is near the notch; looking: at least one Pip is tracking mouse. Pauses idle motions while tracking; re-centers 4s after stopping
    public mutating func mouseMoved(near: Bool, looking: Bool, now: Double) {
        if near { approached(now) }
        guard looking else { return }
        restAt = now + Choreography.gazeRestAfter
        idle.postponeMotions(until: now + Choreography.gazeRestAfter)
    }

    /// Mouse tracking disabled: eyes already re-centered, no longer waiting
    public mutating func endGaze() { restAt = nil }

    /// Poked Pip; poking while dizzy resets dizzy timer
    public mutating func poke(now: Double) { dizzyUntil = now + Self.dizzyFor }

    /// All Pips became invisible, clock suspends: dizziness is normally cleared by `tick`; clearing it on suspend prevents masking other looks when restored.
    /// Dizziness is a transient poke response that concludes once invisible.
    public mutating func suspend() { dizzyUntil = nil }

    /// Restored after being invisible: skips accumulated blinks and motions
    public mutating func resume(at now: Double) { idle.resume(at: now) }

    private mutating func approached(_ now: Double) {
        lastNear = now
        drowsy = false
    }
}

extension Look {
    /// Drowsy and dizzy overlay atop plugin-provided looks (docs/mascot.md §2 "Priority": guard > dizzy > agent > sleeping > idle).
    /// Sign looks (guard alerts, error cards) are never masked; only idle look transitions to sleeping
    public func shown(drowsy: Bool, dizzy: Bool) -> Look {
        if isSign { return self }
        if dizzy { return .dizzy }
        return self == .idle && drowsy ? .sleeping : self
    }
}
