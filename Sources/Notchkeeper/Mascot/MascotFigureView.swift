import AppKit
import QuartzCore
import MascotCore

/// Pip layer tree: renders look and submits choreographies from MascotCore to Core Animation.
/// Intermediate frames interpolated by system compositor outside App process; App commits on look change, action start, or mouse target shift (docs/mascot.md §5 "Rendering").
/// Agnostic to where look comes from or when blinks occur (MascotDirector).
///
/// 2D simulation of 3D (docs/mascot.md §1 Option (a)): body is a sphere, eyes wrap spherical surface, movements drive head orientation.
/// stage -> body (breathing, anchor at bottom) -> disc (circular mask, non-rotating) -> gradient + pose -> yaw -> pitch -> roll -> both eyes; stage -> decoration.
/// pose holds stationary look orientation, yaw / pitch neutral values track mouse, actions layer on yaw / pitch / roll.
/// Eye layer anchors at eye center with `anchorPointZ` offset to sphere center, rotated along surface by latitude/longitude; hidden when behind via `isDoubleSided = false`.
@MainActor
final class MascotFigureView: MascotLayerView {
    private let pt: CGFloat
    private let stage = CALayer(), body = CALayer(), disc = CALayer(), gradient = CAGradientLayer()
    private let poseLayer = CATransformLayer(), yawLayer = CATransformLayer(), pitchLayer = CATransformLayer(), rollLayer = CATransformLayer()
    private let eyeLayers = [CAShapeLayer(), CAShapeLayer()]
    private let rests = [Anatomy.leftEye, Anatomy.rightEye]
    private var deco: DecoLayer?

    private(set) var look: Look
    /// Current polygon for both eyes (before scaling): used to align subsequent morphs.
    private var shapes: [EyeOutline]
    /// Retracted left ear and panel: sign decorations moved to right, omitted here.
    private var hidesSigns: Bool
    private var reduceMotion: Bool
    private var gazeTarget = Gaze.rest
    private var peeking = false
    /// Pending entrance animation to play upon becoming visible: during init or when look changed while invisible.
    private var entranceDue: Bool

    /// unit: points per canvas unit. entrance: whether to play entrance animation when first becoming visible.
    init(look: Look, unit: CGFloat, reduceMotion: Bool, entrance: Bool, hidesSigns: Bool) {
        self.look = look
        self.pt = unit
        self.reduceMotion = reduceMotion
        self.hidesSigns = hidesSigns
        entranceDue = entrance
        let e = look.eyes
        shapes = [e.left, e.right]
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: Anatomy.canvas.width * unit, height: Anatomy.canvas.height * unit)))
        build()
    }

    override var unit: CGFloat { pt }

    // MARK: Layer Tree

    private func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - Anatomy.canvas.minX) * pt, y: (p.y - Anatomy.canvas.minY) * pt)
    }

    private var toPoints: CGAffineTransform {
        CGAffineTransform(scaleX: pt, y: pt).translatedBy(x: -Anatomy.canvas.minX, y: -Anatomy.canvas.minY)
    }

    /// Sublayers share size and origin with parent, differing only in anchor point (scale and rotation center).
    private func mount(_ l: CALayer, in parent: CALayer, anchor: CGPoint) {
        let a = point(anchor)
        l.bounds = bounds
        l.anchorPoint = CGPoint(x: a.x / bounds.width, y: a.y / bounds.height)
        l.position = a
        parent.addSublayer(l)
    }

    private func build() {
        guard let root = layer else { preconditionFailure("layer is guaranteed after wantsLayer = true") }
        let c = Anatomy.bodyCenter, r = Anatomy.bodyRadius
        mount(stage, in: root, anchor: c)
        mount(body, in: stage, anchor: CGPoint(x: c.x, y: c.y + r))
        mount(disc, in: body, anchor: c)
        let mask = CAShapeLayer()
        mask.frame = bounds
        var t = toPoints
        mask.path = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: &t)
        disc.mask = mask
        // Rasterizes 3D subtree at screen backing scale (not for caching; disc redraws on motion, see viewDidChangeBackingProperties).
        disc.shouldRasterize = true
        gradient.frame = bounds
        gradient.startPoint = CGPoint(x: 0.5, y: point(CGPoint(x: c.x, y: c.y - r)).y / bounds.height)
        gradient.endPoint = CGPoint(x: 0.5, y: point(CGPoint(x: c.x, y: c.y + r)).y / bounds.height)
        disc.addSublayer(gradient)
        mount(poseLayer, in: disc, anchor: c)
        mount(yawLayer, in: poseLayer, anchor: c)
        mount(pitchLayer, in: yawLayer, anchor: c)
        mount(rollLayer, in: pitchLayer, anchor: c)
        for (l, rest) in zip(eyeLayers, rests) {
            let (pitch, yaw) = Sphere.place(rest)
            l.bounds = bounds
            let a = point(rest)
            l.anchorPoint = CGPoint(x: a.x / bounds.width, y: a.y / bounds.height)
            l.anchorPointZ = -r * pt
            l.position = point(c)
            l.isDoubleSided = false
            // Rotate pitch around x-axis first, then yaw around y-axis; convention matches HeadPose.
            l.transform = CATransform3DConcat(CATransform3DMakeRotation(pitch, 1, 0, 0), CATransform3DMakeRotation(yaw, 0, 1, 0))
            l.fillColor = RGB.ink.cg
            rollLayer.addSublayer(l)
        }
        quietly {
            draw(look)
            settle(nil)
        }
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func eyePath(_ i: Int, _ poly: EyeOutline) -> CGPath {
        let k = Eyes.scale * (follows && peeking ? Choreography.peekEyes : 1)
        let p = CGMutablePath()
        p.addLines(between: poly.map { CGPoint(x: rests[i].x + $0.x * k, y: rests[i].y + $0.y * k).applying(toPoints) })
        p.closeSubpath()
        return p
    }

    private func poseTransform(_ l: Look) -> CATransform3D {
        let p = l.pose
        // Roll first, then pitch, then yaw: matches layer tree nesting order (docs/mascot.md §1).
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeRotation(p.roll, 0, 0, 1), CATransform3DMakeRotation(p.pitch, 1, 0, 0)),
                                   CATransform3DMakeRotation(p.yaw, 0, 1, 0))
    }

    private func makeDeco(_ l: Look) -> DecoLayer? {
        let parts = Self.decoration(l, hidesSigns: hidesSigns)
        guard !parts.isEmpty else { return nil }
        return DecoLayer(parts, in: stage, center: Anatomy.decoCenter, map: toPoints, unit: pt, scale: scale)
    }

    /// Update look appearance immediately without animation.
    private func draw(_ l: Look) {
        gradient.colors = [l.gradient.top.cg, l.gradient.bottom.cg]
        for (i, e) in eyeLayers.enumerated() { e.path = eyePath(i, shapes[i]) }
        poseLayer.transform = poseTransform(l)
        deco?.layer.removeFromSuperlayer()
        deco = makeDeco(l)
    }

    /// When head turns (yaw/pitch != 0), eye contours soften; during expansion Pip tracks mouse on notch, causing eyes to stay blurry.
    /// Inferred to be resampling when 3D subtree flattens to disc; explicit rasterization at screen scale resolves blurriness (docs/mascot.md §5 "Rendering").
    /// @see https://developer.apple.com/documentation/quartzcore/calayer/shouldrasterize
    /// @see https://developer.apple.com/documentation/quartzcore/calayer/rasterizationscale
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        quietly { disc.rasterizationScale = scale }
    }

    override func layer(for part: Part) -> CALayer? {
        switch part {
        case .stage: return stage
        case .body: return body
        case .yaw: return yawLayer
        case .pitch: return pitchLayer
        case .roll: return rollLayer
        case .decoPart(let i): return deco?.parts.indices.contains(i) == true ? deco?.parts[i] : nil
        case .earDot: return nil
        }
    }

    // MARK: Neutral Values: Gaze + Peeking

    /// Only open-eyed looks track mouse; disabled when Reduce Motion is enabled.
    private var follows: Bool { look.opensEyes && !reduceMotion }

    /// Currently tracking mouse (not at rest): suppresses idle micro-movements.
    var isLooking: Bool { follows && gazeTarget != .rest }

    /// Align layer neutral values to current gaze and peek; jumps immediately when how is nil.
    private func settle(_ how: Retarget?) {
        let g = follows ? gazeTarget : .rest
        let targets: [(Part, CALayer, Property, Double)] = [
            (.yaw, yawLayer, .rotationY, g.yaw),
            (.pitch, pitchLayer, .rotationX, g.pitch),
            (.body, body, .scale, follows && peeking ? Choreography.peekScale : 1),
        ]
        var tracks: [Track] = []
        quietly {
            for (part, l, p, new) in targets {
                let old = model(l, p)
                guard abs(old - new) > 1e-9 else { continue }
                setModel(l, p, new)
                if let how, active { tracks.append(Choreography.retarget(part, p, from: old, to: new, how)) }
            }
        }
        play(tracks)
    }

    // MARK: External Invocations

    /// Switch look; hidesSigns provided together: swaps decoration once when both change, avoiding transient flashes.
    func setLook(_ new: Look, hidesSigns h: Bool) {
        guard new != look else { return setHidesSigns(h) }
        hidesSigns = h
        look = new
        let e = new.eyes
        shapes = [Eyes.aligned(e.left, to: shapes[0]), Eyes.aligned(e.right, to: shapes[1])]
        guard active else {
            quietly { draw(new); settle(nil) }
            entranceDue = true
            return
        }
        let c = Choreography.change(reduceMotion: reduceMotion)
        stopLoops(ease: !reduceMotion)
        quietly {
            for (i, eye) in eyeLayers.enumerated() {
                let to = eyePath(i, shapes[i])
                morph(eye, to: to, duration: c.eyeMorph)
                eye.path = to
            }
            let colors = [new.gradient.top.cg, new.gradient.bottom.cg]
            let blend = CABasicAnimation(keyPath: "colors")
            blend.fromValue = gradient.presentation()?.colors ?? gradient.colors
            blend.toValue = colors
            blend.duration = c.colorFade
            blend.timingFunction = Self.function(.sineInOut)
            gradient.add(blend, forKey: "colors")
            gradient.colors = colors
            let pose = poseTransform(new)
            if case .spring(let response, let damping)? = c.pose {
                let s = Self.spring(response: response, damping: damping, keyPath: "transform")
                s.fromValue = poseLayer.presentation()?.transform ?? poseLayer.transform
                s.toValue = pose
                poseLayer.add(s, forKey: "pose")
            }
            poseLayer.transform = pose
            deco?.exit(c, animated: true)
            deco = makeDeco(new)
            deco?.enter(c)
        }
        settle(Choreography.followSpring)
        play(Choreography.entrance(new, reduceMotion: reduceMotion))
        startLoops(loops, delay: c.loopDelay)
    }

    /// Point-by-point path interpolation from current presentation path to target. Cancels ongoing blinks to avoid conflicts.
    private func morph(_ eye: CAShapeLayer, to: CGPath, duration: Double) {
        let a = CABasicAnimation(keyPath: "path")
        a.fromValue = eye.presentation()?.path ?? eye.path
        a.toValue = to
        a.duration = duration
        a.timingFunction = Self.function(.sineInOut)
        eye.removeAnimation(forKey: "blink")
        eye.add(a, forKey: "morph")
    }

    /// Signs reappear when flying to card (e.g. !! on red card) and retract when returning to ear/panel; transitions mirror look decorations.
    private func setHidesSigns(_ on: Bool) {
        guard on != hidesSigns else { return }
        hidesSigns = on
        guard look.isSign else { return }
        guard active else {
            quietly { draw(look) }
            return
        }
        let c = Choreography.change(reduceMotion: reduceMotion)
        stopLoops(ease: false)
        quietly {
            deco?.exit(c, animated: true)
            deco = makeDeco(look)
            deco?.enter(c)
        }
        startLoops(loops, delay: c.loopDelay)
    }

    func setReduceMotion(_ on: Bool) {
        guard on != reduceMotion else { return }
        reduceMotion = on
        quietly {
            for (i, e) in eyeLayers.enumerated() { e.path = eyePath(i, shapes[i]) }
        }
        settle(nil)
        if active {
            stopLoops(ease: false)
            startLoops(loops)
        }
    }

    /// Mouse position in screen coordinates; nil = mouse settled long enough, smoothly resets gaze.
    func follow(mouse: NSPoint?) {
        var g = Gaze.rest
        if let mouse, let window {
            let c = window.convertPoint(toScreen: convert(point(Anatomy.bodyCenter), to: nil))
            // Screen coords have +y up; Gaze expects +y down.
            g = Gaze(toward: CGVector(dx: mouse.x - c.x, dy: c.y - mouse.y))
        }
        guard g != gazeTarget else { return }
        gazeTarget = g
        // Non-tracking looks record target only, applied when returning to a tracking look via settle.
        guard active, follows else { return }
        if mouse == nil {
            settle(Choreography.gazeReturn)
        } else {
            settle(Choreography.followSpring)
        }
    }

    func setPeeking(_ on: Bool) {
        guard on != peeking else { return }
        peeking = on
        guard follows else { return }
        settle(Choreography.peekSpring)
        quietly {
            for (i, eye) in eyeLayers.enumerated() {
                let to = eyePath(i, shapes[i])
                if active { morph(eye, to: to, duration: Choreography.peekEyeMorph) }
                eye.path = to
            }
        }
    }

    /// force: test mode for "play action", executes regardless of current look compatibility.
    func perform(_ cue: Cue, force: Bool = false) {
        guard active else { return }
        switch cue {
        case .blink(let twice):
            guard force || look.opensEyes else { return }
            // Do not blink during morph: path animations conflict on same path property.
            guard eyeLayers.allSatisfy({ $0.animation(forKey: "morph") == nil && $0.animation(forKey: "blink") == nil }) else { return }
            blink(twice: twice)
        case .idle(let m):
            guard force || (look == .idle && !isLooking) else { return }
            play(Choreography.tracks(for: m, reduceMotion: reduceMotion))
        }
    }

    /// Blink: eye polygon interpolates into a slit and reopens (docs/mascot.md §5).
    private func blink(twice: Bool) {
        let close = Choreography.blinkClose, open = Choreography.blinkOpen
        let once = close + open
        let total = twice ? Choreography.secondBlinkAfter + once : once
        for (i, eye) in eyeLayers.enumerated() {
            let o = eyePath(i, shapes[i])
            let s = eyePath(i, Eyes.shut(shapes[i]))
            var keys: [(Double, CGPath)] = [(0, o), (close, s), (once, o)]
            if twice { keys += [(Choreography.secondBlinkAfter, o), (Choreography.secondBlinkAfter + close, s), (total, o)] }
            let a = CAKeyframeAnimation(keyPath: "path")
            a.values = keys.map(\.1)
            a.keyTimes = keys.map { NSNumber(value: $0.0 / total) }
            a.timingFunctions = Array(repeating: Self.function(.sineInOut), count: keys.count - 1)
            a.duration = total
            eye.add(a, forKey: "blink")
        }
    }

    /// Visible decorations: retracted left ear omits sign decorations (moved to right ear). Decoration loops align accordingly.
    nonisolated static func decoration(_ look: Look, hidesSigns: Bool) -> [DecoPart] {
        hidesSigns && look.isSign ? [] : look.decoration
    }

    /// Active loops: only attach to rendered decoration parts.
    nonisolated static func loops(_ look: Look, reduceMotion: Bool, hidesSigns: Bool) -> [Track] {
        let drawn = decoration(look, hidesSigns: hidesSigns).count
        return Choreography.loop(look, reduceMotion: reduceMotion).filter {
            if case .decoPart(let i) = $0.part { return i < drawn } else { return true }
        }
    }

    private var loops: [Track] { Self.loops(look, reduceMotion: reduceMotion, hidesSigns: hidesSigns) }

    // MARK: Visibility

    override func activeChanged(_ on: Bool) {
        guard on else { return }
        settle(nil)
        startLoops(loops)
        if entranceDue {
            entranceDue = false
            play(Choreography.entrance(look, reduceMotion: reduceMotion))
        }
    }
}
