import SwiftUI

/// Claude's emblem (sunburst): session rows use this to indicate Claude Code sessions; matches the agent vendor's branding.
/// Agnostic of where or at what size it is drawn. Path and color copied verbatim from Wikimedia Commons "Claude AI symbol.svg", canvas 100 x 100.
/// It is an Anthropic trademark, used solely to identify the session vendor (CLAUDE.md "Brand").
/// Does not load SVG via NSImage: that relies on private `_NSSVGImageRep`, undocumented by Apple.
/// @see https://commons.wikimedia.org/wiki/File:Claude_AI_symbol.svg
struct ClaudeMark: Shape {
    /// Source specifies hsl(14.8, 63.1%, 59.6%)
    static let color = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        return Self.unit.applying(CGAffineTransform(translationX: rect.midX - 50 * s, y: rect.midY - 50 * s).scaledBy(x: s, y: s))
    }

    static let unit = path("m19.6 66.5 19.7-11 .3-1-.3-.5h-1l-3.3-.2-11.2-.3L14 53l-9.5-.5-2.4-.5L0 49l.2-1.5 2-1.3 2.9.2 6.3.5 9.5.6 6.9.4L38 49.1h1.6l.2-.7-.5-.4-.4-.4L29 41l-10.6-7-5.6-4.1-3-2-1.5-2-.6-4.2 2.7-3 3.7.3.9.2 3.7 2.9 8 6.1L37 36l1.5 1.2.6-.4.1-.3-.7-1.1L33 25l-6-10.4-2.7-4.3-.7-2.6c-.3-1-.4-2-.4-3l3-4.2L28 0l4.2.6L33.8 2l2.6 6 4.1 9.3L47 29.9l2 3.8 1 3.4.3 1h.7v-.5l.5-7.2 1-8.7 1-11.2.3-3.2 1.6-3.8 3-2L61 2.6l2 2.9-.3 1.8-1.1 7.7L59 27.1l-1.5 8.2h.9l1-1.1 4.1-5.4 6.9-8.6 3-3.5L77 13l2.3-1.8h4.3l3.1 4.7-1.4 4.9-4.4 5.6-3.7 4.7-5.3 7.1-3.2 5.7.3.4h.7l12-2.6 6.4-1.1 7.6-1.3 3.5 1.6.4 1.6-1.4 3.4-8.2 2-9.6 2-14.3 3.3-.2.1.2.3 6.4.6 2.8.2h6.8l12.6 1 3.3 2 1.9 2.7-.3 2-5.1 2.6-6.8-1.6-16-3.8-5.4-1.3h-.8v.4l4.6 4.5 8.3 7.5L89 80.1l.5 2.4-1.3 2-1.4-.2-9.2-7-3.6-3-8-6.8h-.5v.7l1.8 2.7 9.8 14.7.5 4.5-.7 1.4-2.6 1-2.7-.6-5.8-8-6-9-4.7-8.2-.5.4-2.9 30.2-1.3 1.5-3 1.2-2.5-2-1.4-3 1.4-6.2 1.6-8 1.3-6.4 1.2-7.9.7-2.6v-.2H49L43 72l-9 12.3-7.2 7.6-1.7.7-3-1.5.3-2.8L24 86l10-12.8 6-7.9 4-4.6-.1-.5h-.3L17.2 77.4l-4.7.6-2-2 .2-3 1-1 8-5.5Z")

    /// Only recognizes SVG commands used in this path: M L H V C Z and their lowercase (relative) forms;
    /// extra coordinate pairs following m / M are implicit l / L.
    /// The path is a hardcoded constant; encountering other commands indicates a coding error.
    /// @see https://www.w3.org/TR/SVG2/paths.html#PathData
    static func path(_ d: String) -> Path {
        var tokens = d.matches(of: #/[A-Za-z]|-?(?:\d+\.?\d*|\.\d+)/#).map { String($0.output) }[...]
        var p = Path()
        var at = CGPoint.zero, start = CGPoint.zero
        var command = ""
        func number() -> CGFloat {
            guard let t = tokens.popFirst(), let v = Double(t) else { preconditionFailure("Path coordinate must be a number") }
            return v
        }
        func point(_ relative: Bool) -> CGPoint {
            let x = number(), y = number()
            return relative ? CGPoint(x: at.x + x, y: at.y + y) : CGPoint(x: x, y: y)
        }
        while let next = tokens.first {
            if next.first!.isLetter { command = String(tokens.removeFirst()) }
            // Starts with number, or number follows Z: no command to repeat
            guard let letter = command.first else { preconditionFailure("Path element must be a command") }
            let relative = letter.isLowercase
            switch command.uppercased() {
            case "M":
                at = point(relative); start = at
                p.move(to: at)
                command = relative ? "l" : "L"
            case "L": at = point(relative); p.addLine(to: at)
            case "H": at.x = number() + (relative ? at.x : 0); p.addLine(to: at)
            case "V": at.y = number() + (relative ? at.y : 0); p.addLine(to: at)
            case "C":
                let c1 = point(relative), c2 = point(relative), end = point(relative)
                p.addCurve(to: end, control1: c1, control2: c2)
                at = end
            case "Z":
                p.closeSubpath()
                at = start
                command = ""
            default: preconditionFailure("Unimplemented SVG path command \(command)")
            }
        }
        return p
    }
}
