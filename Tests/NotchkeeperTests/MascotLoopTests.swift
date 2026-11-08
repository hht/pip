import Testing
import MascotCore
@testable import Notchkeeper

/// Retracted left ear does not render sign decorations and must not attach loops to these non-existent parts (attaching causes crashes: missing decoration layer on mismatched egress).
@Suite struct MascotLoopTests {
    @Test func hiddenSignsHaveNoDecoLoops() {
        for l in Look.allCases where l.isSign {
            let tracks = MascotFigureView.loops(l, reduceMotion: false, hidesSigns: true)
            #expect(!tracks.contains { if case .decoPart = $0.part { return true } else { return false } }, "\(l)")
            #expect(tracks.contains { $0.part == .body }, "Body still breathes: \(l)")
        }
    }

    /// Mood decorations remain in left ear and loop normally.
    @Test func moodLoopsStay() {
        let tracks = MascotFigureView.loops(.sleeping, reduceMotion: false, hidesSigns: true)
        #expect(tracks == Choreography.loop(.sleeping, reduceMotion: false))
    }
}
