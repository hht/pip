import CoreGraphics
import Foundation
import Testing
import NotchCore

@Suite struct NotchLayoutRules {
    /// Cards are briefly presented expanded states, same width as dashboard, elements maintain relative positions (docs/ui.md "Cards", HIG Live Activities)
    @Test(arguments: [CGSize(width: 185, height: 32), .zero])
    func cardIsAsWideAsDashboard(notch: CGSize) {
        let card = NotchLayout.size(.card, notch: notch, panel: PanelShape(header: true, list: []), cardContent: NotchLayout.cardRowHeight, ears: true)
        let dashboard = NotchLayout.size(.dashboard, notch: notch, panel: PanelShape(header: true, list: []), cardContent: 0, ears: true)
        #expect(card.width == dashboard.width)
    }

    /// Fullest panel fits within notch window (each section showing 1 row up to section cap, or max total rows)
    @Test(arguments: [CGSize(width: 185, height: 38), CGSize(width: 180, height: 0)])
    func fullestPanelFitsWindow(notch: CGSize) {
        let rows = (0..<10).map { PanelSection(plugin: "p\($0)", rows: Array(repeating: row, count: 9), maxRows: 5) }
        for sections in [rows, rows.map { var s = $0; s.maxRows = 1; return s }] {
            let shape = PanelShape(guardEnabled: true, sections: sections)
            #expect(NotchLayout.size(.dashboard, notch: notch, panel: shape, cardContent: 0, ears: true).height <= NotchLayout.windowSize.height)
        }
    }

    /// Small text (<= 17pt) contrast at least 4.5:1 (HIG Accessibility); sufficient on both black background and 0.06 white container background
    @Test(arguments: [0, 0.06])
    func secondaryTextMeetsContrast(background: Double) {
        let text = background + NotchLayout.secondaryTextOpacity * (1 - background)
        #expect(contrast(text, background) >= 4.5)
    }

    /// WCAG 2 contrast; composited using sRGB encoded values, lower than linear compositing for conservative margin
    private func contrast(_ a: Double, _ b: Double) -> Double {
        func luminance(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }
}

private let row = PanelRow(id: "r", icon: .claude, title: "~/x", indicator: .working, trailing: .value("1"))

/// Panel partitioned into plugin sections (docs/ui.md "Panel Layout"): egress guard at top, remaining sections in order up to their row limits, max 6 rows total
@Suite struct PanelShapes {
    private func section(_ id: String, rows: Int, max: Int = 5) -> PanelSection {
        PanelSection(plugin: id, rows: Array(repeating: row, count: rows), maxRows: max)
    }

    @Test func rowsPerSection() {
        let shape = PanelShape(guardEnabled: true, sections: [section("claude", rows: 2), section("dl", rows: 7, max: 3)])
        #expect(shape == PanelShape(header: true, list: [.init(plugin: "claude", rows: 2), .init(plugin: "dl", rows: 3)]))
    }

    /// Empty sections hidden; single placeholder row when all empty
    @Test func emptySectionsHidden() {
        #expect(PanelShape(guardEnabled: true, sections: [section("claude", rows: 0), section("dl", rows: 1)]).list == [.init(plugin: "dl", rows: 1)])
        #expect(PanelShape(guardEnabled: false, sections: [section("claude", rows: 0)]) == PanelShape(header: false, list: []))
    }

    /// At most 6 rows total: earlier sections prioritized, starved sections hidden
    @Test func budgetAcrossSections() {
        let shape = PanelShape(guardEnabled: true, sections: [section("a", rows: 5), section("b", rows: 5), section("c", rows: 5)])
        #expect(shape.list == [.init(plugin: "a", rows: 5), .init(plugin: "b", rows: 1)])
    }

    /// Guard only: no list; no plugins enabled: placeholder row ("No enabled plugins")
    @Test func guardOnlyAndNothing() {
        #expect(PanelShape(guardEnabled: true, sections: []) == PanelShape(header: true, list: nil))
        #expect(PanelShape(guardEnabled: false, sections: []) == PanelShape(header: false, list: []))
    }

    @Test func heights() {
        let notch = CGSize(width: 185, height: 32)
        func h(_ shape: PanelShape) -> CGFloat { NotchLayout.size(.dashboard, notch: notch, panel: shape, cardContent: 0, ears: true).height }
        let guardOnly = h(PanelShape(header: true, list: nil))
        #expect(h(PanelShape(header: true, list: [])) == guardOnly + NotchLayout.listGap + NotchLayout.rowHeight + 2 * NotchLayout.listInset)
        #expect(h(PanelShape(header: false, list: nil)) == guardOnly - NotchLayout.dashStatusHeight)
        let two = h(PanelShape(header: true, list: [.init(plugin: "a", rows: 1), .init(plugin: "b", rows: 2)]))
        #expect(two == guardOnly + NotchLayout.listGap + 3 * NotchLayout.rowHeight + 4 * NotchLayout.listInset + NotchLayout.sectionGap)
    }

    /// Collapsed without ears matches notch itself (left ear Pip disabled and right ear empty)
    @Test func closedWithoutEars() {
        let notch = CGSize(width: 185, height: 32)
        #expect(NotchLayout.size(.closed, notch: notch, panel: PanelShape(header: true, list: nil), cardContent: 0, ears: false) == notch)
        #expect(NotchLayout.size(.closed, notch: notch, panel: PanelShape(header: true, list: nil), cardContent: 0, ears: true).width
                == notch.width + 2 * NotchLayout.earWidth)
    }
}
