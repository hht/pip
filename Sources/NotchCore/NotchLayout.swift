import CoreGraphics

/// Collapsed, card presentation, expanded panel
public enum NotchMode: Hashable, Sendable { case closed, card, dashboard }

/// Answers: Dimensions of the notch's 3 states and inner element padding. Shared by views and hover hit-testing; agnostic of content and mouse position
public enum NotchLayout {
    /// Notch window: fits fullest panel (`PanelShape.maxRows` rows across up to 6 sections) and largest card
    public static let windowSize = CGSize(width: 580, height: 440)
    /// Card content padding from shape's black background: card Pip aligns with panel top-left Pip, moving vertically without horizontal shift (HIG Live Activities: keep relative position between expanded states)
    public static let cardPadding = contentInset + rowIcon / 2 - dashCorner / 2
    /// Height of first row (Pip + title + subtitle)
    public static let cardRowHeight: CGFloat = 38
    public static let cardBottom: CGFloat = 16
    /// Black background width of expanded panel and cards = iOS Live Activity expanded width 408 (HIG Live Activities; Mac menu bar Live Activity uses identical dimensions).
    /// Outward top corners (`openFlare`) on each side not counted in black width
    public static let dashWidth: CGFloat = 408
    /// Outward flare width at shape top when expanded (panel, cards) (NotchShape topRadius)
    public static let openFlare: CGFloat = 14
    /// Padding around black background 14 (HIG Live Activities: Lock Screen standard margin)
    public static let dashMargin: CGFloat = 14
    public static let listRadius: CGFloat = 14
    /// Bottom corner radius when expanded (panel, card); 8 when closed
    public static let openBottomRadius: CGFloat = 28
    /// Session list container inset 4
    public static let listInset: CGFloat = 4
    public static let rowHeight: CGFloat = 38
    public static let rowPadding: CGFloat = 10
    public static let rowIcon: CGFloat = 24
    /// Content distance from black background edge: session icon left edge, time right edge, gear right edge, top-right badge right edge align here (docs/ui.md "Panel Layout")
    public static let contentInset = dashMargin + listInset + rowPadding
    /// Top-left Pip and top-right badge: equal size (HIG: balanced leading/trailing dimensions), matches height of title + IP status rows under notch;
    /// Pip body center and session icon center vertically aligned. Card uses same Pip with identical size
    public static let dashCorner: CGFloat = 32
    /// Pip and badge top offset from panel top 8: hugs notch sides without forehead gap
    public static let dashCornerTop: CGFloat = 8
    /// Height of status area directly under notch (title + IP)
    public static let dashStatusHeight: CGFloat = 42
    public static let footerHeight: CGFloat = 30
    /// Gap between status area and session container, and between footer and panel bottom
    public static let listGap: CGFloat = 10
    public static let footerBottom: CGFloat = 4
    /// Gap between sections in panel
    public static let sectionGap: CGFloat = 6
    /// White opacity for secondary text (time, footer, empty list): >= 4.5:1 contrast for <= 17pt text (HIG Accessibility)
    public static let secondaryTextOpacity = 0.5

    /// Ears on both sides of notch when closed: left ear holds Pip, right ear holds status indicator (docs/mascot.md §1)
    public static let earWidth: CGFloat = 44
    /// Outward flare width at top corner when closed (NotchShape topRadius)
    public static let closedFlare: CGFloat = 4
    /// Left ear Pip body diameter (docs/mascot.md §1): panel Pip scaled to this size
    public static let earMascotSize: CGFloat = 20
    /// Center inset of left ear Pip and right ear indicator: centered in visible ear portion (excluding flare), symmetrical
    /// (docs/mascot.md §1; HIG Live Activities compact: balanced left/right, hugs camera)
    public static let earCenterInset = closedFlare + (earWidth - closedFlare) / 2

    /// Screens without a physical notch (height 0) do not show ears, preserving original notch-less behavior
    public static func hasEars(_ notch: CGSize) -> Bool { notch.height > 0 }

    public static func topInset(_ notch: CGSize) -> CGFloat { max(notch.height, 24) }
    /// Panel content starts below notch; screen without notch reserves 32 for menu bar
    public static func dashTop(_ notch: CGSize) -> CGFloat { max(notch.height, 32) }
    /// Top edge of card content
    public static func cardTop(_ notch: CGSize) -> CGFloat { topInset(notch) - 2 }

    /// cardContent: Measured height of card content (row 1 + block), shape expands via spring.
    /// ears: Whether ears show when collapsed (notch-less screen has none; solid black notch when left ear Pip disabled and right ear has nothing)
    public static func size(_ mode: NotchMode, notch: CGSize, panel: PanelShape, cardContent: CGFloat, ears: Bool) -> CGSize {
        switch mode {
        case .closed:
            return hasEars(notch) && ears ? CGSize(width: notch.width + 2 * earWidth, height: notch.height) : notch
        case .card: return CGSize(width: dashWidth + 2 * openFlare, height: cardTop(notch) + cardContent + cardBottom)
        case .dashboard:
            let list: CGFloat = switch panel.list {
            case nil: 0
            case []?: listGap + rowHeight + 2 * listInset
            case let sections?: listGap + sections.map { CGFloat($0.rows) * rowHeight + 2 * listInset }.reduce(0, +)
                + CGFloat(sections.count - 1) * sectionGap
            }
            return CGSize(width: dashWidth + 2 * openFlare,
                          height: dashTop(notch) + (panel.header ? dashStatusHeight : 0) + list + footerHeight + footerBottom)
        }
    }
}

/// Panel appearance: whether egress guard header is present, how many rows each section shows (docs/ui.md "Panel Layout"). Shared by view and hover hit-testing
public struct PanelShape: Equatable, Sendable {
    public struct Visible: Equatable, Sendable {
        public var plugin: String
        public var rows: Int

        public init(plugin: String, rows: Int) {
            self.plugin = plugin
            self.rows = rows
        }
    }

    public var header: Bool
    /// nil: no list (egress guard only); empty: placeholder row (all sections empty or no plugins enabled)
    public var list: [Visible]?

    /// Maximum total visible rows across sections: earlier sections prioritized, remainder omitted (prevents panel covering half the screen)
    public static let maxRows = 6

    public init(header: Bool, list: [Visible]?) {
        self.header = header
        self.list = list
    }

    /// sections: Enabled sections in display order
    public init(guardEnabled: Bool, sections: [PanelSection]) {
        header = guardEnabled
        guard !sections.isEmpty else {
            list = guardEnabled ? nil : []
            return
        }
        var left = Self.maxRows
        var visible: [Visible] = []
        for s in sections {
            let n = min(s.rows.count, s.maxRows, left)
            guard n > 0 else { continue }
            visible.append(Visible(plugin: s.plugin, rows: n))
            left -= n
        }
        list = visible
    }
}
