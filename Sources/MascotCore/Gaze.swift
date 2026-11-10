import CoreGraphics

/// Pip tracks mouse position: takes mouse displacement relative to body center, outputs head yaw / pitch (radians).
/// Unaware of mouse event sources, re-centering timing (managed by App), or transition animation (`Choreography.followSpring`).
/// Values follow docs/mascot.md §5 "Follow mouse": linear per axis, reaching maximum angle at 400pt and clamping beyond.
public struct Gaze: Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double

    public static let rest = Gaze(yaw: 0, pitch: 0)

    static let reach: CGFloat = 400
    static let maxYaw = 25 * Double.pi / 180
    static let maxPitch = 20 * Double.pi / 180
    /// Quantization step: small mouse movements within 1-2pt yield identical result, sparing App from committing new Core Animation transactions
    static let step = 0.5 * Double.pi / 180

    /// offset: mouse relative to body center in pt, +y downwards
    public init(toward offset: CGVector) {
        func axis(_ v: CGFloat, _ max: Double) -> Double {
            let a = max * Double(Swift.max(-1, Swift.min(1, v / Self.reach)))
            return (a / Self.step).rounded() * Self.step
        }
        yaw = axis(offset.dx, Self.maxYaw)
        // Pitches up when mouse is above (dy < 0)
        pitch = axis(-offset.dy, Self.maxPitch)
    }

    private init(yaw: Double, pitch: Double) {
        self.yaw = yaw
        self.pitch = pitch
    }
}
