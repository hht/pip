import Testing
@testable import MascotCore

private let deg = Double.pi / 180

/// All Tracks in choreography (loops, entrances, motions, ear dots)
private func everything(reduceMotion: Bool) -> [Track] {
    let looks = Look.allCases.flatMap { l in
        Choreography.loop(l, reduceMotion: reduceMotion)
            + Choreography.entrance(l, reduceMotion: reduceMotion)
    }
    return looks + Motion.allCases.flatMap { Choreography.tracks(for: $0, reduceMotion: reduceMotion) }
        + Choreography.earDots(reduceMotion: reduceMotion)
}

private func loop(_ l: Look, _ part: Part, _ p: Property) -> Track? {
    Choreography.loop(l, reduceMotion: false).first { $0.part == part && $0.property == p }
}

private func near(_ a: [Double]?, _ b: [Double]) -> Bool {
    guard let a, a.count == b.count else { return false }
    return zip(a, b).allSatisfy { abs($0 - $1) < 1e-9 }
}

@Suite struct TrackShape {
    @Test func everyTrackIsWellFormed() {
        for t in everything(reduceMotion: false) + everything(reduceMotion: true) {
            #expect(t.duration > 0, "\(t)")
            #expect(t.phase >= 0 && t.phase < t.duration, "Phase is within one period: \(t)")
            if case .spring = t.timings.first {
                #expect(t.values.count == 2 && t.timings.count == 1 && !t.repeats, "Spring can only have one segment: \(t)")
            } else {
                #expect(t.keyTimes.count == t.values.count, "\(t)")
                #expect(t.timings.count == t.values.count - 1, "\(t)")
                #expect(t.keyTimes.first == 0 && t.keyTimes.last == 1, "\(t)")
                #expect(zip(t.keyTimes, t.keyTimes.dropFirst()).allSatisfy { $0 <= $1 }, "\(t)")
            }
        }
    }

    /// Animations are additive on top of rest values: one-shot motions must return to 0 when finished (except full rotations), otherwise it will jump when finished
    @Test func oneShotsEndAtRest() {
        for t in everything(reduceMotion: false) where !t.repeats {
            #expect(t.values.last == 0 || isFullTurn(t), "\(t)")
        }
    }

    /// Loops must be seamless, otherwise each cycle starts with a jump. Exceptions: full rotation; 4-point star rotated by 90 deg (looks identical after rotation);
    /// parts that are completely transparent at start/end (Z and sweat drops invisible when returning to origin)
    @Test func loopsAreSeamless() {
        for l in Look.allCases {
            let tracks = Choreography.loop(l, reduceMotion: false)
            for t in tracks where t.values.first != t.values.last {
                let star = l == .finished && t.part == .decoPart(0) && t.property == .rotationZ
                let hidden = tracks.contains { $0.part == t.part && $0.property == .opacity && $0.values.first == -1 && $0.values.last == -1 }
                #expect(isFullTurn(t) || star || hidden, "\(l) \(t)")
            }
        }
    }
}

private func isFullTurn(_ t: Track) -> Bool {
    [.rotationX, .rotationY, .rotationZ].contains(t.property) && abs(abs(t.values.last! - t.values.first!) - 2 * .pi) < 1e-9
}

@Suite struct ReduceMotion {
    /// docs/mascot.md §5 "Reduce Motion": no translation, no scale, no rotation, opacity only
    @Test func onlyOpacity() {
        for t in everything(reduceMotion: true) { #expect(t.property == .opacity, "\(t)") }
    }

    @Test func motionsAndEntrancesAreDropped() {
        for m in Motion.allCases { #expect(Choreography.tracks(for: m, reduceMotion: true).isEmpty) }
        for l in Look.allCases { #expect(Choreography.entrance(l, reduceMotion: true).isEmpty) }
    }

    /// Color and eye shapes fade in/out in 0.15s; orientation set directly
    @Test func change() {
        let c = Choreography.change(reduceMotion: true)
        #expect(c.eyeMorph == 0.15 && c.colorFade == 0.15 && c.pose == nil && c.decoPop == nil && c.loopDelay == 0)
    }
}

@Suite struct LookChangeTests {
    /// docs/mascot.md §5 "Change Look"
    @Test func numbers() {
        let c = Choreography.change(reduceMotion: false)
        #expect(c.eyeMorph == 0.38 && c.colorFade == 0.4)
        #expect(c.pose == .spring(response: 0.5, damping: 0.75))
        #expect(c.decoExit == 0.18 && c.decoExitScale == 0.4)
        #expect(c.decoEnterDelay == 0.1 && c.decoPop == .spring(response: 0.38, damping: 0.6) && c.decoFadeIn == 0.16)
        #expect(c.loopDelay == 0.4)
    }
}

@Suite struct Breathing {
    /// All looks breathe, period 4.6s, scaleY +0.03, scaleX -0.01
    @Test func everyLookBreathes() {
        for l in Look.allCases where l != .sleeping {
            let y = loop(l, .body, .scaleY), x = loop(l, .body, .scaleX)
            #expect(y?.duration == 4.6 && near(y?.values, [0, 0.03, 0]) && near(x?.values, [0, -0.01, 0]), "\(l)")
            #expect(y?.timings == [.sineInOut, .sineInOut])
        }
    }

    /// Sleeping: 6s, scaleY +0.045
    @Test func sleeping() {
        let y = loop(.sleeping, .body, .scaleY)
        #expect(y?.duration == 6 && near(y?.values, [0, 0.045, 0]))
    }
}

@Suite struct HeadLoops {
    /// docs/mascot.md §5 "Body and Head"
    @Test func working() {
        let t = loop(.working, .yaw, .rotationY)
        #expect(t?.duration == 1.4 && t?.phase == 0.45 && near(t?.values, [-7 * deg, 7 * deg, -7 * deg, -7 * deg]))
        #expect(near(t?.keyTimes, [0, 0.9 / 1.4, 1.15 / 1.4, 1]))
    }

    @Test func longTurnReadsFaster() {
        let t = loop(.longTurn, .yaw, .rotationY)
        #expect(t?.duration == 1.0 && t?.phase == 0.3)
    }

    @Test func others() {
        #expect(near(loop(.sleeping, .pitch, .rotationX)?.values, [0, -4 * deg, 0]))
        #expect(loop(.thinking, .yaw, .rotationY)?.duration == 3.6)
        #expect(near(loop(.dizzy, .roll, .rotationZ)?.values, [0, 6 * deg, 0, -6 * deg, 0]))
        #expect(near(loop(.offline, .yaw, .rotationY)?.values, [0, -25 * deg, -25 * deg, 25 * deg, 25 * deg, 0, 0]))
        #expect(loop(.idle, .yaw, .rotationY) == nil)
    }
}

@Suite struct DecoLoops {
    /// Decorative parts referenced in choreography must actually exist
    @Test func referencedPartsExist() {
        for l in Look.allCases {
            let n = l.decoration.count
            for t in Choreography.loop(l, reduceMotion: false) {
                if case .decoPart(let i) = t.part { #expect(i < n, "\(l) \(t)") }
            }
        }
    }

    /// Three Z's, one per second: period 3s, phases 0, 2, 1
    @Test func zzz() {
        let phases = (0..<3).map { loop(.sleeping, .decoPart($0), .translationY)?.phase }
        #expect(phases == [0, 2, 1])
        #expect(near(loop(.sleeping, .decoPart(0), .opacity)?.values, [-1, 0, 0, -1]))
    }

    /// Opacity is converted to additive delta: small star rests at 0.6, flashes to 1, dims to 0.25
    @Test func opacityIsAdditive() {
        #expect(near(loop(.finished, .decoPart(1), .opacity)?.values, [0, 0.4, -0.35, 0]))
        #expect(near(loop(.offline, .decoPart(0), .opacity)?.values, [-0.75, 0, -0.75, -0.75]))
        #expect(loop(.offline, .decoPart(3), .opacity) == nil, "Slash does not move")
    }

    /// Two !'s bounce alternately, second staggered by 0.24s
    @Test func dangerAlternates() {
        #expect(loop(.danger, .decoPart(0), .translationY)?.phase == 0)
        let p = loop(.danger, .decoPart(1), .translationY)?.phase ?? 0
        #expect(abs(p - 0.66) < 1e-9)
    }

    /// Three blue ear dots light up in sequence: period 1.2s, adjacent dots staggered by 0.2s
    @Test func earDots() {
        let t = Choreography.earDots(reduceMotion: false)
        #expect(t.count == 3 && t.allSatisfy { $0.duration == 1.2 && $0.property == .opacity })
        #expect(near(t.map(\.phase), [0, 1.0, 0.8]))
    }
}

@Suite struct Motions {
    /// docs/mascot.md §5 "Motions": only animated components appear
    @Test func channels() {
        let spin = Choreography.tracks(for: .spinAround, reduceMotion: false)
        #expect(spin.count == 1 && spin[0].part == .yaw && near(spin[0].values, [0, 2 * .pi]) && spin[0].duration == 0.9)
        let curious = Choreography.tracks(for: .curious, reduceMotion: false)
        #expect(Set(curious.map(\.part)) == [.yaw, .pitch, .roll])
        let jump = Choreography.tracks(for: .finishJump, reduceMotion: false)
        #expect(Set(jump.map(\.part)) == [.yaw, .stage])
        #expect(near(jump.first { $0.part == .stage }?.values, [0, 1, -4, 0, 0]))
    }

    /// Entering finished jumps, entering working nods, entering danger shakes horizontally 3 times
    @Test func entrances() {
        #expect(Choreography.entrance(.finished, reduceMotion: false) == Choreography.tracks(for: .finishJump, reduceMotion: false))
        #expect(Choreography.entrance(.working, reduceMotion: false) == Choreography.tracks(for: .nod, reduceMotion: false))
        let shake = Choreography.entrance(.danger, reduceMotion: false)
        #expect(shake.count == 1 && shake[0].part == .stage && shake[0].property == .translationX && shake[0].duration == 0.45)
        #expect(Choreography.entrance(.idle, reduceMotion: false).isEmpty)
    }
}

@Suite struct Retarget {
    /// Rest value is already updated to new, additive animation goes from old - new back to 0: visual smoothly transitions from old to new
    @Test func springStartsAtOldAndSettles() {
        let t = Choreography.retarget(.yaw, .rotationY, from: 0.1, to: 0.3, Choreography.followSpring)
        #expect(t.values == [0.1 - 0.3, 0] && t.timings == [.spring(response: 0.3, damping: 0.85)] && t.duration == 0.3)
    }

    /// Return to center after mouse stops: 0.8s sine
    @Test func sineTakesGivenDuration() {
        let t = Choreography.retarget(.pitch, .rotationX, from: 0.2, to: 0, Choreography.gazeReturn)
        #expect(t.values == [0.2, 0] && t.duration == 0.8 && t.timings == [.sineInOut])
    }
}

/// How much a loop adds at a given time: removing a loop only finishes its own tween without touching active springs on the same layer
@Suite struct TrackValue {
    @Test func linearInterpolation() {
        let t = Track.keys(.yaw, .rotationY, [(0, 0), (2, 4)], timing: .linear, repeats: true)
        #expect(abs(t.value(at: 0.5) - 1) < 1e-6)
        #expect(abs(t.value(at: 2.5) - 1) < 1e-6, "Loop: continues calculation past one cycle")
    }

    @Test func phaseShiftsStart() {
        let t = Track.keys(.yaw, .rotationY, [(0, 0), (1, 1), (2, 0)], timing: .linear, phase: 1, repeats: true)
        #expect(abs(t.value(at: 0) - 1) < 1e-6)
    }

    /// Sine easing: half progress at half time, less than a quarter progress at quarter time
    @Test func easing() {
        let t = Track.keys(.yaw, .rotationY, [(0, 0), (1, 1)], repeats: true)
        #expect(abs(t.value(at: 0.5) - 0.5) < 1e-4)
        #expect(t.value(at: 0.25) < 0.2)
    }

    @Test func multiSegment() {
        let t = Choreography.loop(.dizzy, reduceMotion: false).first { $0.part == .roll }!
        #expect(abs(t.value(at: 0.6) - 6 * deg) < 1e-6 && abs(t.value(at: 1.8) + 6 * deg) < 1e-6)
    }
}
