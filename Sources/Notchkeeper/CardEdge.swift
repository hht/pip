import AppKit
import NotchCore
import QuartzCore
import SwiftUI

/// Shooting stars along the card edge (docs/ui.md "Card"): After a card pops up and its shape forms, two shooting stars travel along the edge at a constant speed from both top ends down to the bottom center.
/// They complete the sweep in 1.5s and fade out at convergence. Runs once only, does not loop; no longer represents a countdown timer, dwell time follows user settings.
/// When hovered, display turns off, or screen locks, the card pauses and incomplete light halts in place. Persistent red cards have no countdown, or when Reduce Motion is enabled: no sweep,
/// only drawing a faint subtle border in the same tint (matching Dynamic Island's keylineTint).
/// @see https://developer.apple.com/documentation/widgetkit/dynamicisland/keylinetint(_:)
/// Agnostic to what the card content is.
///
/// Follows Magic UI's Border Beam: a gradient color block (transparent -> tint -> bright white) travels along the border path, masked to a single outline stroke,
/// leaving a smooth fading tail that curves around corners. The light sits centered directly on the card edge (view placed outside the card clipping), diffusing soft glow inward and outward.
/// @see https://magicui.design/docs/components/border-beam
/// Positioning handled by Core Animation: a 1.5s along-path keyframe animation, playing from the frame corresponding to elapsed time since card appeared;
/// on pause, animation speed is set to 0, holding at that exact frame. The main thread performs no frame-by-frame redraws (docs/ui.md "Principles").
/// @see https://developer.apple.com/library/archive/qa/qa1673/_index.html
struct CardEdge: NSViewRepresentable {
    /// Same parameters as the shape: path must match card outline precisely.
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    let tint: Color
    /// nil: persistent card
    let countdown: CardCountdown?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> CardEdgeView { CardEdgeView() }

    func updateNSView(_ v: CardEdgeView, context: Context) {
        v.set(shape: NotchShape(topRadius: topRadius, bottomRadius: bottomRadius, closed: false),
              tint: NSColor(tint), countdown: countdown, reduceMotion: reduceMotion)
    }
}

final class CardEdgeView: NSView {
    /// A beam layer: outer layer handles blur, inner layer uses outline stroke mask, containing left and right edge gradients. Masking before blur allows proper glow diffusion.
    private final class Beams {
        let blurred = CALayer()
        let ring = CALayer()
        let mask = CAShapeLayer()
        let left = CAGradientLayer()
        let right = CAGradientLayer()

        init(width: CGFloat, blur: CGFloat, opacity: Float, length: CGFloat) {
            mask.fillColor = nil
            mask.strokeColor = NSColor.white.cgColor
            mask.lineWidth = width
            mask.lineCap = .round
            mask.lineJoin = .round
            ring.mask = mask
            for g in [left, right] {
                g.startPoint = CGPoint(x: 0, y: 0.5)
                g.endPoint = CGPoint(x: 1, y: 0.5)
                // Head at right end: anchor at head, head rides path, tail trails behind.
                g.anchorPoint = CGPoint(x: 1, y: 0.5)
                g.bounds = CGRect(x: 0, y: 0, width: length, height: 24)
                g.locations = [0, 0.55, 0.92, 1]
                // Place off-screen when not sweeping.
                g.position = CGPoint(x: -1000, y: -1000)
                ring.addSublayer(g)
            }
            blurred.addSublayer(ring)
            blurred.opacity = opacity
            if blur > 0 { blurred.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]) as Any] }
        }
    }

    /// Faint keyline for persistent cards.
    private let keyline = CAShapeLayer()
    /// Outer glow around shooting star head: elongated ellipse trailing in direction of travel; unmasked by border, diffuses both inside and outside the edge.
    private let heads = [CAGradientLayer(), CAGradientLayer()]
    /// Solid nucleus of shooting star: distinct teardrop shape, front has bright core thicker than tail, tapering into thin tail; white front, card tint rear, unblurred.
    /// Teardrop is linear, constrained within a narrow band mask along the path: portions deviating on curves get clipped, appearing to bend along the arc.
    private let nuclei = [CAGradientLayer(), CAGradientLayer()]
    private let nucleusBand = CALayer()
    private let nucleusMask = CAShapeLayer()
    /// Shooting star profile = elliptical glow bundle on head + short soft halo near head + long thin trailing core: bright & wide -> tapering -> vanishing.
    private let core = Beams(width: 1, blur: 0, opacity: 1, length: 200)
    private let halo = Beams(width: 4, blur: 3, opacity: 0.6, length: 80)
    private var shape = NotchShape(topRadius: 0, bottomRadius: 0, closed: false)
    private var tint: NSColor?
    private var countdown: CardCountdown?
    private var reduceMotion = false

    /// Head glow width/height; solid nucleus length and radius; blur layer padding margin.
    /// Head glow must not be too long, or it will fling along the tangent on sharp corners.
    private static let headSize = CGSize(width: 18, height: 9)
    /// Teardrop cannot be too long: corner radius is 28pt; longer lengths deviate more on curves; remaining length is handled by curving tail.
    private static let nucleusLength: CGFloat = 16
    private static let nucleusRadius: CGFloat = 1.5
    private static let blurPad: CGFloat = 16
    /// Duration of single shooting star sweep.
    private static let sweep: TimeInterval = 1.5
    /// Wait until card shape is mostly formed after popping up before sweeping, avoiding misaligned corners; matches fade-in delay in `Notch.swift`.
    static let appearDelay: TimeInterval = 0.35

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // Soft glow requires Gaussian blur: layer filters only apply when enabled, rendering in App process; torn down when card retracts.
        // @see https://developer.apple.com/documentation/appkit/nsview/layerusescoreimagefilters
        layerUsesCoreImageFilters = true
        guard let root = layer else { preconditionFailure("layer is guaranteed after wantsLayer = true") }
        root.masksToBounds = false
        keyline.fillColor = nil
        keyline.lineWidth = 1
        root.addSublayer(keyline)
        root.addSublayer(halo.blurred)
        root.addSublayer(core.blurred)
        for h in heads {
            h.type = .radial
            h.startPoint = CGPoint(x: 0.5, y: 0.5)
            h.endPoint = CGPoint(x: 1, y: 1)
            h.locations = [0, 0.25, 1]
            h.bounds = CGRect(origin: .zero, size: Self.headSize)
            // Most of the ellipse trails behind head: glow elongates in travel direction before tapering into tail.
            h.anchorPoint = CGPoint(x: 0.7, y: 0.5)
            h.position = CGPoint(x: -1000, y: -1000)
            h.opacity = 0.7
            root.addSublayer(h)
        }
        // Teardrop: tip on left (tail end), circle on right (head); anchor at circle center riding on path.
        let l = Self.nucleusLength, r = Self.nucleusRadius
        let drop = CGMutablePath()
        drop.move(to: CGPoint(x: 0, y: r))
        drop.addLine(to: CGPoint(x: l, y: 0))
        drop.addArc(center: CGPoint(x: l, y: r), radius: r, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        drop.closeSubpath()
        nucleusMask.fillColor = nil
        nucleusMask.strokeColor = NSColor.white.cgColor
        nucleusMask.lineWidth = 2 * r + 1.2
        nucleusMask.lineCap = .round
        nucleusMask.lineJoin = .round
        nucleusBand.mask = nucleusMask
        root.addSublayer(nucleusBand)
        for n in nuclei {
            n.startPoint = CGPoint(x: 0, y: 0.5)
            n.endPoint = CGPoint(x: 1, y: 0.5)
            n.locations = [0, 0.55, 0.85, 1]
            n.bounds = CGRect(x: 0, y: 0, width: l + r, height: 2 * r)
            n.anchorPoint = CGPoint(x: l / (l + r), y: 0.5)
            n.position = CGPoint(x: -1000, y: -1000)
            let shape = CAShapeLayer()
            shape.path = drop
            n.mask = shape
            nucleusBand.addSublayer(n)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("code initialization only") }

    /// Matches SwiftUI Shape origin at top-left.
    override var isFlipped: Bool { true }
    func set(shape s: NotchShape, tint t: NSColor, countdown c: CardCountdown?, reduceMotion rm: Bool) {
        let changed = t != tint || c != countdown || rm != reduceMotion
        shape = s
        countdown = c
        reduceMotion = rm
        if t != tint {
            tint = t
            // Tail is card tint fading toward end; head is bright white.
            let colors = [t.withAlphaComponent(0), t.withAlphaComponent(0.35), t.blended(withFraction: 0.5, of: .white) ?? t, .white].map(\.cgColor)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for b in [core, halo] { [b.left, b.right].forEach { $0.colors = colors } }
            keyline.strokeColor = t.withAlphaComponent(0.5).cgColor
            // Center bright white, transitioning outward to card tint, then transparent.
            heads.forEach { $0.colors = [NSColor.white.withAlphaComponent(0.8), t.withAlphaComponent(0.35), t.withAlphaComponent(0)].map(\.cgColor) }
            nuclei.forEach { $0.colors = [t.withAlphaComponent(0), t.withAlphaComponent(0.7), NSColor.white, NSColor.white].map(\.cgColor) }
            CATransaction.commit()
        }
        if changed { reshape() }
    }

    /// When card expands with spring animation, recalculate masks and trajectories to new dimensions (animations align by time without jumping).
    override func layout() {
        super.layout()
        reshape()
    }

    private func reshape() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let path = shape.path(in: bounds).cgPath
        // When not sweeping (persistent card, reduce motion), retain only a subtle keyline.
        let flowing = countdown != nil && !reduceMotion
        keyline.frame = bounds
        keyline.path = path
        nucleusBand.frame = bounds
        nucleusMask.frame = bounds
        nucleusMask.path = path
        keyline.isHidden = flowing
        // Blur renders within layer bounds only: extra margin around edges allows light at bottom to bloom outward without being clipped.
        let pad = Self.blurPad
        for b in [core, halo] {
            b.blurred.frame = bounds.insetBy(dx: -pad, dy: -pad)
            b.ring.frame = CGRect(origin: CGPoint(x: pad, y: pad), size: bounds.size)
            b.mask.frame = b.ring.bounds
            b.mask.path = path
            [b.left, b.right].forEach { $0.removeAllAnimations() }
            b.blurred.isHidden = !flowing
        }
        (heads + nuclei).forEach {
            $0.removeAllAnimations()
            $0.isHidden = !flowing
        }
        guard flowing, let c = countdown else { return }
        // Elapsed time counted from moment shape finishes forming; negative if yet to reach, animation starts in future.
        let elapsed = c.total - c.remaining(at: Date()) - Self.appearDelay
        // Sweep completed: do not attach animation (when paused, timeOffset exceeding duration loops back to start).
        guard elapsed < Self.sweep else {
            ([core.blurred, halo.blurred] + heads + nuclei).forEach { $0.isHidden = true }
            return
        }
        // Left beam travels along left half from top to bottom center; right beam mirrors; head faces forward, rotating along path at constant speed.
        let half = shape.leftHalf(in: bounds).cgPath
        var mirror = CGAffineTransform(translationX: bounds.width, y: 0).scaledBy(x: -1, y: 1)
        guard let mirrored = half.copy(using: &mirror) else { preconditionFailure("affine transform copy path always succeeds") }
        let sides = [half, mirrored]
        // Glow bundle and nucleus follow same path and timeline, rotating along path.
        let layers = [core.left, core.right, halo.left, halo.right, heads[0], heads[1], nuclei[0], nuclei[1]]
        for (i, layer) in layers.enumerated() {
            let path = sides[i % 2]
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.calculationMode = .paced
            move.rotationMode = .rotateAuto
            // Fade in at start, fade out before convergence.
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.12, 0.8, 1]
            let once = CAAnimationGroup()
            once.animations = [move, fade]
            once.duration = Self.sweep
            // Active: offset beginTime backward by elapsed time (QA1673 resume animation pattern; timeOffset loops on completion);
            // Paused: speed 0, hold on elapsed frame.
            if c.isPaused {
                once.speed = 0
                once.timeOffset = max(elapsed, 0)
            } else {
                once.beginTime = CACurrentMediaTime() - elapsed
            }
            // Hold on first frame (transparent) before start, hold on last frame (transparent) when finished.
            once.fillMode = .both
            once.isRemovedOnCompletion = false
            layer.add(once, forKey: "once")
        }
    }
}
