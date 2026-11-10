import CoreGraphics

// Pip's body and decorations: CGPath and painting methods in canvas coordinates. Unaware of how these shapes animate.
// Coordinates and paths follow docs/mascot.md §1, §4. Units are canvas units, origin top-left, +y downwards.

/// Positions of anatomical parts on the canvas
public enum Anatomy {
    public static let bodyCenter = CGPoint(x: 14, y: 16.5)
    public static let bodyRadius: CGFloat = 10
    public static let leftEye = CGPoint(x: 10.5, y: 17)
    public static let rightEye = CGPoint(x: 17.5, y: 17)
    /// Center of top-right decoration area; serves as anchor when the decoration group pops out
    public static let decoCenter = CGPoint(x: 23.25, y: 4.5)
    /// Canvas frame viewBox -4 -6 40 34: slightly larger than body, decorations overflow top-right. Left ear pip scales down this exact canvas (docs/mascot.md §1)
    public static let canvas = CGRect(x: -4, y: -6, width: 40, height: 34)
}

public enum Paint: Equatable, Sendable {
    case fill
    /// Strokes always have round caps and joins
    case stroke(CGFloat)
    case fillAndStroke(CGFloat)
}

public struct ShapeSpec: Equatable, @unchecked Sendable {
    public let path: CGPath
    public let paint: Paint
    public let color: RGB
    /// Rest opacity; looped opacity animations are superimposed onto it
    public let opacity: Double

    public init(_ path: CGPath, _ paint: Paint = .fill, _ color: RGB = .ink, opacity: Double = 1) {
        self.path = path
        self.paint = paint
        self.color = color
        self.opacity = opacity
    }
}

/// An independently animatable decoration piece with its own anchor (scale/rotation center)
public struct DecoPart: Equatable, Sendable {
    public let spec: ShapeSpec
    public let anchor: CGPoint

    public init(spec: ShapeSpec, anchor: CGPoint) {
        self.spec = spec
        self.anchor = anchor
    }
}

extension Look {
    /// Top-right decorations, ordered by drawing sequence. Indices are fixed: `Choreography` targets animated pieces by index
    public var decoration: [DecoPart] {
        func at(_ anchor: CGPoint, _ specs: [ShapeSpec]) -> [DecoPart] { specs.map { DecoPart(spec: $0, anchor: anchor) } }
        switch self {
        case .sleeping:
            let zs = [(20.0, 4.9, 3.0, 2.2, CGPoint(x: 21.5, y: 6)), (23.5, 1.4, 4.0, 3.2, CGPoint(x: 25.5, y: 3)),
                      (28.5, -3.6, 5.0, 4.2, CGPoint(x: 31, y: -1.5))]
            return zs.map { x, y, w, h, anchor in
                let p = CGMutablePath()
                p.addLines(between: [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x, y: y + h), CGPoint(x: x + w, y: y + h)])
                return DecoPart(spec: ShapeSpec(p, .stroke(0.8), RGB(0xB9C3F0)), anchor: anchor)
            }
        case .thinking:
            let cloud = [CGRect(x: 20.5, y: 3, width: 3, height: 3), CGRect(x: 22.5, y: 1.5, width: 4, height: 4),
                         CGRect(x: 25, y: 3, width: 3, height: 3), CGRect(x: 18.5, y: 5.5, width: 2, height: 2)]
                .map { CGPath(ellipseIn: $0, transform: nil) } + [CGPath(rect: CGRect(x: 22, y: 4, width: 4.5, height: 2), transform: nil)]
            let dot = { (x: CGFloat) in CGPath(ellipseIn: CGRect(x: x - 0.55, y: 4.05, width: 1.1, height: 1.1), transform: nil) }
            // Dim dots always visible, bright dots overlay on top; rest opacity 0, lit in turn by loop
            return at(Anatomy.decoCenter, [ShapeSpec(union(cloud), .fill, RGB(0xE9E2FB), opacity: 0.95),
                                           ShapeSpec(union([22.5, 24.5, 26.5].map(dot)), .fill, RGB(0xBFB2EE))]
                + [22.5, 24.5, 26.5].map { ShapeSpec(dot($0), .fill, RGB(0x7C5CE0), opacity: 0) })
        case .question:
            let tail = CGMutablePath()
            tail.addLines(between: [CGPoint(x: 21, y: 5.5), CGPoint(x: 23, y: 5.5), CGPoint(x: 20.5, y: 8)])
            tail.closeSubpath()
            let bubble = ShapeSpec(union([CGPath(roundedRect: CGRect(x: 20, y: 1, width: 7.5, height: 5), cornerWidth: 2, cornerHeight: 2, transform: nil), tail]),
                                   .fill, RGB(0xCFF3F7))
            let anchor = CGPoint(x: 23.8, y: 3.6)
            let q = CGMutablePath()
            q.move(to: CGPoint(x: 22.75, y: 2.75))
            q.addQuadCurve(to: CGPoint(x: 23.85, y: 1.85), control: CGPoint(x: 22.9, y: 1.85))
            q.addQuadCurve(to: CGPoint(x: 24.85, y: 2.75), control: CGPoint(x: 24.85, y: 1.85))
            q.addQuadCurve(to: CGPoint(x: 24.1, y: 3.7), control: CGPoint(x: 24.85, y: 3.35))
            q.addQuadCurve(to: CGPoint(x: 23.75, y: 4.35), control: CGPoint(x: 23.75, y: 3.9))
            return at(anchor, [bubble, ShapeSpec(q, .stroke(0.55)),
                               ShapeSpec(CGPath(ellipseIn: CGRect(x: 23.75 - 0.32, y: 5.15 - 0.32, width: 0.64, height: 0.64), transform: nil))])
        case .finished:
            return [DecoPart(spec: ShapeSpec(star(center: CGPoint(x: 24.5, y: 3.5), outer: 2.5, inner: 0.75), .fill, RGB(0xFFD66B)),
                             anchor: CGPoint(x: 24.5, y: 3.5)),
                    DecoPart(spec: ShapeSpec(star(center: CGPoint(x: 21, y: 6.5), outer: 1.25, inner: 0.375), .fill, RGB(0xFFD66B), opacity: 0.6),
                             anchor: CGPoint(x: 21, y: 6.5))]
        case .longTurn:
            // Sweat drop
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 23.2, y: 2.8))
            p.addQuadCurve(to: CGPoint(x: 24.3, y: 5.4), control: CGPoint(x: 24.2, y: 4.2))
            p.addArc(center: CGPoint(x: 23.2, y: 5.6), radius: 1.1, startAngle: -0.18, endAngle: .pi + 0.18, clockwise: false)
            p.addQuadCurve(to: CGPoint(x: 23.2, y: 2.8), control: CGPoint(x: 22.2, y: 4.2))
            return at(Anatomy.decoCenter, [ShapeSpec(p, .fill, RGB(0x7CC4F5))])
        case .approval:
            // Raised hand: palm + 4 fingers + thumb
            var parts = [CGPath(roundedRect: CGRect(x: 21.8, y: 4.2, width: 4.6, height: 3.8), cornerWidth: 1.3, cornerHeight: 1.3, transform: nil)]
            for (x, top) in [(21.9, 1.9), (23.05, 1.1), (24.2, 1.3), (25.35, 2.1)] {
                parts.append(CGPath(roundedRect: CGRect(x: x, y: top, width: 0.95, height: 5 - top), cornerWidth: 0.47, cornerHeight: 0.47, transform: nil))
            }
            var t = CGAffineTransform(translationX: 21.9, y: 6.6).rotated(by: -0.6).translatedBy(x: -21.9, y: -6.6)
            parts.append(CGPath(roundedRect: CGRect(x: 20.6, y: 4.6, width: 0.95, height: 2.6), cornerWidth: 0.47, cornerHeight: 0.47, transform: &t))
            return at(CGPoint(x: 24, y: 8), [ShapeSpec(union(parts), .fill, RGB(0xD9EE8C))])
        case .error:
            let p = CGMutablePath()
            p.addLines(between: [CGPoint(x: 22.5, y: 2), CGPoint(x: 26.5, y: 6)])
            p.addLines(between: [CGPoint(x: 26.5, y: 2), CGPoint(x: 22.5, y: 6)])
            return at(CGPoint(x: 24.5, y: 4), [ShapeSpec(p, .stroke(1.1), RGB(0xFF8A3D))])
        case .offline:
            // Wi-Fi sector + slash
            let c = CGPoint(x: 24.5, y: 7.6)
            func arc(_ r: CGFloat) -> CGPath {
                let p = CGMutablePath()
                p.addArc(center: c, radius: r, startAngle: -3 * .pi / 4, endAngle: -.pi / 4, clockwise: false)
                return p
            }
            let slash = CGMutablePath()
            slash.addLines(between: [CGPoint(x: 21, y: 1.4), CGPoint(x: 28, y: 8.2)])
            return at(CGPoint(x: 24.5, y: 5), [ShapeSpec(CGPath(ellipseIn: CGRect(x: c.x - 0.65, y: c.y - 1.05, width: 1.3, height: 1.3), transform: nil), .fill, .grey),
                                               ShapeSpec(arc(2.4), .stroke(0.85), .grey), ShapeSpec(arc(4.2), .stroke(0.85), .grey),
                                               ShapeSpec(slash, .stroke(0.85), RGB(0xC7C7CC))])
        case .mismatch:
            let tri = CGMutablePath()
            tri.addLines(between: [CGPoint(x: 24.5, y: 1.5), CGPoint(x: 28, y: 7.5), CGPoint(x: 21, y: 7.5)])
            tri.closeSubpath()
            let bang = CGMutablePath()
            bang.addRects([CGRect(x: 24, y: 3.5, width: 1, height: 2), CGRect(x: 24, y: 6, width: 1, height: 1)])
            return at(CGPoint(x: 24.5, y: 4.5), [ShapeSpec(tri, .fillAndStroke(0.5), .amber), ShapeSpec(bang)])
        case .stale:
            let p = CGMutablePath()
            p.addRects([CGRect(x: 22, y: 1.5, width: 5, height: 1), CGRect(x: 22, y: 6.5, width: 5, height: 1)])
            p.addLines(between: [CGPoint(x: 22.5, y: 2.5), CGPoint(x: 26.5, y: 2.5), CGPoint(x: 24.5, y: 4.5)])
            p.closeSubpath()
            p.addLines(between: [CGPoint(x: 24.5, y: 4.5), CGPoint(x: 26.5, y: 6.5), CGPoint(x: 22.5, y: 6.5)])
            p.closeSubpath()
            return at(CGPoint(x: 24.5, y: 4.5), [ShapeSpec(p, .fill, RGB(0xB7A27A))])
        case .danger:
            // Two ! marks are two distinct pieces that bounce alternately
            return [21.5, 25].map { x in
                let p = CGMutablePath()
                p.addRects([CGRect(x: x, y: 1.5, width: 1.5, height: 3.5), CGRect(x: x, y: 6, width: 1.5, height: 1.5)])
                return DecoPart(spec: ShapeSpec(p, .fill, .red), anchor: CGPoint(x: x + 0.75, y: 4.5))
            }
        case .shielded:
            // Lock: shackle, body, keyhole
            let shackle = CGMutablePath()
            shackle.move(to: CGPoint(x: 22.8, y: 4.4))
            shackle.addLine(to: CGPoint(x: 22.8, y: 3.0))
            shackle.addArc(center: CGPoint(x: 24.5, y: 3.0), radius: 1.7, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
            shackle.addLine(to: CGPoint(x: 26.2, y: 4.4))
            let hole = CGMutablePath()
            hole.addEllipse(in: CGRect(x: 24.5 - 0.55, y: 5.5, width: 1.1, height: 1.1))
            hole.addRect(CGRect(x: 24.2, y: 6.0, width: 0.6, height: 1.3))
            return at(CGPoint(x: 24.5, y: 5), [ShapeSpec(shackle, .stroke(0.9), RGB(0xFF8A80)),
                                               ShapeSpec(CGPath(roundedRect: CGRect(x: 21.5, y: 4.2, width: 6, height: 4.3), cornerWidth: 1, cornerHeight: 1, transform: nil), .fill, .red),
                                               ShapeSpec(hole)])
        case .idle, .working, .interrupted, .dizzy:
            return []
        }
    }
}

/// Merges shapes of the same color into a single union: overlapping areas won't darken through alpha stacking, nor cut holes from opposing winding directions
/// @see https://developer.apple.com/documentation/coregraphics/cgpath/union(_:using:)
private func union(_ paths: [CGPath]) -> CGPath {
    paths.dropFirst().reduce(paths[0]) { $0.union($1) }
}

/// Four-pointed star: outer vertices up/down/left/right, inner vertices at 45° with inner offset (both stars in docs/mascot.md §4 use this shape)
private func star(center c: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addLines(between: (0..<8).map { i in
        let a = Double(i) * .pi / 4 - .pi / 2
        let r = i % 2 == 0 ? outer : inner * 2.squareRoot()
        return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
    })
    p.closeSubpath()
    return p
}
