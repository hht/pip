import CoreGraphics

/// What motions Pip performs right now: given a look or motion, outputs declarative `[Track]` submitted to Core Animation.
/// Unaware of layer hierarchy or animation submission (App), or schedule timing (`IdleDirector`, App).
/// All Tracks are additive over layer rest values: values are offsets relative to rest values, allowing pose, gaze, breathing, and motions to compose simultaneously.
/// Empirically verified (macOS 26): two additive animations on the same keypath sum together.
/// Numeric constants follow docs/mascot.md §5.
/// @see https://developer.apple.com/documentation/quartzcore/capropertyanimation/isadditive
public enum Choreography {
    /// Looping motions active while dwelling in a look: body breathing, head idle motions, decoration rhythms
    public static func loop(_ look: Look, reduceMotion: Bool) -> [Track] {
        let tracks = breath(look) + head(look) + deco(look, count: look.decoration.count)
        return reduceMotion ? tracks.filter(\.isStill) : tracks
    }

    /// One-shot motion played upon switching into a look
    public static func entrance(_ look: Look, reduceMotion: Bool) -> [Track] {
        let tracks: [Track]
        switch look {
        case .finished: tracks = Motion.finishJump.tracks
        case .working: tracks = Motion.nod.tracks
        case .danger:
            // 3 horizontal shakes with successive decay
            tracks = [.keys(.stage, .translationX, [(0, 0), (0.075, 1.2), (0.15, -1), (0.225, 0.7), (0.3, -0.4), (0.45, 0)])]
        default: tracks = []
        }
        return reduceMotion ? tracks.filter(\.isStill) : tracks
    }

    public static func tracks(for motion: Motion, reduceMotion: Bool) -> [Track] {
        reduceMotion ? motion.tracks.filter(\.isStill) : motion.tracks
    }

    /// Morphing and transitions between looks across parts
    public static func change(reduceMotion: Bool) -> LookChange {
        if reduceMotion {
            return LookChange(eyeMorph: 0.15, colorFade: 0.15, pose: nil, decoExit: 0.15, decoExitScale: nil,
                              decoEnterDelay: 0, decoPop: nil, decoFadeIn: 0.15, loopDelay: 0)
        }
        return LookChange(eyeMorph: 0.38, colorFade: 0.4, pose: .spring(response: 0.5, damping: 0.75),
                          decoExit: 0.18, decoExitScale: 0.4, decoEnterDelay: 0.1, decoPop: .spring(response: 0.38, damping: 0.6),
                          decoFadeIn: 0.16, loopDelay: 0.4)
    }

    /// 3 blue dots in right ear light up sequentially: rest opacity `earDotRest`, lights to 1, period 1.2s, adjacent phase offset 0.2s
    public static func earDots(reduceMotion: Bool) -> [Track] {
        (0..<3).map { i in
            .keys(.earDot(i), .opacity, [(0, 0), (0.25, 1 - earDotRest), (0.5, 0), (1.2, 0)], phase: 1.2 - 0.2 * Double(i), repeats: true)
        }
    }

    public static let earDotRest = 0.35

    /// Blink: eye shape morphs to flat line and returns (`Eyes.shut`); second blink in double blink follows after 0.25s
    public static let blinkClose = 0.06
    public static let blinkOpen = 0.14
    public static let secondBlinkAfter = 0.25

    /// Rest value changes from old to new (gaze, peek): App sets layer rest value to new, then adds an animation from old - new back to 0.
    /// Additive animations compose seamlessly: switching targets before prior transition finishes maintains visual continuity.
    /// @see https://developer.apple.com/videos/play/wwdc2014/236/
    public static func retarget(_ part: Part, _ property: Property, from old: Double, to new: Double, _ how: Retarget) -> Track {
        switch how {
        case .spring(let response, let damping): return .spring(part, property, from: old - new, .spring(response: response, damping: damping))
        case .sine(let duration): return .keys(part, property, [(0, old - new), (duration, 0)])
        }
    }

    /// Spring for mouse tracking
    public static let followSpring = Retarget.spring(response: 0.3, damping: 0.85)
    /// Duration mouse stays stationary before re-centering gaze, and return duration
    public static let gazeRestAfter = 4.0
    public static let gazeReturn = Retarget.sine(duration: 0.8)
    /// Mouse enters notch ("peek"): body scales up, eyes scale up, spring; eyes morph 0.25s to scaled shape
    public static let peekScale = 1.06
    public static let peekEyes = 1.1
    public static let peekSpring = Retarget.spring(response: 0.35, damping: 0.6)
    public static let peekEyeMorph = 0.25

    private static let deg = Double.pi / 180

    /// Breathing: anchored at body bottom, scaleY +0.03, scaleX -0.01, 4.6s period; sleeping 6s, +0.045
    private static func breath(_ look: Look) -> [Track] {
        let (period, rise) = look == .sleeping ? (6.0, 0.045) : (4.6, 0.03)
        return [.keys(.body, .scaleY, [(0, 0), (period / 2, rise), (period, 0)], repeats: true),
                .keys(.body, .scaleX, [(0, 0), (period / 2, -0.01), (period, 0)], repeats: true)]
    }

    private static func head(_ look: Look) -> [Track] {
        func d(_ keys: [(Double, Double)]) -> [(Double, Double)] { keys.map { ($0.0, $0.1 * deg) } }
        switch look {
        case .sleeping:
            return [.keys(.pitch, .rotationX, d([(0, 0), (3, -4), (6, 0)]), repeats: true)]
        case .thinking:
            // Slow pondering left and right
            return [.keys(.yaw, .rotationY, d([(0, 0), (1.8, -8), (3.6, 0)]), repeats: true)]
        case .working:
            // Reading lines of code: slow horizontal sweep, fast return to line start
            return [.keys(.yaw, .rotationY, d([(0, -7), (0.9, 7), (1.15, -7), (1.4, -7)]), phase: 0.45, repeats: true)]
        case .longTurn:
            return [.keys(.yaw, .rotationY, d([(0, -7), (0.6, 7), (0.8, -7), (1.0, -7)]), phase: 0.3, repeats: true)]
        case .dizzy:
            return [.keys(.roll, .rotationZ, d([(0, 0), (0.6, 6), (1.2, 0), (1.8, -6), (2.4, 0)]), repeats: true)]
        case .offline:
            // Head searches left and right for signal
            return [.keys(.yaw, .rotationY, d([(0, 0), (0.5, -25), (1.2, -25), (1.8, 25), (2.5, 25), (3.0, 0), (3.6, 0)]), repeats: true)]
        default:
            return []
        }
    }

    /// Decoration rhythms. Opacity values are expressed as offsets relative to rest value (`ShapeSpec.opacity`)
    private static func deco(_ look: Look, count n: Int) -> [Track] {
        let parts = (0..<n).map(Part.decoPart)
        switch look {
        case .sleeping:
            // Three Zs emerge, float up, scale up, fade out sequentially, 1/s like snore bubbles
            return parts.enumerated().flatMap { i, z in
                let ph = Double((3 - i) % 3)
                return [Track.keys(z, .translationY, [(0, 0), (3, -2)], timing: .easeOut, phase: ph, repeats: true),
                        .keys(z, .translationX, [(0, 0), (1.5, 0.5), (3, 0)], phase: ph, repeats: true),
                        .keys(z, .scale, [(0, -0.4), (0.6, 0), (3, 0.15)], phase: ph, repeats: true),
                        .keys(z, .opacity, [(0, -1), (0.4, 0), (2.2, 0), (3, -1)], phase: ph, repeats: true)]
            }
        case .thinking:
            // Entire cloud floats gently; three bright dots (rest opacity 0) illuminate sequentially
            return parts.map { .keys($0, .translationY, [(0, 0), (1.2, -0.5), (2.4, 0)], repeats: true) }
                + (0..<3).map { i in .keys(parts[2 + i], .opacity, [(0, 0), (0.2, 1), (0.4, 0), (1.2, 0)], phase: 1.2 - 0.2 * Double(i), repeats: true) }
        case .question:
            // Bubble and ? float up/down; ? wiggles every 2s
            return parts.map { .keys($0, .translationY, [(0, 0), (1, -0.6), (2, 0)], repeats: true) }
                + parts.dropFirst().map { .keys($0, .rotationZ, [(0, 0), (0.12, 0.2), (0.24, -0.2), (0.36, 0.1), (0.48, 0), (2, 0)], repeats: true) }
        case .finished:
            // Large star rotates slowly with flash; small star (rest opacity 0.6) offsets rhythm
            return [.keys(parts[0], .rotationZ, [(0, 0), (2.4, .pi / 2)], timing: .linear, repeats: true),
                    .keys(parts[0], .scale, [(0, 0), (0.6, 0.18), (1.2, 0), (2.4, 0)], repeats: true),
                    .keys(parts[1], .opacity, [(0, 0), (0.6, 0.4), (1.2, -0.35), (2.4, 0)], phase: 1.2, repeats: true)]
        case .longTurn:
            // Sweat drop slides down and fades out
            return [.keys(parts[0], .translationY, [(0, 0), (1.6, 1.6), (2.0, 1.6)], timing: .easeIn, repeats: true),
                    .keys(parts[0], .opacity, [(0, -1), (0.2, 0), (1.3, 0), (1.6, -1), (2.0, -1)], repeats: true)]
        case .approval:
            // Waves twice, pauses briefly
            return [.keys(parts[0], .rotationZ, [(0, 0), (0.2, 0.3), (0.4, -0.15), (0.6, 0.3), (0.8, 0), (2.4, 0)], repeats: true)]
        case .error:
            return [.keys(parts[0], .rotationZ, [(0, 0), (0.08, 0.2), (0.16, -0.2), (0.24, 0.1), (0.32, 0), (2.6, 0)], repeats: true)]
        case .offline:
            // Signal arcs illuminate and dim from inside out sequentially, slash stationary
            return (0..<3).map { i in .keys(parts[i], .opacity, [(0, -0.75), (0.3, 0), (0.9, -0.75), (2.4, -0.75)], phase: 2.4 - 0.3 * Double(i), repeats: true) }
        case .mismatch:
            return parts.map { .keys($0, .scale, [(0, 0), (0.2, 0.12), (0.4, 0), (0.6, 0.12), (0.8, 0), (2.6, 0)], repeats: true) }
        case .stale:
            // Hourglass pauses, flips over, pauses, flips back
            return [.keys(parts[0], .rotationZ, [(0, 0), (1.2, 0), (1.7, .pi), (2.9, .pi), (3.4, 2 * .pi)], repeats: true)]
        case .danger:
            // Two ! marks bounce alternately like an alarm
            return parts.enumerated().map { i, p in
                .keys(p, .translationY, [(0, 0), (0.12, -0.9), (0.24, 0), (0.9, 0)], phase: 0.9 - 0.24 * Double(i), repeats: true)
            }
        case .shielded:
            // Lock clicks shut every 3s: shackle snaps down, body compresses slightly
            return [.keys(parts[0], .translationY, [(0, 0), (0.12, 0.5), (0.3, 0), (3, 0)], repeats: true)]
                + parts.dropFirst().map { .keys($0, .scale, [(0, 0), (0.12, -0.06), (0.3, 0), (3, 0)], repeats: true) }
        case .idle, .working, .interrupted, .dizzy:
            return []
        }
    }
}

/// Transition behavior after rest value changes
public enum Retarget: Equatable, Sendable {
    case spring(response: Double, damping: Double)
    /// Sine easing with given duration
    case sine(duration: Double)
}

/// Part transitions during look change (docs/mascot.md §5 "Change look"). Starting points read from presentation layer
public struct LookChange: Equatable, Sendable {
    /// Duration of point-by-point eye morphing, sine
    public let eyeMorph: Double
    /// Duration of gradient color fade, sine
    public let colorFade: Double
    /// Spring for head rotating to new pose; nil = set directly
    public let pose: Timing?
    /// Old decoration fade-out duration (ease-in), and concurrent scale-down target; nil = fade only
    public let decoExit: Double
    public let decoExitScale: Double?
    /// Delay before new decoration appears; spring popping from 0.4 to 1 (nil = fade in only); fade-in duration
    public let decoEnterDelay: Double
    public let decoPop: Timing?
    public let decoFadeIn: Double
    /// Delay before loop animations start on new look
    public let loopDelay: Double
}

/// A motion sequence layered atop look pose and mouse tracking (docs/mascot.md §5 "Motions")
public enum Motion: CaseIterable, Sendable {
    case spinAround, flip, lookAround, nod, tilt, shake, lookUp, lookDown, sideways, curious, finishJump

    /// Keyframes: time s, yaw°, pitch°, roll°, dy (canvas units, negative = upwards)
    var keys: [(Double, Double, Double, Double, Double)] {
        switch self {
        case .spinAround: return [(0, 0, 0, 0, 0), (0.9, 360, 0, 0, 0)]
        case .flip: return [(0, 0, 0, 0, 0), (0.9, 0, 360, 0, 0)]
        case .lookAround: return [(0, 0, 0, 0, 0), (0.4, -35, 0, 0, 0), (0.9, -35, 0, 0, 0), (1.5, 35, 0, 0, 0), (2.0, 35, 0, 0, 0), (2.4, 0, 0, 0, 0)]
        case .nod: return [(0, 0, 0, 0, 0), (0.18, 0, -18, 0, 0), (0.38, 0, 0, 0, 0), (0.55, 0, -10, 0, 0), (0.75, 0, 0, 0, 0)]
        case .tilt: return [(0, 0, 0, 0, 0), (0.35, 0, 0, 14, 0), (1.4, 0, 0, 14, 0), (1.7, 0, 0, 0, 0)]
        case .shake: return [(0, 0, 0, 0, 0), (0.15, -22, 0, 0, 0), (0.35, 22, 0, 0, 0), (0.52, -14, 0, 0, 0), (0.66, 8, 0, 0, 0), (0.78, 0, 0, 0, 0)]
        case .lookUp: return [(0, 0, 0, 0, 0), (0.45, 0, 35, 0, 0), (1.5, 0, 35, 0, 0), (1.9, 0, 0, 0, 0)]
        case .lookDown: return [(0, 0, 0, 0, 0), (0.45, 0, -35, 0, 0), (1.5, 0, -35, 0, 0), (1.9, 0, 0, 0, 0)]
        case .sideways: return [(0, 0, 0, 0, 0), (0.5, 90, 0, 0, 0), (1.3, 90, 0, 0, 0), (1.7, 0, 0, 0, 0)]
        case .curious: return [(0, 0, 0, 0, 0), (0.4, 30, 12, -10, 0), (1.4, 30, 12, -10, 0), (1.8, 0, 0, 0, 0)]
        case .finishJump: return [(0, 0, 0, 0, 0), (0.12, 0, 0, 0, 1), (0.4, 180, 0, 0, -4), (0.67, 360, 0, 0, 0), (0.8, 360, 0, 0, 0)]
        }
    }

    /// One track per moving channel, sine interpolation between keyframes
    var tracks: [Track] {
        let d = Double.pi / 180
        let channels: [(Part, Property, ((Double, Double, Double, Double, Double)) -> Double)] = [
            (.yaw, .rotationY, { $0.1 * d }), (.pitch, .rotationX, { $0.2 * d }), (.roll, .rotationZ, { $0.3 * d }), (.stage, .translationY, { $0.4 }),
        ]
        return channels.compactMap { part, property, value in
            let values = keys.map(value)
            guard values.contains(where: { $0 != 0 }) else { return nil }
            return .keys(part, property, Array(zip(keys.map(\.0), values)))
        }
    }
}

/// Which layer the animation targets. Layer tree built by App (docs/mascot.md §1): stage ⊃ body ⊃ ... ⊃ pose ⊃ yaw ⊃ pitch ⊃ roll ⊃ eyes; stage ⊃ decorations
public enum Part: Hashable, Sendable {
    /// Whole Pip: shake, jump
    case stage
    /// Body, anchored at bottom: breathing
    case body
    /// Three head rotation layers, layered atop look rest pose: mouse tracking, motions, idle head nods
    case yaw, pitch, roll
    /// Nth decoration piece (index in `Look.decoration`), around its own anchor
    case decoPart(Int)
    /// Nth blue dot in right ear
    case earDot(Int)
}

/// Animated property. Rotations in radians, translations in canvas units; App maps to Core Animation keypaths
public enum Property: Sendable {
    case translationX, translationY, scaleX, scaleY, scale, rotationX, rotationY, rotationZ, opacity
}

public enum Timing: Equatable, Sendable {
    /// Two cubic bezier control points
    case bezier(Double, Double, Double, Double)
    /// response is perceptual duration in seconds, damping is damping ratio. Mapped to CASpringAnimation: mass 1,
    /// stiffness = (2π / response)², damping = 4π * damping / response (docs/mascot.md §5 "Easing")
    case spring(response: Double, damping: Double)

    public static let linear = bezier(0, 0, 1, 1)
    /// Equivalent to kCAMediaTimingFunctionEaseIn / EaseOut
    public static let easeIn = bezier(0.42, 0, 1, 1)
    public static let easeOut = bezier(0, 0, 0.58, 1)
    /// Sine easing @see https://easings.net/#easeInOutSine
    public static let sineInOut = bezier(0.37, 0, 0.63, 1)

    /// Value progress for time progress x (0...1): solves cubic bezier x(s) = x, then evaluates y(s). 40 bisections, precision << 1px
    /// @see https://developer.apple.com/documentation/quartzcore/camediatimingfunction
    func progress(_ x: Double) -> Double {
        guard case .bezier(let x1, let y1, let x2, let y2) = self else { preconditionFailure("Spring has no analytical solution") }
        func bez(_ s: Double, _ a: Double, _ b: Double) -> Double { 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if bez(mid, x1, x2) < x { lo = mid } else { hi = mid }
        }
        return bez((lo + hi) / 2, y1, y2)
    }
}

/// An animation track: a property on a part travels through values over duration (additive over rest value).
/// Springs have single segment: values = [startOffset, 0], duration is perceptual response, actual run duration computed by Core Animation
public struct Track: Equatable, Sendable {
    public var part: Part
    public var property: Property
    public var values: [Double]
    /// 0...1, 1:1 correspondence with values
    public var keyTimes: [Double]
    /// One per segment, one fewer than values
    public var timings: [Timing]
    public var duration: Double
    /// Time offset within loop cycle (seconds, 0 <= phase < duration): offsets rhythms among pieces
    public var phase: Double = 0
    public var repeats = false

    /// Kept when reduceMotion is enabled: translations, scales, rotations count as motion; only opacity remains
    var isStill: Bool { property == .opacity }

    /// Additive offset at elapsed seconds after start (wrapped for loops). App uses this to cleanly wind down loop transitions,
    /// without interrupting concurrent gaze or peek springs on the same layer
    public func value(at elapsed: Double) -> Double {
        guard case .bezier = timings.first else { preconditionFailure("Spring has no analytical solution: \(self)") }
        let t = repeats ? (phase + elapsed).truncatingRemainder(dividingBy: duration) : min(elapsed, duration)
        let u = t / duration
        guard let i = keyTimes.indices.dropFirst().first(where: { keyTimes[$0] >= u }) else { return values[values.count - 1] }
        let span = keyTimes[i] - keyTimes[i - 1]
        let k = span > 0 ? (u - keyTimes[i - 1]) / span : 1
        return values[i - 1] + (values[i] - values[i - 1]) * timings[i - 1].progress(k)
    }

    /// keys are (seconds, value), first time must be 0, last time is duration
    static func keys(_ part: Part, _ property: Property, _ keys: [(Double, Double)], timing: Timing = .sineInOut,
                     phase: Double = 0, repeats: Bool = false) -> Track {
        guard let end = keys.last?.0, end > 0, keys.first?.0 == 0 else { preconditionFailure("Keyframes must start at 0 and have positive duration: \(keys)") }
        return Track(part: part, property: property, values: keys.map(\.1), keyTimes: keys.map { $0.0 / end },
                     timings: Array(repeating: timing, count: keys.count - 1), duration: end,
                     phase: phase.truncatingRemainder(dividingBy: end), repeats: repeats)
    }

    static func spring(_ part: Part, _ property: Property, from: Double, _ timing: Timing) -> Track {
        guard case .spring(let response, _) = timing else { preconditionFailure("Not a spring: \(timing)") }
        return Track(part: part, property: property, values: [from, 0], keyTimes: [0, 1], timings: [timing], duration: response)
    }
}
