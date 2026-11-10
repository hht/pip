import QuartzCore
import MascotCore

/// A group of decorations: one layer per part, respective anchor points, and entry/exit transitions. The same decoration mounts on Pip top-right and on retracted right ear
/// (40pt decoration matches right ear icon scale: 1 canvas unit = 2pt, docs/mascot.md §2 "Right Ear Indicator").
/// Agnostic to part looping (`Choreography.loop` targets indices, committed by the hosting view).
@MainActor
final class DecoLayer {
    let layer = CALayer()
    private(set) var parts: [CAShapeLayer] = []

    /// map: canvas coordinates -> parent layer coordinates; unit: points per canvas unit (stroke width converted); center: group scale center (canvas coords).
    init(_ deco: [DecoPart], in parent: CALayer, center: CGPoint, map: CGAffineTransform, unit: CGFloat, scale: CGFloat) {
        func mount(_ l: CALayer, in p: CALayer, anchor: CGPoint) {
            let a = anchor.applying(map)
            l.bounds = parent.bounds
            l.anchorPoint = CGPoint(x: a.x / parent.bounds.width, y: a.y / parent.bounds.height)
            l.position = a
            p.addSublayer(l)
        }
        mount(layer, in: parent, anchor: center)
        for d in deco {
            let s = CAShapeLayer()
            mount(s, in: layer, anchor: d.anchor)
            s.contentsScale = scale
            Self.paint(s, d.spec, map: map, unit: unit)
            parts.append(s)
        }
    }

    /// Old decoration scales down and fades out (ease-in), removed upon completion. Completion block runs even when animation is removed, ensuring cleanup.
    /// @see https://developer.apple.com/documentation/quartzcore/catransaction/setcompletionblock(_:)
    func exit(_ c: LookChange, animated: Bool) {
        let l = layer
        guard animated else { return l.removeFromSuperlayer() }
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        var animations: [CAAnimation] = []
        if let s = c.decoExitScale {
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1
            shrink.toValue = s
            animations.append(shrink)
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = (l.presentation() ?? l).opacity
        fade.toValue = 0
        animations.append(fade)
        let g = CAAnimationGroup()
        g.animations = animations
        g.duration = c.decoExit
        g.timingFunction = CAMediaTimingFunction(name: .easeIn)
        l.opacity = 0
        l.add(g, forKey: "exit")
        CATransaction.commit()
    }

    /// Pops up after brief delay: spring scales from 0.4 up to 1 (matching SF Symbols Replace effect), while fading in.
    /// @see https://developer.apple.com/videos/play/wwdc2023/10258/
    func enter(_ c: LookChange) {
        let begin = layer.convertTime(CACurrentMediaTime(), from: nil) + c.decoEnterDelay
        var animations: [CAAnimation] = []
        if case .spring(let response, let damping)? = c.decoPop {
            let pop = MascotLayerView.spring(response: response, damping: damping, keyPath: "transform.scale")
            pop.fromValue = 0.4
            pop.toValue = 1
            animations.append(pop)
        }
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = c.decoFadeIn
        animations.append(appear)
        for a in animations {
            a.beginTime = begin
            a.fillMode = .backwards
            layer.add(a, forKey: nil)
        }
    }

    static func paint(_ l: CAShapeLayer, _ s: ShapeSpec, map: CGAffineTransform, unit: CGFloat) {
        var t = map
        l.path = s.path.copy(using: &t)
        let color = s.color.cg
        switch s.paint {
        case .fill:
            l.fillColor = color
            l.strokeColor = nil
        case .stroke(let w):
            l.fillColor = nil
            l.strokeColor = color
            l.lineWidth = w * unit
        case .fillAndStroke(let w):
            l.fillColor = color
            l.strokeColor = color
            l.lineWidth = w * unit
        }
        l.lineCap = .round
        l.lineJoin = .round
        l.opacity = Float(s.opacity)
    }
}
