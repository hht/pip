import AppKit
import Testing
import MascotCore
import NotchCore
@testable import Notchkeeper

/// Status dots have at least 3:1 contrast against both light and dark backgrounds (WCAG 1.4.11, docs/ui.md "Light and Dark"). Background colors sample common values in settings window.
@Suite struct GuardColorContrast {
    private static let lightBackgrounds = [RGB(0xFFFFFF), RGB(0xF2F2F7), RGB(0xECECEC), RGB(0xE5E5E5)]
    private static let darkBackgrounds = [RGB(0x000000), RGB(0x1E1E1E), RGB(0x2C2C2E), RGB(0x3A3A3C)]

    @Test(arguments: [GuardPresentation.Tone.healthy, .mismatch, .unknown, .violated])
    func dotsReadOnBothAppearances(_ tone: GuardPresentation.Tone) {
        let p = GuardPresentation.palette(tone)
        for bg in Self.lightBackgrounds { #expect(contrast(p.light, bg) >= 3, "\(tone) light \(bg)") }
        for bg in Self.darkBackgrounds { #expect(contrast(p.dark, bg) >= 3, "\(tone) dark \(bg)") }
    }

    /// Notch window uses fixed dark appearance: resolves dark palette, matching Pip and right ear colors.
    @Test @MainActor func notchUsesDarkPalette() {
        let dark = NSAppearance(named: .darkAqua)!
        var resolved: NSColor?
        dark.performAsCurrentDrawingAppearance {
            resolved = GuardPresentation.nsColor(.violated).usingColorSpace(.sRGB)
        }
        let r = GuardPresentation.palette(.violated).dark
        #expect(resolved.map { Int(($0.redComponent * 255).rounded()) } == Int(r.r * 255))
    }

    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        func channel(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func luminance(_ c: RGB) -> Double { 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b) }
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }
}
