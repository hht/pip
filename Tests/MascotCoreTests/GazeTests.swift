import CoreGraphics
import Testing
@testable import MascotCore

private let deg = Double.pi / 180

@Suite struct GazeTests {
    private func gaze(_ x: CGFloat, _ y: CGFloat) -> Gaze { Gaze(toward: CGVector(dx: x, dy: y)) }

    /// docs/mascot.md §5 "Follow mouse": linear per axis, yaw 25° * dx / 400, pitch 20° * dy / 400 (dy positive upwards)
    @Test func linearPerAxis() {
        #expect(abs(gaze(200, 0).yaw - 12.5 * deg) < 1e-9 && gaze(200, 0).pitch == 0)
        #expect(abs(gaze(0, -200).pitch - 10 * deg) < 1e-9)
        #expect(abs(gaze(0, 200).pitch + 10 * deg) < 1e-9)
        #expect(gaze(-400, 0).yaw == -25 * deg)
    }

    /// Clamps at maximum angle beyond 400pt, without jumping back to center
    @Test func clampsBeyondReach() {
        #expect(gaze(401, 0).yaw == 25 * deg)
        #expect(gaze(5000, -5000) == gaze(400, -400))
        #expect(gaze(0, 900).pitch == -20 * deg)
    }

    /// Quantized to 0.5°: small movements of 1-2 points keep result constant, preventing App from resubmitting animations
    @Test func quantized() {
        #expect(gaze(200, 40) == gaze(201, 40.5))
        for x in stride(from: -390.0, through: 390, by: 7) {
            let g = gaze(x, x / 3)
            for v in [g.yaw / (0.5 * deg), g.pitch / (0.5 * deg)] { #expect(abs(v - v.rounded()) < 1e-9) }
        }
    }

    @Test func centerRests() {
        #expect(gaze(0, 0) == .rest)
    }
}
