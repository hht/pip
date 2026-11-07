import AppKit
import SwiftUI
import MascotCore
import NotchCore

/// 判定在 NotchCore；这里只管文案和颜色（docs/egress-guard.md「怎么画」）
extension GuardPresentation {
    var title: String {
        switch status {
        case .checking: return String(localized: "正在检查出口")
        case .healthy: return String(localized: "出口正常")
        case .mismatch: return String(localized: "出口 IP 不在允许列表里")
        case .offline: return String(localized: "没有网络，暂时检查不了出口")
        case .probeFailed: return String(localized: "暂时判断不了出口")
        case .violated: return Self.violatedTitle
        }
    }

    static var violatedTitle: String { String(localized: "有流量没走代理") }

    var color: Color { Color(nsColor: Self.nsColor(tone)) }

    /// 跟着外观换：刘海窗口固定暗色外观，永远是暗色那套（和 Pip、右耳的配色一致）；设置窗口跟随系统
    static func nsColor(_ tone: Tone) -> NSColor {
        let p = palette(tone)
        return NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? p.dark : p.light
            return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        }
    }

    /// 亮色那套压暗：设置页白底上的状态点也要 3:1（WCAG 1.4.11，docs/ui.md「亮色与暗色」）
    static func palette(_ tone: Tone) -> (dark: RGB, light: RGB) {
        switch tone {
        case .healthy: (RGB(0x30D158), RGB(0x248A3D))
        case .mismatch: (.amber, RGB(0xB25000))
        case .unknown: (.grey, RGB(0x6E6E73))
        case .violated: (.red, RGB(0xD70015))
        }
    }

    /// 出口 IP 的字色：只有 mismatch 用琥珀（IP 本身就是问题），其余浅灰
    var ipColor: Color { tone == .mismatch ? color : .white.opacity(0.6) }
}

/// 状态点：unknown 是灰色空心环，其余是实心点
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
