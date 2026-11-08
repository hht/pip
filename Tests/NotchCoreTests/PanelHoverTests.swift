import Foundation
import Testing
import NotchCore

private let t0 = Date(timeIntervalSinceReferenceDate: 0)

/// Hover expand panel: pauses briefly on notch to open, lingers before closing after cursor leaves (docs/ui.md "Principles": hover or click to expand)
@Suite struct PanelHovering {
    @Test func opensAfterDwellOnNotch() {
        var h = PanelHover()
        h.mouseMoved(onNotch: true, nearShape: false, canOpen: true, now: t0)
        #expect(!h.isOpen)
        #expect(h.deadline == t0 + PanelHover.openDelay)
        // Continued motion while dwelling does not reset timer
        h.mouseMoved(onNotch: true, nearShape: false, canOpen: true, now: t0 + 0.1)
        h.tick(now: t0 + PanelHover.openDelay)
        #expect(h.isOpen)
        #expect(h.deadline == nil)
    }

    /// Just passing by: leaves before dwell duration, does not open
    @Test func passingByDoesNotOpen() {
        var h = PanelHover()
        h.mouseMoved(onNotch: true, nearShape: false, canOpen: true, now: t0)
        h.mouseMoved(onNotch: false, nearShape: false, canOpen: true, now: t0 + 0.05)
        #expect(h.deadline == nil)
        h.tick(now: t0 + 1)
        #expect(!h.isOpen)
    }

    /// Hover expand disabled or pinned open/closed: hover does not expand, click still expands
    @Test func hoverDisabledStillOpensOnClick() {
        var h = PanelHover()
        h.mouseMoved(onNotch: true, nearShape: false, canOpen: false, now: t0)
        #expect(h.deadline == nil)
        h.open()
        #expect(h.isOpen)
    }

    /// Closes after leaving shape (including 10pt margin) for a duration; returning cancels close
    @Test func closesAfterLeaving() {
        var h = PanelHover()
        h.open()
        h.mouseMoved(onNotch: false, nearShape: false, canOpen: true, now: t0)
        #expect(h.isOpen)
        #expect(h.deadline == t0 + PanelHover.closeDelay)
        h.mouseMoved(onNotch: false, nearShape: true, canOpen: true, now: t0 + 0.1)
        #expect(h.deadline == nil)
        h.mouseMoved(onNotch: false, nearShape: false, canOpen: true, now: t0 + 0.2)
        // Continued motion outside does not reset timer
        h.mouseMoved(onNotch: false, nearShape: false, canOpen: true, now: t0 + 0.3)
        h.tick(now: t0 + 0.2 + PanelHover.closeDelay)
        #expect(!h.isOpen)
    }

    /// Panel opened via click unaffected by "hover expand" toggle, closes on leave as usual
    @Test func clickOpenedClosesOnLeaveEvenIfHoverDisabled() {
        var h = PanelHover()
        h.open()
        h.mouseMoved(onNotch: false, nearShape: false, canOpen: false, now: t0)
        h.tick(now: t0 + PanelHover.closeDelay)
        #expect(!h.isOpen)
    }

    /// Early tick does nothing
    @Test func earlyTickIsIgnored() {
        var h = PanelHover()
        h.mouseMoved(onNotch: true, nearShape: false, canOpen: true, now: t0)
        h.tick(now: t0 + PanelHover.openDelay / 2)
        #expect(!h.isOpen && h.deadline == t0 + PanelHover.openDelay)
    }

    /// Opening settings, changing pin mode, disabling hover expand: close immediately and cancel pending expand
    @Test func closeCancelsEverything() {
        var h = PanelHover()
        h.mouseMoved(onNotch: true, nearShape: false, canOpen: true, now: t0)
        h.close()
        h.tick(now: t0 + 1)
        #expect(!h.isOpen && h.deadline == nil)
        h.open()
        h.mouseMoved(onNotch: false, nearShape: false, canOpen: true, now: t0)
        h.close()
        #expect(!h.isOpen && h.deadline == nil)
    }
}
