import AgentCore
import AppKit
import SwiftUI
import MascotCore
import NotchCore
import PluginCore

/// Card appearance and sound: Content defined in NotchCore `Card`; resolves shooting star tint, Pip look, and alert sound per `outcome` (docs/ui.md "Card").
/// Timing of presentation is governed by `CardQueue`.
extension Card {
    static var exitAlert: Card {
        Card(source: .exitGuard, title: GuardPresentation.violatedTitle, subtitle: String(localized: "Internet traffic is routed outside Clash's tunnel"), outcome: .violation)
    }
    static var recovered: Card {
        Card(source: .exitGuard, title: String(localized: "Egress recovered"), subtitle: String(localized: "All traffic is going through the proxy again"), outcome: .recovered)
    }
    /// Recovery card duration fixed at 4s, independent of "Card Duration" setting (docs/ui.md "Card").
    static let recoveredSeconds: TimeInterval = 4

    /// Claude Code cards: subtitle is session directory path matching session row; click switches to its terminal.
    static func turnDone(_ session: Session) -> Card { claude(String(localized: "Claude Code is done"), .done, session) }
    static func turnFailed(_ session: Session) -> Card { claude(String(localized: "Claude Code hit an error"), .failed, session) }
    static func needsYou(_ need: AgentState.Need, _ session: Session) -> Card {
        switch need {
        case .question: return claude(String(localized: "Claude Code is waiting for your answer"), .question, session)
        case .approval: return claude(String(localized: "Claude Code is waiting for your approval"), .approval, session)
        }
    }

    private static func claude(_ title: String, _ outcome: Outcome, _ session: Session) -> Card {
        Card(source: .claudeCode, title: title, subtitle: (session.cwd as NSString).abbreviatingWithTildeInPath, outcome: outcome,
             action: .terminal(TerminalRef(session)))
    }

    /// Shooting star and keyline tint: done uses desaturated silver-white, failed uses light orange from lower body of error look; green reserved for healthy egress.
    var tint: Color {
        switch outcome {
        case .done, .info: return Color(white: 0.85)
        case .failed: return Color(cgColor: Look.error.gradient.bottom.cg)
        case .question, .attention: return Color(cgColor: RGB.question.cg)
        case .approval: return Color(cgColor: RGB.approval.cg)
        case .recovered: return .green
        case .violation: return Color(cgColor: RGB.red.cg)
        }
    }

    /// Pip on card updates to this card's specific look (docs/ui.md "Card" 7).
    var look: Look {
        switch outcome {
        case .done, .recovered: return .finished
        case .failed: return .error
        case .question, .attention: return .question
        case .approval: return .approval
        case .info: return .idle
        case .violation: return .danger
        }
    }

    /// System alert sound played at moment of presentation (docs/agent-integration.md "Alerts", docs/egress-guard.md); standard messages are silent.
    var sound: NSSound.Name? {
        switch outcome {
        case .done, .recovered: return "Glass"
        case .failed: return "Funk"
        case .question, .approval, .attention: return "Ping"
        case .info: return nil
        case .violation: return "Basso"
        }
    }
}

/// "State Testing" overrides (StateTest.swift): in-memory only, mutated via NotchController only, reset on App restart.
@MainActor
final class NotchOverrides: ObservableObject {
    @Published fileprivate(set) var look: Look?
    @Published fileprivate(set) var pin: NotchPin = .auto

    var isReal: Bool { look == nil && pin == .auto }

    /// Actual Pip look rendered: forced takes precedence, otherwise real look (from dominant plugin).
    func mascot(real: Look) -> Look { look ?? real }
    /// Actual right ear indicator: tracks forced look when overridden.
    func ear(real: EarIndicator) -> EarIndicator { look.map { .for($0, probeFailed: false) } ?? real }
}

extension AppState {
    /// Current panel shape: view rendering and hit testing evaluate same model.
    var panel: PanelShape { PanelShape(guardEnabled: store.config.isEnabled(PluginID.exitGuard), sections: sections) }

    /// Whether retracted notch has ears: left ear renders Pip, or right ear has content.
    func ears(_ overrides: NotchOverrides) -> Bool {
        store.config.showsEarMascot || overrides.ear(real: lead?.indicator ?? .none) != .none
    }
}

/// Handlers for clicking cards, buttons, and panel rows: three actions only (CLAUDE.md hard rule "Plugins").
/// URL opening filtered via `urlSchemes` allowlist; rejected URLs log scheme only (truncated).
@MainActor
enum CardActions {
    static func perform(_ action: Card.Action) {
        switch action {
        case .open(let url):
            if URLPolicy(schemes: ConfigStore.shared.config.urlSchemes).allows(url) {
                NSWorkspace.shared.open(url)
            } else {
                Log.write("Card: URL scheme not in allowlist, not opened (\((url.scheme ?? "none").prefix(32)))")
            }
        case .activate(let bundleID):
            if !Apps.activate(bundleID) { Log.write("Card: target App not installed") }
        case .terminal(let terminal):
            Ghostty.focus(terminal)
        }
    }
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var card: Card?
    @Published var expanded = false      // Whether card is expanded
    /// Hover (or click) expanded panel: mirror of `PanelHover`, written by `NotchController.updateHover` only.
    @Published var hovering = false
    @Published var notchSize: CGSize = CGSize(width: 190, height: 32)
    @Published var countdown: CardCountdown?
    /// Measured natural height of card content; drives shape geometry and hover hit target.
    @Published var cardContentHeight = NotchLayout.cardRowHeight
    let overrides = NotchOverrides()

    /// Cards override everything (Always Closed never suppresses real alert cards); otherwise governed by pin mode, Auto tracks hover.
    var mode: NotchMode {
        if expanded, card != nil { return .card }
        switch overrides.pin {
        case .open: return .dashboard
        case .closed: return .closed
        case .auto: return hovering ? .dashboard : .closed
        }
    }
}

/// Transparent window over notch area. When retracted, black shape coincides with physical notch (invisible); pops out when expanded.
/// Retracted window does not capture mouse: hover and clicks rely on global monitors checking notch hit area,
/// preventing focus stealing and blocking clicks elsewhere.
@MainActor
final class NotchController {
    /// Retracted window level: above system menu bar, below pull-down menus.
    static let restLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
    /// Expanded window level: raised above third-party menu bar overlays to avoid top clipping.
    /// Active only during expansion, returning to restLevel when retracted without obstructing pull-down menus.
    /// Verified (CGWindowListCopyWindowInfo, macOS 26.5): Control Center level 25,
    /// Vibe Island level 27 (mainMenu + 3), iBar Pro level 101 (popUpMenu, covering menu bar);
    /// pull-down menus beside notch remained unoccluded during alert cards.
    static let openLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)

    private let window: NSPanel
    private let model = NotchModel()
    private let state = AppState.shared
    private var queue = CardQueue<Card>()
    /// Alert card content: displayed on stage when active; subtitle updates with guard status.
    private var alertCard: Card?
    private var tickWork: DispatchWorkItem?
    var hasNotch: Bool { NotchLayout.hasEars(model.notchSize) }
    var overrides: NotchOverrides { model.overrides }

    private var moveMonitors: [Any] = []
    private let tracker = NotchMouseTracker()
    private var hoverEnabled = false
    private var hover = PanelHover()
    private var hoverWork: DispatchWorkItem?
    private var screenFrame: NSRect = .zero

    /// Gear button, "Open Plugin Settings": opens settings (nil restores previous page).
    var onOpenSettings: (SettingsPane?) -> Void = { _ in }
    /// Pops up on right-click over notch or expanded shape.
    var contextMenu: NSMenu?
    /// Alert card retracted before healthy (user clicks close, or non-resident card times out): marks violation as dismissed.
    var onAlertDismissed: () -> Void = {}

    init() {
        window = NSPanel(contentRect: NSRect(origin: .zero, size: NotchLayout.windowSize),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = Self.restLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        // Notch elements permanently use white-on-black: system controls, .secondary, SF Symbols rendering, and tooltips follow window appearance (docs/ui.md "Light and Dark").
        window.appearance = NSAppearance(named: .darkAqua)
        // Panel does not activate App; enabling this ensures session rows and gear tooltips appear while app is in background.
        // @see https://developer.apple.com/documentation/appkit/nswindow/allowstooltipswhenapplicationisinactive
        window.allowsToolTipsWhenApplicationIsInactive = true

        let host = FirstMouseHostingView(rootView: NotchRoot(model: model, overrides: model.overrides, state: state, store: ConfigStore.shared, onDismiss: { [weak self] in
            // Clicked card close button
            guard let self else { return }
            self.apply(self.queue.dismiss(now: Date()))
        }, onOpenCard: { [weak self] action in
            // Clicked card outside close button or clicked action button: execute action, dismiss card (docs/ui.md "Card").
            guard let self else { return }
            CardActions.perform(action)
            self.apply(self.queue.dismiss(now: Date()))
        }, onCardResized: { [weak self] in
            self?.cardResized()
        }, onSettings: { [weak self] pane in
            self?.updateHover { $0.close() }
            self?.onOpenSettings(pane)
        }))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: NotchLayout.windowSize)
        window.contentView = host
        // Once window captures mouse, global monitor misses events targeted at App, while panel never becomes key window;
        // activeAlways tracking area captures movement and exit to restore mouse passthrough when cursor leaves shape.
        // @see https://developer.apple.com/documentation/appkit/nstrackingarea/options/activealways
        // @see https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)
        tracker.onMove = { [weak self] in self?.mouseMoved() }
        host.addTrackingArea(NSTrackingArea(rect: .zero,
                                            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                            owner: tracker, userInfo: nil))
        position()
        orderFront()
        installMouseMonitors()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.position() }
        }
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func position() {
        guard let s = targetScreen() else { return }
        // Displays without hardware notch: emerges from top center of screen.
        var notch = CGSize(width: 180, height: 0)
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            notch = CGSize(width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top)
        }
        model.notchSize = notch
        let f = s.frame
        screenFrame = f
        window.setFrame(NSRect(x: f.midX - NotchLayout.windowSize.width / 2, y: f.maxY - NotchLayout.windowSize.height,
                               width: NotchLayout.windowSize.width, height: NotchLayout.windowSize.height), display: true)
    }

    // MARK: Cards

    private func orderFront() { window.orderFrontRegardless() }

    /// Activity cards: refreshes in-place if queued or active (no replay, no sound, no timer reset); posts if absent and requested.
    func activityCard(_ change: ActivityBoard.CardChange) {
        if queue.update(change.card, key: change.key) {
            apply(CardQueue.Change())
        } else if change.alert {
            // Expired cards dropped like regular cards: after hours of alert card, does not replay long-completed activities.
            post(change.card, key: change.key, staleAt: min(change.staleAt ?? .distantFuture, Date().addingTimeInterval(InboxGate.lifetime)))
        }
    }

    /// Plugin disabled: dismiss its queued and active cards.
    func discard(where shouldGo: (CardQueue<Card>.Notice) -> Bool) {
        apply(queue.discard(where: shouldGo, now: Date()))
    }

    /// Enqueues transient card (docs/ui.md "Card"). seconds defaults to "Card Duration" setting.
    func post(_ card: Card, key: CardQueue<Card>.Key?, seconds: TimeInterval? = nil, lapses: Bool = false, staleAt: Date? = nil) {
        let notice = CardQueue.Notice(card: card, key: key, seconds: seconds ?? ConfigStore.shared.config.cardAutoDismissSeconds,
                                      lapses: lapses, externalPluginID: card.externalPluginID, staleAt: staleAt)
        apply(queue.post(notice, now: Date()))
    }

    /// Converts AgentCore events to cards, or dismisses expired intervention cards (docs/ui.md "Card" 2).
    func agentEvents(_ events: [AgentEvent], sessions: [Session]) {
        // Events and session list originate from same update: target session is guaranteed to exist.
        func session(_ pid: Int32) -> Session {
            guard let s = sessions.first(where: { $0.pid == pid }) else { preconditionFailure("event session not in list") }
            return s
        }
        for event in events {
            switch event {
            case .turnDone(let pid): post(.turnDone(session(pid)), key: .session(pid))
            case .turnFailed(let pid): post(.turnFailed(session(pid)), key: .session(pid))
            case .needsYou(let need, let pid): post(.needsYou(need, session(pid)), key: .session(pid), lapses: true)
            case .needsYouEnded(let pid): apply(queue.withdraw(.session(pid), now: Date()))
            }
        }
    }

    /// Stage tracks queue: swap or dismiss card, play card sound, schedule next deadline.
    private func apply(_ change: CardQueue<Card>.Change) {
        let card: Card?
        switch queue.showing {
        case .notice(let c): card = c
        case .alert:
            guard let a = alertCard else { preconditionFailure("alert card must have content when active") }
            card = a
        case nil: card = nil
        }
        if let card {
            if card.id != model.card?.id || !model.expanded {
                present(card)
            } else if card != model.card {
                // Same card updated in-place (activity refresh): skip re-entrance animation.
                model.card = card
            }
            if change.sound, ConfigStore.shared.config.soundEnabled, let sound = card.sound { NSSound(named: sound)?.play() }
        } else if model.expanded {
            collapse()
        }
        // Persistent alert cards have no countdown: edge does not sweep, drawing static keyline only (docs/ui.md "Card").
        model.countdown = queue.showing == .alert(persistent: true) ? nil : queue.countdown
        scheduleTick()
        if change.alertDismissed {
            alertCard = nil
            onAlertDismissed()
        }
    }

    private func present(_ card: Card) {
        orderFront()
        if model.mode != .closed {
            withAnimation(NotchSpring.notchOpen) { model.card = card; model.expanded = true }
        } else {
            model.card = card
            withAnimation(NotchSpring.notchOpen) { model.expanded = true }
        }
        updateMouseCapture()
        // VoiceOver announces title when card pops up (docs/ui.md "Card").
        // Posted from panel window with high priority to interrupt ongoing speech without activating App.
        // @see https://developer.apple.com/documentation/appkit/nsaccessibility/notification/announcementrequested
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: card.title, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Display sleep or lock screen: pauses active card, holds queue; resumes on return.
    func setScreenAway(_ away: Bool) {
        apply(queue.setAway(away, now: Date()))
    }

    private func scheduleTick() {
        tickWork?.cancel()
        guard let at = queue.deadline(now: Date()) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.apply(self.queue.tick(now: Date()))
        }
        tickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at.timeIntervalSinceNow), execute: work)
    }

    /// Mouse hovered over card: pauses countdown; resumes remaining time when moved away.
    func setCardHover(_ over: Bool) {
        guard over != queue.hovering else { return }
        apply(queue.setHovering(over, now: Date()))
    }

    /// Action for alert card after guard round check (evaluated in `ViolationAlert`).
    func alertAction(_ action: ViolationAlert.Action) {
        switch action {
        case .none: return
        case .raise:
            // New violation: insert alert card at front, play Basso.
            alertCard = .exitAlert
            let cfg = ConfigStore.shared.config
            apply(queue.raiseAlert(persistent: cfg.alertPersistent, seconds: cfg.cardAutoDismissSeconds, now: Date()))
        case .clear(let recovered):
            // Queue recovery card first, presenting immediately once alert card is dismissed ahead of accumulated cards.
            if recovered { post(.recovered, key: .recovered, seconds: Card.recoveredSeconds) }
            apply(queue.clearAlert(now: Date()))
            alertCard = nil
        }
    }

    /// Card content preserved until retract animation finishes so collapsing card is visible; retained if interrupted by new card.
    /// @see https://developer.apple.com/documentation/swiftui/withanimation(_:completioncriteria:_:completion:)
    private func collapse() {
        withAnimation(model.hovering ? NotchSpring.page : NotchSpring.notchClose) {
            model.expanded = false
        } completion: { [weak self] in
            guard let self, !self.model.expanded else { return }
            self.model.card = nil
        }
        updateMouseCapture()
    }

    // MARK: State Testing (in-memory only, see StateTest.swift)

    var mode: NotchMode { model.mode }

    /// Force Pip to display specific look; nil reverts to real state. Changes visual look only: leaves AppState and alert cards untouched,
    /// so forcing "Danger" does not pop up alert cards, play sounds, or alter dismissal state.
    func force(_ l: Look?) {
        guard overrides.look != l else { return }
        overrides.look = l
    }

    /// Always Open / Always Closed / Auto. Resets hover on change, re-evaluating mouse position when returning to Auto.
    func setPin(_ p: NotchPin) {
        guard overrides.pin != p else { return }
        let opening = p == .open && model.mode == .closed
        if opening { orderFront() }
        withAnimation(opening ? NotchSpring.notchOpen : NotchSpring.notchClose) {
            overrides.pin = p
            updateHover { $0.close() }
        }
        updateMouseCapture()
    }

    /// "Restore Real State": clears both override settings.
    func restoreRealState() {
        force(nil)
        setPin(.auto)
    }

    // MARK: Hover Expansion

    func setHoverEnabled(_ on: Bool) {
        hoverEnabled = on
        if !on { updateHover { $0.close() } }
    }

    /// Persistent mouse monitors: card click-through relies on this, so not toggled by "Expand on Hover".
    /// When retracted, clicks pass to other apps and are visible to global monitor only; when expanded, window captures mouse and local monitor handles clicks.
    /// @see https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)
    private func installMouseMonitors() {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { _ in
            Task { @MainActor in self.mouseMoved() }
        }) { moveMonitors.append(g) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in
            let right = e.type == .rightMouseDown
            Task { @MainActor in _ = self.mouseDown(right: right) }
        }) { moveMonitors.append(g) }
        // Window captures mouse when over retracted ears (see captures); left click handled by local monitor only.
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in
            self.mouseDown(right: e.type == .rightMouseDown) ? nil : e
        }) { moveMonitors.append(l) }
    }

    /// Click notch to expand; right-click over notch or expanded shape opens context menu. Returns true if handled.
    private func mouseDown(right: Bool) -> Bool {
        let p = NSEvent.mouseLocation
        let onShape = triggerRect.contains(p) || (model.mode != .closed && shapeRect.contains(p))
        guard onShape else { return false }
        if right {
            guard let menu = contextMenu else { return false }
            menu.popUp(positioning: nil, at: p, in: nil)
            return true
        }
        guard model.mode == .closed, overrides.pin == .auto else { return false }
        updateHover { $0.open() }
        return true
    }

    /// Screen bounds of physical notch (Pip MascotDirector tracks this).
    var anchorRect: NSRect {
        let h = NotchLayout.topInset(model.notchSize)
        let w = model.notchSize.width
        return NSRect(x: screenFrame.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h)
    }

    /// Determines whether window captures mouse and layer level: captures only when cursor falls within visible shape,
    /// passing through transparent areas (including 580x320 window padding) without blocking menu bar or other apps.
    private func updateMouseCapture() {
        let open = model.mode != .closed
        let level = open ? Self.openLevel : Self.restLevel
        if window.level != level { window.level = level }
        let capture = captures(NSEvent.mouseLocation)
        if window.ignoresMouseEvents == capture { window.ignoresMouseEvents = !capture }
    }

    /// Whether window captures mouse at point: full shape when expanded; notch plus retracted black ears when retracted
    /// (ears overlay menu bar and must not leak clicks behind); notchless screens have height 0 when retracted, passing through.
    func captures(_ p: NSPoint) -> Bool {
        (model.mode != .closed || hasNotch) && shapeRect.contains(p)
    }

    /// Retracted shape (notch plus ears, or top thin strip on notchless displays) slightly expanded as hover/click hit region.
    var triggerRect: NSRect {
        let f = screenFrame
        let n = NotchLayout.size(.closed, notch: model.notchSize, panel: state.panel, cardContent: 0, ears: state.ears(overrides))
        let w = (hasNotch ? n.width : 200) + 16
        let h = hasNotch ? n.height + 2 : 6
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h + Self.topEdgeSlack)
    }

    /// When cursor hits very top edge of screen, NSEvent.mouseLocation.y equals frame.maxY while NSRect.contains excludes top boundary;
    /// hit region extends 1pt beyond top edge so top-pinned cursor remains inside target.
    /// @see https://developer.apple.com/documentation/appkit/nsevent/mouselocation
    /// @see https://developer.apple.com/documentation/corefoundation/cgrect
    private static let topEdgeSlack: CGFloat = 1

    /// Screen rect of currently visible shape (shares dimensions with NotchLayout).
    private var shapeRect: NSRect {
        let s = NotchLayout.size(model.mode, notch: model.notchSize, panel: state.panel, cardContent: model.cardContentHeight, ears: state.ears(overrides))
        let f = screenFrame
        return NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height + Self.topEdgeSlack)
    }

    /// 10pt margin when checking if hover exited.
    private var visibleRect: NSRect { shapeRect.insetBy(dx: -10, dy: -10) }

    /// Card height changed while mouse stationary: transparent area passes through, visible area captures clicks;
    /// does not count as hover start (docs/ui.md "Card": mouse must move over card to pause).
    private func cardResized() {
        updateMouseCapture()
        if queue.hovering, !shapeRect.contains(NSEvent.mouseLocation) { setCardHover(false) }
    }

    private func mouseMoved() {
        updateMouseCapture()
        let p = NSEvent.mouseLocation
        MascotDirector.shared.mouseMoved(to: p)
        setCardHover(model.mode == .card && shapeRect.contains(p))
        let (onNotch, nearShape, canOpen) = (triggerRect.contains(p), visibleRect.contains(p), hoverEnabled && overrides.pin == .auto)
        updateHover { $0.mouseMoved(onNotch: onNotch, nearShape: nearShape, canOpen: canOpen, now: Date()) }
    }

    /// Hover state updated: expands or collapses panel, schedules next timer.
    private func updateHover(_ change: (inout PanelHover) -> Void) {
        change(&hover)
        if hover.isOpen != model.hovering {
            if hover.isOpen { orderFront() }
            withAnimation(hover.isOpen ? NotchSpring.notchOpen : NotchSpring.notchClose) { model.hovering = hover.isOpen }
            updateMouseCapture()
        }
        hoverWork?.cancel(); hoverWork = nil
        guard let at = hover.deadline else { return }
        let work = DispatchWorkItem { [weak self] in self?.updateHover { $0.tick(now: Date()) } }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at.timeIntervalSinceNow), execute: work)
    }
}

/// Captures mouse events from host view tracking area, forwards to NotchController.
final class NotchMouseTracker: NSResponder {
    var onMove: () -> Void = {}
    override func mouseMoved(with event: NSEvent) { onMove() }
    override func mouseEntered(with event: NSEvent) { onMove() }
    override func mouseExited(with event: NSEvent) { onMove() }
}

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// When false, omits top edge (used for border): card top blends into physical notch without seam line.
    var closed = true

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    /// Effective radii for top corner outward flares and bottom rounded corners, clamped to fit small bounds.
    private func radii(in r: CGRect) -> (top: CGFloat, bottom: CGFloat) {
        let t = min(topRadius, r.width / 4, r.height / 2)
        return (t, max(0, min(bottomRadius, r.height - t, (r.width - 2 * t) / 2)))
    }

    /// Left half: from top-left outward flare tip, along left edge and corner to bottom center. Left shooting star travels this path, right star mirrors it.
    func leftHalf(in r: CGRect) -> Path {
        var p = Path()
        guard r.width > 0, r.height > 0 else { return p }
        let (t, b) = radii(in: r)
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        return p
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        guard r.width > 0, r.height > 0 else { return p }
        let (t, b) = radii(in: r)
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        if closed { p.closeSubpath() }
        return p
    }
}

struct NotchRoot: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var overrides: NotchOverrides
    let state: AppState
    /// Plugin enablement, ordering, resident plugin, and ear mascot visibility configured in settings.
    @ObservedObject var store: ConfigStore
    let onDismiss: () -> Void
    let onOpenCard: (Card.Action) -> Void
    /// Measured new card height: hit target updates accordingly.
    let onCardResized: () -> Void
    let onSettings: (SettingsPane?) -> Void

    @ObservedObject private var director = MascotDirector.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let mode = model.mode
        let panel = state.panel
        let size = NotchLayout.size(mode, notch: model.notchSize, panel: panel, cardContent: model.cardContentHeight, ears: state.ears(overrides))
        let open = mode != .closed
        let t: CGFloat = open ? NotchLayout.openFlare : NotchLayout.closedFlare
        let b: CGFloat = open ? NotchLayout.openBottomRadius : 8
        let shape = NotchShape(topRadius: t, bottomRadius: b)

        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .top) { content(mode, panel: panel, inset: t) }
                .overlay(alignment: .topLeading) { corners(mode, size: size, flare: t) }
                .overlay {
                    // Panel has faint keyline; card edge has shooting stars rendered outside clipping (see below).
                    if mode != .card {
                        NotchShape(topRadius: t, bottomRadius: b, closed: false)
                            .stroke(Color.white.opacity(open ? 0.08 : 0), lineWidth: 1)
                    }
                }
                .clipShape(shape)
                .overlay {
                    // Shooting stars along card edge (docs/ui.md "Card"): centered on edge with soft glow blooming inside and out, placed outside clipping.
                    if mode == .card, let card = model.card {
                        // Corner radius changes with the spring; shooting stars are drawn according to the final shape: fade in when shape is almost ready to avoid misaligned corners;
                        // Remove immediately as soon as closing starts, without fading out, to avoid light clusters remaining in place and falling behind the shape retracting into the notch (Dynamic Island also dismisses content first when retracting).
                        CardEdge(topRadius: t, bottomRadius: b, tint: card.tint, countdown: model.countdown)
                            // Covers card, passing clicks to close button and card content beneath.
                            .allowsHitTesting(false)
                            .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.25).delay(CardEdgeView.appearDelay)),
                                                    removal: .opacity.animation(.linear(duration: 0))))
                    }
                }
                .shadow(color: .black.opacity(open ? 0.3 : 0), radius: 18, y: 6)
                .animation(NotchSpring.page, value: panel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Pip and the indicators on the right: the **same view** across closed, dashboard, and card modes, only changing position and scale per mode,
    /// following the same spring as the shape (HIG Live Activities: "Maintain the relative placement of elements",
    /// expanded state scales up from collapsed state without removing and re-entering elements). Layout size is fixed, only animating position / scaleEffect,
    /// embedded Core Animation views on macOS 14 are also interpolated frame-by-frame (verified).
    /// Pip flies between left ear -> dashboard top-left -> card left side; switches to this card's pose on the card, and announcement returns (docs/ui.md "Card" 7);
    /// the group on the right fades out in card mode, pausing animations when transparent.
    /// Does not fly when reduce motion is enabled: replaces with a new view on mode change, old fades out in place, new fades in at new position (docs/mascot.md §5).
    @ViewBuilder
    private func corners(_ mode: NotchMode, size: CGSize, flare: CGFloat) -> some View {
        if NotchLayout.hasEars(model.notchSize) || mode != .closed {
            let open = mode == .dashboard
            let notch = model.notchSize
            let c = NotchLayout.dashCorner
            let top = NotchLayout.dashCornerTop + c / 2
            let right = size.width - flare - NotchLayout.contentInset - c / 2
            let card = mode == .card ? model.card : nil
            let lead = state.lead
            let look = card?.look ?? overrides.mascot(real: lead?.look ?? .idle)
            let shown = overrides.look != nil || card != nil ? look : director.shown(look)
            let ear = overrides.ear(real: lead?.indicator ?? .none)
            // Right indicator tracks active left look (dims during drowsiness/dizziness); probe grey ring does not change with look.
            let indicator = shown == look ? ear : EarIndicator.for(shown, probeFailed: ear == .ring)
            let guardOn = store.config.isEnabled(PluginID.exitGuard)
            // Left ear Pip disabled: omitted when retracted, flies in normally when expanded.
            let mascotHidden = mode == .closed && !store.config.showsEarMascot
            let mascotAt: CGPoint = switch mode {
            case .closed: CGPoint(x: NotchLayout.earCenterInset, y: notch.height / 2)
            case .dashboard: CGPoint(x: flare + NotchLayout.contentInset + NotchLayout.rowIcon / 2, y: top)
            case .card: CGPoint(x: flare + NotchLayout.cardPadding + c / 2, y: NotchLayout.cardTop(notch) + NotchLayout.cardRowHeight / 2)
            }
            ZStack(alignment: .topLeading) {
                // Sign decoration resides on right ear, Pip holds expression only; restored on cards where right ear is absent.
                MascotView(look: look, size: c, hidesSigns: card == nil, playing: !mascotHidden)
                    .environment(\.mascotLiteral, overrides.look != nil || card != nil)
                    .scaleEffect(mode == .closed ? NotchLayout.earMascotSize / c : 1)
                    .opacity(mascotHidden ? 0 : 1)
                    .position(mascotAt)
                    .id(reduceMotion ? mode : .closed)
                    .transition(.opacity)
                ZStack {
                    EarIndicatorView(indicator: indicator,
                                     size: CGSize(width: NotchLayout.earWidth, height: notch.height),
                                     // Outer container positioned at earCenterInset from right; aligns to its own center here without double offset.
                                     center: CGPoint(x: NotchLayout.earWidth / 2, y: notch.height / 2),
                                     playing: mode == .closed)
                        .frame(width: NotchLayout.earWidth, height: notch.height)
                        .opacity(mode == .closed ? 1 : 0)
                    // Badge belongs to Egress Guard section: omitted when guard is disabled.
                    GuardBadge(presentation: state.presentation, size: c)
                        .opacity(open && guardOn ? 1 : 0)
                        .scaleEffect(open || reduceMotion ? 1 : 0.4)
                }
                .frame(width: c, height: c)
                .position(open ? CGPoint(x: right, y: top)
                               : CGPoint(x: size.width - NotchLayout.earCenterInset, y: notch.height / 2))
                .id(reduceMotion && open)
                .transition(.opacity)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .allowsHitTesting(false)
            // Poke Pip in panel to make it dizzy briefly (docs/mascot.md §2). In panel only: clicking retracted notch expands it; clicking cards executes card action.
            if open {
                Circle().fill(.clear)
                    .contentShape(Circle())
                    .frame(width: c, height: c)
                    .position(mascotAt)
                    .onTapGesture { director.poke() }
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func content(_ mode: NotchMode, panel: PanelShape, inset: CGFloat) -> some View {
        let top = NotchLayout.cardTop(model.notchSize)
        switch mode {
        case .card:
            if let card = model.card {
                NotchCardView(card: card, onDismiss: onDismiss, onAction: onOpenCard)
                    .fixedSize(horizontal: false, vertical: true)
                    // Shape grows to natural height of content via spring animation: transitions smoothly on card swaps or content updates.
                    // @see https://developer.apple.com/documentation/swiftui/view/ongeometrychange(for:of:action:)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        withAnimation(NotchSpring.page) { model.cardContentHeight = h }
                        onCardResized()
                    }
                    .id(card.id)
                    .padding(.top, top)
                    .padding(.horizontal, inset)
                    .transition(Self.contentTransition(reduceMotion))
            }
        case .dashboard:
            NotchDashboard(state: state, panel: panel, onSettings: onSettings)
                .frame(width: NotchLayout.dashWidth)
                .padding(.top, NotchLayout.dashTop(model.notchSize))
                .transition(Self.contentTransition(reduceMotion))
        case .closed:
            EmptyView()
        }
    }

    /// Content enters after the shape has expanded: blur clears up + scales up from 0.96 + fades in, waiting 0.06s for the shape to move first (DynamicNotchKit's blur + scale + opacity,
    /// boring.notch's `.smooth(0.35)`); exit only fades out, faster (docs/ui.md "Principles": enter slightly slower, exit slightly faster). Reduce motion uses fade in / fade out only.
    static func contentTransition(_ reduceMotion: Bool) -> AnyTransition {
        let fadeOut = AnyTransition.opacity.animation(.easeIn(duration: 0.1))
        if reduceMotion { return .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2)), removal: fadeOut) }
        return .asymmetric(
            insertion: .modifier(active: Unfocus(amount: 1), identity: Unfocus(amount: 0))
                .animation(.smooth(duration: 0.35).delay(0.06)),
            removal: fadeOut)
    }
}

/// Entrance state: 8pt blur, scaled to 0.96 (top anchored), transparent.
private struct Unfocus: ViewModifier {
    let amount: CGFloat
    func body(content: Content) -> some View {
        content
            .blur(radius: 8 * amount)
            .scaleEffect(1 - 0.04 * amount, anchor: .top)
            .opacity(1 - amount)
    }
}

/// Egress status badge at top-right: matches size of Pip at top-left. Color + icon + copy convey status together (docs/ui.md "Principles");
/// title sits below physical notch.
struct GuardBadge: View {
    let presentation: GuardPresentation
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var symbol: String {
        switch presentation.tone {
        case .healthy: return "checkmark.shield.fill"
        case .mismatch: return "exclamationmark.triangle.fill"
        case .violated: return "xmark.shield.fill"
        case .unknown:
            switch presentation.look {
            case .offline: return "wifi.slash"
            case .stale: return "hourglass"
            default: return "questionmark"
            }
        }
    }

    var body: some View {
        let c = presentation.color
        Circle()
            .fill(c.opacity(0.16))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(c)
                // Symbol replaces in-place on status change (Apple "Displaying live data": Replace symbol effect); fades with Reduce Motion.
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace)))
            .animation(.smooth, value: symbol)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(presentation.title)
    }
}

/// Hover-expanded content: Egress Guard status below notch, plugin sections, and footer gear button. Pip top-left and badge top-right live in NotchRoot.
/// Egress Guard pinned at top (status and badge), omitted if disabled; other plugins follow settings order (docs/ui.md "Panel Layout").
/// Displays path / status / time only, never conversation contents.
struct NotchDashboard: View {
    let state: AppState
    let panel: PanelShape
    let onSettings: (SettingsPane?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = state.presentation
        VStack(spacing: 0) {
            if panel.header {
                // Directly below notch (Dynamic Island center region): bold/semibold typography (HIG Live Activities), rounded font matching Pip (HIG Typography).
                VStack(spacing: 2) {
                    Text(p.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(state.display.egressIP ?? "—")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(p.ipColor)
                        // IP digits roll character-by-character on change (Apple "Displaying live data"); fades with Reduce Motion.
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                        .animation(.smooth, value: state.display.egressIP)
                }
                // Padding clears Pip and badge on sides.
                .padding(.horizontal, NotchLayout.contentInset + NotchLayout.rowIcon / 2 + NotchLayout.dashCorner / 2 + 6)
                .frame(height: NotchLayout.dashStatusHeight)
            }

            if let list = panel.list {
                PanelList(list: list, sections: state.sections, onSettings: { onSettings(.plugins) })
                    .padding(.top, NotchLayout.listGap)
                    .padding(.horizontal, NotchLayout.dashMargin)
            }

            // Footer is global, containing only gear: plugins are optional, avoiding section-specific info (e.g. "Checked at...").
            // Stale guard data is reflected in top status (Guard Not Responding).
            HStack {
                Spacer()
                NotchGearButton { onSettings(nil) }
                    .padding(.trailing, -5) // Gear hit box 24pt, glyph ~14pt: aligns glyph right edge with margin
            }
            .padding(.horizontal, NotchLayout.contentInset)
            .frame(height: NotchLayout.footerHeight)
        }
    }
}

/// Plugin sections: rounded inset containers (HIG Live Activities: inset rounded containers separate content), showing `PanelShape` row count, scrolling excess.
/// Placeholder shown when all sections empty; "No plugins turned on" and "Open Plugin Settings" when none enabled.
struct PanelList: View {
    let list: [PanelShape.Visible]
    let sections: [PanelSection]
    let onSettings: () -> Void

    var body: some View {
        if list.isEmpty {
            HStack(spacing: 10) {
                Text(placeholder)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(NotchLayout.secondaryTextOpacity))
                if sections.isEmpty {
                    Button("Open Plugin Settings", action: onSettings)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(.white.opacity(0.14)))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: NotchLayout.rowHeight)
            .padding(NotchLayout.listInset)
            .background(Self.container)
        } else {
            VStack(spacing: NotchLayout.sectionGap) {
                ForEach(list, id: \.plugin) { visible in
                    let rows = sections.first { $0.plugin == visible.plugin }?.rows ?? []
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            ForEach(rows) { PanelRowView(row: $0) }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .environment(\.colorScheme, .dark) // Prevents light scrollbar track on dark background when scrollbar setting is "Always"
                    .frame(height: CGFloat(visible.rows) * NotchLayout.rowHeight)
                    .padding(NotchLayout.listInset)
                    .background(Self.container)
                }
            }
        }
    }

    private var placeholder: String {
        if sections.isEmpty { return String(localized: "No plugins turned on") }
        if sections.map(\.plugin) == [PluginID.claudeCode] { return String(localized: "Claude Code isn't running") }
        return String(localized: "No sessions or activities in progress")
    }

    private static var container: some View {
        RoundedRectangle(cornerRadius: NotchLayout.listRadius, style: .continuous).fill(.white.opacity(0.06))
    }
}

/// Settings entry button at bottom-right of panel. Dimmed at rest (white 0.55 meets 4.5:1 contrast on black), brightens with circular backplate and rotation on hover.
struct NotchGearButton: View {
    let action: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(hover ? 0.9 : 0.55))
                .rotationEffect(.degrees(hover && !reduceMotion ? 30 : 0))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(pressedScale: 0.92))
        .onHover { h in withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { hover = h } }
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}

/// Panel row (`PanelRow`): icon, title, optional subtitle, status indicator, relative time / short value on right. Stopped sessions dim icon and title, preserving timestamp contrast.
/// Status conveyed via indicators only; names provided via hover tooltips and VoiceOver.
struct PanelRowView: View {
    let row: PanelRow
    @State private var hover = false

    /// Working and in-progress use three blue dots matching right ear; waiting for answer/approval use Pip decorations (speech bubble, raised hand); progress uses ring indicator.
    private var indicator: EarIndicator {
        switch row.indicator {
        case .none, .progress: return .none
        case .working: return .dots
        case .question: return .decoration(.question)
        case .approval: return .decoration(.approval)
        case .attention: return .dot(.question)
        }
    }

    private var stateTitle: String {
        if row.dimmed { return String(localized: "Stopped") }
        switch row.indicator {
        case .none: return ""
        case .working: return row.icon == .claude ? String(localized: "Working") : String(localized: "In Progress")
        case .question: return String(localized: "Waiting for Answer")
        case .approval: return String(localized: "Waiting for Approval")
        case .attention: return String(localized: "Needs You")
        case .progress(let p): return p.formatted(.percent.precision(.fractionLength(0)))
        }
    }

    var body: some View {
        Group {
            if let action = row.action {
                Button { CardActions.perform(action) } label: { label }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hover ? 0.06 : 0)))
                    .onHover { hover = $0 }
                    .accessibilityHint(Self.hint(action))
            } else {
                label
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(stateTitle)
    }

    private var label: some View {
        let dimmed = row.dimmed ? 0.55 : 1
        return HStack(spacing: 10) {
            icon
                .frame(width: NotchLayout.rowIcon, height: NotchLayout.rowIcon)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08)))
                .opacity(dimmed)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(row.titleIsPath ? .head : .tail)
                    .help(row.title)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(NotchLayout.secondaryTextOpacity))
                        .lineLimit(1)
                }
            }
            .opacity(dimmed)
            Spacer(minLength: 8)
            Group {
                if case .progress(let p) = row.indicator {
                    ZStack {
                        Circle().stroke(.white.opacity(0.15), lineWidth: 2)
                        Circle().trim(from: 0, to: p).stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 12, height: 12)
                    .animation(.smooth, value: p)
                } else {
                    EarIndicatorView(indicator: indicator, size: CGSize(width: 20, height: 20), center: CGPoint(x: 13, y: 10))
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .help(stateTitle)
            trailing
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(NotchLayout.secondaryTextOpacity))
                .lineLimit(1)
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.horizontal, NotchLayout.rowPadding)
        .frame(height: NotchLayout.rowHeight)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        switch row.icon {
        case .claude:
            // Agent brand indicated solely by leading logo.
            ClaudeMark()
                .fill(ClaudeMark.color)
                .frame(width: 15, height: 15)
                .help("Claude Code")
                .accessibilityLabel("Claude Code")
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.trailing {
        case .since(let date):
            // TimelineView recalculates body every second against current wall clock time.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(AgoText.string(date))
            }
        case .value(let v):
            Text(v)
        }
    }

    private static func hint(_ action: Card.Action) -> String {
        switch action {
        case .terminal: return String(localized: "Open in Ghostty")
        case .open: return String(localized: "Open Link")
        case .activate: return String(localized: "Switch App")
        }
    }
}

struct NotchCardView: View {
    let card: Card
    let onDismiss: () -> Void
    /// Click card (when `action` exists) or button.
    let onAction: (Card.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Pip position: flies in from NotchRoot (docs/ui.md "Card" 7).
                Color.clear.frame(width: NotchLayout.dashCorner, height: NotchLayout.dashCorner)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    subtitle
                }
                Spacer(minLength: 8)
                if let value = card.value {
                    Text(value).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(PressableStyle())
            }
            .frame(height: NotchLayout.cardRowHeight)
            if let block = card.block {
                CardBlockView(block: block, tint: card.tint)
            }
            if !card.buttons.isEmpty {
                HStack(spacing: 8) {
                    Spacer()
                    ForEach(card.buttons.indices, id: \.self) { i in
                        Button { onAction(card.buttons[i].action) } label: {
                            Text(card.buttons[i].title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .frame(height: 26)
                                .background(Capsule().fill(.white.opacity(0.14)))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
        }
        .padding(.horizontal, NotchLayout.cardPadding)
        // Close button catches clicks first; clicking remaining card area triggers action.
        .contentShape(Rectangle())
        .onTapGesture { card.action.map(onAction) }
        .accessibilityAddTraits(card.action == nil ? [] : .isButton)
    }

    /// External plugin cards indicate source origin (CLAUDE.md hard rule "External plugins trusted but constrained").
    private var subtitle: some View {
        HStack(spacing: 4) {
            if case .plugin(_, let name, let symbol) = card.source {
                Image(systemName: symbol)
                Text(card.subtitle == nil ? name : "\(name) -")
            }
            if let subtitle = card.subtitle { Text(subtitle) }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.65))
        .lineLimit(1)
    }
}

/// Card bottom content blocks: laid out at natural size, card expands to fit with spring animation.
struct CardBlockView: View {
    let block: Card.Block
    let tint: Color

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            // Concentric: card bottom radius 28 - bottom margin 16.
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
    }

    @ViewBuilder
    private var content: some View {
        switch block {
        case .text(let t):
            // Body text wraps, showing up to 3 lines.
            Text(Self.markdown(t.joined(separator: "\n")))
                .lineLimit(Card.maxLines)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        case .log(let l):
            // Logs do not wrap: one line per entry.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(l.enumerated()), id: \.offset) { _, line in Text(line).lineLimit(1) }
            }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
        case .facts(let facts):
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 4) {
                ForEach(Array(facts.enumerated()), id: \.offset) { _, f in
                    HStack(spacing: 6) {
                        Text(f.title).foregroundStyle(.white.opacity(NotchLayout.secondaryTextOpacity))
                        Text(f.value).foregroundStyle(.white.opacity(0.9))
                    }
                    .lineLimit(1)
                }
            }
            .font(.system(size: 12, weight: .medium))
        case .checklist(let checks):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(checks.enumerated()), id: \.offset) { _, c in
                    HStack(spacing: 6) {
                        Image(systemName: Self.symbol(c.state)).foregroundStyle(Self.color(c.state)).frame(width: 14)
                        Text(c.text).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    }
                }
            }
            .font(.system(size: 12, weight: .medium))
        case .progress(let p, let label):
            VStack(spacing: 6) {
                HStack {
                    if let label { Text(label).lineLimit(1) }
                    Spacer(minLength: 8)
                    Text(p, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule().fill(tint).frame(width: g.size.width * p)
                    }
                }
                .frame(height: 6)
            }
        }
    }

    /// Recognizes inline bold, italic, code only (Adaptive Cards Markdown subset). Links and images stripped: actions route through cards/buttons only, never bypassing URL allowlist.
    /// Displays raw text on parse errors (external content).
    /// @see https://learn.microsoft.com/en-us/adaptive-cards/authoring-cards/text-features
    static func markdown(_ line: String) -> AttributedString {
        guard var s = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(line)
        }
        for run in s.runs where run.link != nil || run.imageURL != nil {
            s[run.range].link = nil
            s[run.range].imageURL = nil
        }
        return s
    }

    private static func symbol(_ state: Card.Check.State) -> String {
        switch state {
        case .ok: return "checkmark"
        case .failed: return "xmark"
        case .pending: return "circle.dotted"
        }
    }

    /// Green reserved for healthy egress: completed uses white, failed uses light orange.
    private static func color(_ state: Card.Check.State) -> Color {
        switch state {
        case .ok: return .white.opacity(0.85)
        case .failed: return Color(cgColor: Look.error.gradient.bottom.cg)
        case .pending: return .white.opacity(NotchLayout.secondaryTextOpacity)
        }
    }
}
