import AppKit
import QuartzCore
import MascotCore

/// Shared logic between Pip and right ear: visibility detection, and submitting MascotCore `Track` instances as Core Animation animations.
/// Agnostic to what is drawn (subclasses build layer trees and map `Part` to corresponding layers).
///
/// Visible = externally playing (`playing`), in a window, window neither retracted nor fully occluded, screen neither asleep nor locked (docs/mascot.md §5 "Rendering").
/// SwiftUI retains views inside closed windows, requiring explicit occlusion tracking. When hidden, all animations are removed;
/// resting state is preserved on model layers, resuming loops upon reappearance.
/// @see https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.property
@MainActor
class MascotLayerView: NSView {
    private(set) var active = false
    /// Whether hosting view intends for this layer to render: SwiftUI transparency is not reflected in window occlusion.
    var playing = true {
        didSet { if playing != oldValue { refreshActive() } }
    }
    private var serial = 0
    /// Active loops: target layer, animation key, track, begin media time. Used to compute accumulated animation offset when stopping.
    private var loops: [(layer: CALayer, key: String, track: Track, begin: CFTimeInterval)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("code initialization only") }

    /// Aligns with canvas coordinate system: origin top-left, +y downward. AppKit flips view layers via geometryFlipped.
    /// In practice: rotation.y positive = facing right, rotation.x positive = looking up, rotation.z positive = clockwise.
    /// @see https://developer.apple.com/documentation/quartzcore/calayer/isgeometryflipped
    override var isFlipped: Bool { true }
    /// Click handling handled by outer SwiftUI views.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
    }

    /// @see https://developer.apple.com/documentation/appkit/nswindow/didchangeocclusionstatenotification
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            MascotDirector.shared.attach(self)
        } else {
            MascotDirector.shared.detach(self)
        }
        refreshActive()
    }

    @objc private func occlusionChanged() { refreshActive() }

    /// Shapes and gradients rasterize at screen scale; update on display changes.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        func walk(_ l: CALayer) {
            l.contentsScale = scale
            l.sublayers?.forEach(walk)
            l.mask.map(walk)
        }
        layer?.sublayers?.forEach(walk)
    }

    func refreshActive() {
        let on = playing && window?.occlusionState.contains(.visible) == true && !MascotDirector.shared.paused
        guard on != active else { return }
        active = on
        if !on {
            quietly { layer?.sublayers?.forEach(Self.removeAnimations) }
            loops = []
        }
        activeChanged(on)
        MascotDirector.shared.activityChanged()
    }

    /// Subclass hook: attach loops when becoming visible; all animations stripped prior when becoming invisible.
    func activeChanged(_ on: Bool) {}

    /// Subclass hook: layer targeted by Part.
    func layer(for part: Part) -> CALayer? { nil }

    /// Canvas unit scale: points per unit for coordinate translations.
    var unit: CGFloat { 1 }

    /// Play one-off Tracks immediately.
    func play(_ tracks: [Track]) {
        let now = CACurrentMediaTime()
        for t in tracks { add(t, begin: now, loop: false) }
    }

    /// Attach loops, starting from respective phases after delay seconds. Holds on initial frame before starting:
    /// prevents flashes if first frame differs from neutral value (e.g. Z hidden, Wi-Fi dimmed).
    func startLoops(_ tracks: [Track], delay: Double = 0) {
        let begin = CACurrentMediaTime() + delay
        for t in tracks { add(t, begin: begin, loop: true) }
    }

    /// Remove loops. ease: if true, smoothly interpolates current loop offset back to rest over 0.25s sine curve (e.g. pendulum, searching head).
    func stopLoops(ease: Bool) {
        let now = CACurrentMediaTime()
        var offsets: [ObjectIdentifier: (layer: CALayer, values: [Property: Double])] = [:]
        for l in loops {
            l.layer.removeAnimation(forKey: l.key)
            guard ease else { continue }
            // Loops waiting to start hold on first frame; ease back from there as well.
            offsets[ObjectIdentifier(l.layer), default: (l.layer, [:])].values[l.track.property, default: 0] += l.track.value(at: max(0, now - l.begin))
        }
        loops = []
        for (layer, values) in offsets.values {
            for (p, v) in values where abs(v) > 1e-6 {
                let a = CABasicAnimation(keyPath: Self.keyPath(p))
                a.fromValue = ca(v, p)
                a.toValue = 0
                a.isAdditive = true
                a.duration = 0.25
                a.timingFunction = Self.function(.sineInOut)
                serial += 1
                layer.add(a, forKey: "settle.\(serial)")
            }
        }
    }

    private func add(_ t: Track, begin: CFTimeInterval, loop: Bool) {
        guard let target = layer(for: t.part) else { preconditionFailure("missing layer for: \(t.part)") }
        let values = t.values.map { ca($0, t.property) }
        let a: CAPropertyAnimation
        if case .spring(let response, let damping) = t.timings.first {
            let s = Self.spring(response: response, damping: damping)
            s.fromValue = values[0]
            s.toValue = values[1]
            a = s
        } else {
            let k = CAKeyframeAnimation()
            k.values = values
            k.keyTimes = t.keyTimes.map { NSNumber(value: $0) }
            k.timingFunctions = t.timings.map(Self.function)
            k.duration = t.duration
            a = k
        }
        a.keyPath = Self.keyPath(t.property)
        a.isAdditive = true
        a.beginTime = target.convertTime(begin, from: nil)
        if t.repeats {
            a.repeatCount = .infinity
            a.timeOffset = t.phase
            a.fillMode = .backwards
        }
        serial += 1
        let key = "\(loop ? "loop" : "once").\(serial)"
        target.add(a, forKey: key)
        if loop { loops.append((target, key, t, begin)) }
    }

    /// Mutate model layer without implicit animations: CALayer property changes default to 0.25s implicit animation.
    /// @see https://developer.apple.com/documentation/quartzcore/catransaction/setdisableactions(_:)
    func quietly(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Neutral value in Track units (translations in canvas units). Transform sub-key paths use Core Animation KVC extensions.
    /// Reads decomposed components, recomposes transform on write. Used only for single-axis yaw/pitch rotation and body scale.
    /// @see https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/Key-ValueCodingExtensions/Key-ValueCodingExtensions.html
    func model(_ l: CALayer, _ p: Property) -> Double { Self.value(l, p) / ca(1, p) }

    func setModel(_ l: CALayer, _ p: Property, _ v: Double) {
        l.setValue(ca(v, p), forKeyPath: Self.keyPath(p))
    }

    private func ca(_ v: Double, _ p: Property) -> Double {
        p == .translationX || p == .translationY ? v * unit : v
    }

    private static func value(_ l: CALayer, _ p: Property) -> Double {
        (l.value(forKeyPath: keyPath(p)) as? NSNumber)?.doubleValue ?? 0
    }

    static func keyPath(_ p: Property) -> String {
        switch p {
        case .translationX: return "transform.translation.x"
        case .translationY: return "transform.translation.y"
        case .scaleX: return "transform.scale.x"
        case .scaleY: return "transform.scale.y"
        case .scale: return "transform.scale"
        case .rotationX: return "transform.rotation.x"
        case .rotationY: return "transform.rotation.y"
        case .rotationZ: return "transform.rotation.z"
        case .opacity: return "opacity"
        }
    }

    /// Spring animation: response is perceived duration, damping is damping ratio (docs/mascot.md §5 "Easing").
    /// @see https://developer.apple.com/documentation/quartzcore/caspringanimation
    static func spring(response: Double, damping: Double, keyPath: String? = nil) -> CASpringAnimation {
        let s = CASpringAnimation(keyPath: keyPath)
        s.mass = 1
        s.stiffness = pow(2 * .pi / response, 2)
        s.damping = 4 * .pi * damping / response
        s.duration = s.settlingDuration
        return s
    }

    static func function(_ t: Timing) -> CAMediaTimingFunction {
        guard case .bezier(let a, let b, let c, let d) = t else { preconditionFailure("keyframes cannot contain springs: \(t)") }
        return CAMediaTimingFunction(controlPoints: Float(a), Float(b), Float(c), Float(d))
    }

    private static func removeAnimations(_ l: CALayer) {
        l.removeAllAnimations()
        l.sublayers?.forEach(removeAnimations)
    }
}
