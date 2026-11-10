import AppKit
import SwiftUI
import QuartzCore
import MascotCore

/// Right ear indicator (docs/mascot.md §2 "Right Ear Indicator"): Retracted right ear; session row status in panel also rendered with this (docs/ui.md "Panel Layout").
/// `center` is indicator center: three blue dot centers offset -8, -3, +2 from it; 7pt dot and decoration frames center on it.
struct EarIndicatorView: NSViewRepresentable {
    let indicator: EarIndicator
    let size: CGSize
    let center: CGPoint
    /// false: transparent / invisible, stop animations.
    var playing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> EarLayerView {
        let v = EarLayerView(size: size, center: center, indicator: indicator, reduceMotion: reduceMotion)
        v.playing = playing
        return v
    }

    func updateNSView(_ v: EarLayerView, context: Context) {
        v.playing = playing
        v.set(indicator, reduceMotion: reduceMotion)
    }
}

/// Right ear layer: single dot, three dots, grey ring, or look decoration (same scale and animation as 40pt Pip top-right).
/// Indicator transition mirrors Pip decoration: old shrinks and fades out, new pops in.
@MainActor
final class EarLayerView: MascotLayerView {
    private let center: CGPoint
    private var indicator: EarIndicator
    private var reduceMotion: Bool
    private var shown: DecoLayer?

    init(size: CGSize, center: CGPoint, indicator: EarIndicator, reduceMotion: Bool) {
        self.center = center
        self.indicator = indicator
        self.reduceMotion = reduceMotion
        super.init(frame: CGRect(origin: .zero, size: size))
        shown = make()
    }

    func set(_ i: EarIndicator, reduceMotion rm: Bool) {
        guard i != indicator || rm != reduceMotion else { return }
        indicator = i
        reduceMotion = rm
        let c = Choreography.change(reduceMotion: rm)
        stopLoops(ease: false)
        quietly {
            shown?.exit(c, animated: active)
            shown = make()
            if active { shown?.enter(c) }
        }
        if active { startLoops(loops, delay: c.loopDelay) }
    }

    override func layer(for part: Part) -> CALayer? {
        switch part {
        case .decoPart(let i), .earDot(let i): return shown?.parts.indices.contains(i) == true ? shown?.parts[i] : nil
        default: return nil
        }
    }

    override var unit: CGFloat {
        if case .decoration = indicator { return 2 }
        return 1
    }

    override func activeChanged(_ on: Bool) {
        if on { startLoops(loops) }
    }

    /// Decorations only use decoration rhythm (no body or head here).
    private var loops: [Track] {
        switch indicator {
        case .dots: return Choreography.earDots(reduceMotion: reduceMotion)
        case .decoration(let look):
            return Choreography.loop(look, reduceMotion: reduceMotion).filter {
                if case .decoPart = $0.part { return true } else { return false }
            }
        case .none, .dot, .ring: return []
        }
    }

    private func make() -> DecoLayer? {
        guard let root = layer else { preconditionFailure("layer is guaranteed after wantsLayer = true") }
        let scale = window?.backingScaleFactor ?? 2
        func circle(_ c: CGPoint, diameter d: CGFloat, _ paint: Paint, _ color: RGB, opacity: Double = 1) -> DecoPart {
            let r = paint == .fill ? d / 2 : d / 2 - 0.5
            return DecoPart(spec: ShapeSpec(CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil),
                                            paint, color, opacity: opacity), anchor: c)
        }
        let parts: [DecoPart]
        var map = CGAffineTransform.identity
        switch indicator {
        case .none:
            return nil
        case .dots:
            // Diameter 3, centers at x - 8, - 3, + 2 relative to center
            parts = [-8.0, -3, 2].map { circle(CGPoint(x: center.x + $0, y: center.y), diameter: 3, .fill, RGB.working,
                                               opacity: Choreography.earDotRest) }
        case .dot(let color):
            parts = [circle(center, diameter: 7, .fill, color)]
        case .ring:
            // 7pt outer diameter, 1pt stroke
            parts = [circle(center, diameter: 7, .stroke(1), .grey)]
        case .decoration(let look):
            // Center of decoration bounding box aligns with right ear center, 1 canvas unit = 2pt
            parts = look.decoration
            let box = parts.map { $0.spec.path.boundingBoxOfPath }.reduce(CGRect.null) { $0.union($1) }
            map = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: 2, y: 2).translatedBy(x: -box.midX, y: -box.midY)
            return DecoLayer(parts, in: root, center: CGPoint(x: box.midX, y: box.midY), map: map, unit: 2, scale: scale)
        }
        return DecoLayer(parts, in: root, center: center, map: map, unit: 1, scale: scale)
    }
}
