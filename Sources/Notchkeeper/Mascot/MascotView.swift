import AppKit
import SwiftUI
import MascotCore

/// Pip embedding point in SwiftUI.
/// Layout occupies size x size, exactly fitting body circular bounding box; canvas rendered in overlay per docs/mascot.md §1 ratio, decorations overflowing top-right.
/// Selects active look (dizziness, sleepiness overriding passed look); rendering and animations implemented in `MascotFigureView`.
struct MascotView: View {
    let look: Look
    let size: CGFloat
    /// Retracted left ear and panel: sign decorations moved to right, omitted here.
    var hidesSigns = false
    /// false: transparent / invisible (retracted Pip disabled), animations halted, director clock paused.
    var playing = true

    @ObservedObject private var director = MascotDirector.shared
    /// @see https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mascotLiteral) private var literal

    private var shown: Look { literal ? look : director.shown(look) }

    /// Canvas position relative to body bounding box (origin = body top-left), in points. Body box spans 20 x 20 units starting at (4, 6.5) in canvas coordinates.
    private var canvas: (unit: CGFloat, frame: CGRect) {
        let k = size / (2 * Anatomy.bodyRadius)
        let c = Anatomy.canvas
        let x = Anatomy.bodyCenter.x - Anatomy.bodyRadius, y = Anatomy.bodyCenter.y - Anatomy.bodyRadius
        return (k, CGRect(x: (c.minX - x) * k, y: (c.minY - y) * k, width: c.width * k, height: c.height * k))
    }

    var body: some View {
        let c = canvas
        Color.clear
            .frame(width: size, height: size)
            .overlay(alignment: .topLeading) {
                MascotLayer(look: shown, unit: c.unit, reduceMotion: reduceMotion, hidesSigns: hidesSigns, playing: playing)
                    .frame(width: c.frame.width, height: c.frame.height)
                    .offset(x: c.frame.minX, y: c.frame.minY)
                    .allowsHitTesting(false)
            }
            .accessibilityElement()
            .accessibilityLabel("Pip")
            // Pip uses expressions to convey state, announced by VoiceOver (HIG Accessibility).
            .accessibilityValue(shown.title)
    }
}

/// Pip in settings pane displayed on a dark "stage": Pip color palette designed for dark background, nearly invisible on white; avoids splitting look data across light/dark (docs/ui.md "Light and Dark").
/// Padding accommodates top-right decorations.
struct MascotStage: View {
    let look: Look
    let size: CGFloat

    var body: some View {
        MascotView(look: look, size: size)
            .padding(size * 0.35)
            .background(.black, in: RoundedRectangle(cornerRadius: size * 0.4, style: .continuous))
    }
}

private struct MascotLayer: NSViewRepresentable {
    let look: Look
    let unit: CGFloat
    let reduceMotion: Bool
    let hidesSigns: Bool
    let playing: Bool

    func makeNSView(context: Context) -> MascotFigureView {
        let v = MascotFigureView(look: look, unit: unit, reduceMotion: reduceMotion, entrance: true, hidesSigns: hidesSigns)
        v.playing = playing
        return v
    }

    func updateNSView(_ v: MascotFigureView, context: Context) {
        v.playing = playing
        v.setReduceMotion(reduceMotion)
        v.setLook(look, hidesSigns: hidesSigns)
    }
}

/// Set to true during State Testing or on cards: renders exact passed look without dizziness or sleepiness overrides (forced idle does not fall asleep).
/// @see https://developer.apple.com/documentation/swiftui/environmentkey
private struct MascotLiteralKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var mascotLiteral: Bool {
        get { self[MascotLiteralKey.self] }
        set { self[MascotLiteralKey.self] = newValue }
    }
}
