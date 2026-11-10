import AppKit
import SwiftUI
import MascotCore
import NotchCore

/// Evaluation lives in NotchCore; handles copy and colors here (docs/egress-guard.md "How It Renders").
extension GuardPresentation {
    var title: String {
        switch status {
        case .checking: return String(localized: "Checking egress")
        case .healthy: return String(localized: "Egress OK")
        case .mismatch: return String(localized: "Unexpected egress IP")
        case .offline: return String(localized: "Offline, can't check the egress")
        case .probeFailed: return String(localized: "Can't verify the egress")
        case .violated: return Self.violatedTitle
        }
    }

    static var violatedTitle: String { String(localized: "Traffic is bypassing the proxy") }

    var color: Color { Color(nsColor: Self.nsColor(tone)) }

    /// Adapts to appearance: notch window uses fixed dark appearance, always matching Pip and right ear colors; settings window follows system appearance.
    static func nsColor(_ tone: Tone) -> NSColor {
        let p = palette(tone)
        return NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? p.dark : p.light
            return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        }
    }

    /// Darkened light palette: status dot against light background in settings pane achieves 3:1 contrast (WCAG 1.4.11, docs/ui.md "Light and Dark").
    static func palette(_ tone: Tone) -> (dark: RGB, light: RGB) {
        switch tone {
        case .healthy: (RGB(0x30D158), RGB(0x248A3D))
        case .mismatch: (.amber, RGB(0xB25000))
        case .unknown: (.grey, RGB(0x6E6E73))
        case .violated: (.red, RGB(0xD70015))
        }
    }

    /// Egress IP text color: amber for mismatch only (IP itself is the issue), otherwise light grey.
    var ipColor: Color { tone == .mismatch ? color : .white.opacity(0.6) }
}

/// Status dot: unknown uses hollow grey ring; other tones use solid circle.
struct GuardDot: View {
    let presentation: GuardPresentation
    var size: CGFloat = 7
    var glow = false

    var body: some View {
        let c = presentation.color
        Group {
            if presentation.tone == .unknown {
                Circle().strokeBorder(c, lineWidth: max(1.2, size / 5))
            } else {
                Circle().fill(c).shadow(color: glow ? c.opacity(0.8) : .clear, radius: 3)
            }
        }
        .frame(width: size, height: size)
    }
}
