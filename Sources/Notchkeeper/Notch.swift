import AgentCore
import AppKit
import SwiftUI
import MascotCore
import NotchCore
import PluginCore

/// 卡片的样子和声音：写什么在 NotchCore 的 `Card`，这里按 `outcome` 取流星颜色、Pip 造型、提示音（docs/ui.md「卡片」）。
/// 什么时候放由 `CardQueue` 决定
extension Card {
    static var exitAlert: Card {
        Card(source: .exitGuard, title: GuardPresentation.violatedTitle, subtitle: String(localized: "去公网的路由没走 Clash 的隧道"), outcome: .violation)
    }
    static var recovered: Card {
        Card(source: .exitGuard, title: String(localized: "出口已恢复"), subtitle: String(localized: "流量又全部走代理了"), outcome: .recovered)
    }
    /// 恢复卡固定 4 秒，不跟「卡片停留」设置走（docs/ui.md「卡片」）
    static let recoveredSeconds: TimeInterval = 4

    /// Claude Code 的卡：副标题是会话的路径，和会话行一样；点了跳回它的终端
    static func turnDone(_ session: Session) -> Card { claude(String(localized: "Claude Code 做完了"), .done, session) }
    static func turnFailed(_ session: Session) -> Card { claude(String(localized: "Claude Code 出错了"), .failed, session) }
    static func needsYou(_ need: AgentState.Need, _ session: Session) -> Card {
        switch need {
        case .question: return claude(String(localized: "Claude Code 在等你回答"), .question, session)
        case .approval: return claude(String(localized: "Claude Code 在等你批准"), .approval, session)
        }
    }

    private static func claude(_ title: String, _ outcome: Outcome, _ session: Session) -> Card {
        Card(source: .claudeCode, title: title, subtitle: (session.cwd as NSString).abbreviatingWithTildeInPath, outcome: outcome,
             action: .terminal(TerminalRef(session)))
    }

    /// 流星和细边的颜色：完成低饱和银白，出错是 error 造型身体下端的浅橙；绿色只给出口正常，Claude 橙在黑底上晕开发红，不用
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

    /// 卡上的 Pip 换成这张卡自己的造型（docs/ui.md「卡片」7）
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

    /// 放出来那一刻响的系统音效（docs/agent-integration.md「提醒」、docs/egress-guard.md）；普通消息不响
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

/// 「状态测试」的覆盖（StateTest.swift）：只在内存里，只经 NotchController 改，重开 App 就没了
@MainActor
final class NotchOverrides: ObservableObject {
    @Published fileprivate(set) var look: Look?
    @Published fileprivate(set) var pin: NotchPin = .auto

    var isReal: Bool { look == nil && pin == .auto }

    /// Pip 实际显示的造型：强制的优先，否则是真实的（上位插件的）
    func mascot(real: Look) -> Look { look ?? real }
    /// 右耳实际显示的指示：强制时跟着强制的造型
    func ear(real: EarIndicator) -> EarIndicator { look.map { .for($0, probeFailed: false) } ?? real }
}

extension AppState {
    /// 面板此刻的形状：视图和命中测试按同一份算
    var panel: PanelShape { PanelShape(guardEnabled: store.config.isEnabled(PluginID.exitGuard), sections: sections) }

    /// 收起时长不长耳朵：左耳画 Pip，或右耳有东西
    func ears(_ overrides: NotchOverrides) -> Bool {
        store.config.showsEarMascot || overrides.ear(real: lead?.indicator ?? .none) != .none
    }
}

/// 点卡片、按钮、面板里的行都走这里：动作只有三种（CLAUDE.md 硬规则「插件」）。
/// 打开 URL 按 `urlSchemes` 白名单放行，拦下时只记 scheme（截短：外部来源）
@MainActor
enum CardActions {
    static func perform(_ action: Card.Action) {
        switch action {
        case .open(let url):
            if URLPolicy(schemes: ConfigStore.shared.config.urlSchemes).allows(url) {
                NSWorkspace.shared.open(url)
            } else {
                Log.write("卡片：链接的 scheme 不在白名单里，没打开（\((url.scheme ?? "无").prefix(32))）")
            }
        case .activate(let bundleID):
            if !Apps.activate(bundleID) { Log.write("卡片：没装要切换的 App") }
        case .terminal(let terminal):
            Ghostty.focus(terminal)
        }
    }
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var card: Card?
    @Published var expanded = false      // 卡片是否展开
    /// 悬停（或点击）展开了面板：`PanelHover` 的镜像，只由 `NotchController.updateHover` 写
    @Published var hovering = false
    @Published var notchSize: CGSize = CGSize(width: 190, height: 32)
    @Published var countdown: CardCountdown?
    /// 卡片内容按自然大小排，量出来的高度；形状和悬停命中区都按它
    @Published var cardContentHeight = NotchLayout.cardRowHeight
    let overrides = NotchOverrides()

    /// 卡片压过一切（固定收起也挡不住真的红卡）；其余由固定方式决定，自动时跟悬停走
    var mode: NotchMode {
        if expanded, card != nil { return .card }
        switch overrides.pin {
        case .open: return .dashboard
        case .closed: return .closed
        case .auto: return hovering ? .dashboard : .closed
        }
    }
}

/// 刘海区域的透明窗口。收起时黑色形状与刘海重合（看不见），展开时从刘海里弹出。
/// 收起时窗口不接收鼠标：悬停和刘海上的点击都靠全局监听判断鼠标是否在刘海热区里，
/// 所以不会抢焦点，也不会挡住别处的点击。
@MainActor
final class NotchController {
    /// 收起时的层级：在系统菜单栏之上，但在下拉菜单之下
    static let restLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
    /// 展开时的层级：要压过铺满顶部的第三方菜单栏覆盖层，否则卡片上沿会被盖住一截。
    /// 只在展开期间用，收起后降回 restLevel，平时不挡下拉菜单。
    /// 实测（CGWindowListCopyWindowInfo，macOS 26.5）：控制中心 25 层，
    /// Vibe Island 27 层（同 mainMenu + 3），iBar Pro 101 层（popUpMenu，铺满菜单栏），
    /// 红卡期间打开刘海旁的下拉菜单未被遮挡。
    static let openLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)

    private let window: NSPanel
    private let model = NotchModel()
    private let state = AppState.shared
    private var queue = CardQueue<Card>()
    /// 红卡的内容：挂着时台面上放它；副标题跟着守卫状态换
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

    /// 齿轮按钮、「打开插件设置」：打开设置（nil 是上次的页）
    var onOpenSettings: (SettingsPane?) -> Void = { _ in }
    /// 在刘海或展开的形状上右键时弹出
    var contextMenu: NSMenu?
    /// 红卡没等到 healthy 就收起（用户点 ×，或非常驻红卡到时）：记作用户关掉了这一次违规
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
        // 贴刘海的部分永远黑底白字：系统控件、.secondary、SF Symbols 分层色、tooltip 都跟窗口外观走，只写死颜色不够（docs/ui.md「亮色与暗色」）
        window.appearance = NSAppearance(named: .darkAqua)
        // 面板不激活 App，Notchkeeper 几乎从不在前台：不开这个，会话行、齿轮的 .help 永远不出现
        // @see https://developer.apple.com/documentation/appkit/nswindow/allowstooltipswhenapplicationisinactive
        window.allowsToolTipsWhenApplicationIsInactive = true

        let host = FirstMouseHostingView(rootView: NotchRoot(model: model, overrides: model.overrides, state: state, store: ConfigStore.shared, onDismiss: { [weak self] in
            // 点了卡片的 ×
            guard let self else { return }
            self.apply(self.queue.dismiss(now: Date()))
        }, onOpenCard: { [weak self] action in
            // 点了卡片 × 以外的地方或按钮：去它说的地方，这张卡算关掉（docs/ui.md「卡片」）
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
        // 窗口接收鼠标后，全局监听收不到发给本 App 的事件，而这个面板不会成为 key window；
        // 用 activeAlways 的 tracking area 接住移动和移出，鼠标离开形状时才能及时恢复穿透
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
        // 没有刘海的屏幕：从屏幕顶端中间“长”出来
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

    // MARK: 卡片

    private func orderFront() { window.orderFrontRegardless() }

    /// 活动的卡：排着或正在放就原地刷新（不重放、不响、不重新倒计时）；不在且要弹才弹
    func activityCard(_ change: ActivityBoard.CardChange) {
        if queue.update(change.card, key: change.key) {
            apply(CardQueue.Change())
        } else if change.alert {
            // 和普通卡一样排久了就不放：红卡挂了几个小时，撤掉后不补放早就结束了的活动
            post(change.card, key: change.key, staleAt: min(change.staleAt ?? .distantFuture, Date().addingTimeInterval(InboxGate.lifetime)))
        }
    }

    /// 关掉了插件：它排着的、正在放的卡都撤
    func discard(where shouldGo: (CardQueue<Card>.Notice) -> Bool) {
        apply(queue.discard(where: shouldGo, now: Date()))
    }

    /// 临时卡进队列（docs/ui.md「卡片」）。seconds 默认是「卡片停留」设置
    func post(_ card: Card, key: CardQueue<Card>.Key?, seconds: TimeInterval? = nil, lapses: Bool = false, staleAt: Date? = nil) {
        let notice = CardQueue.Notice(card: card, key: key, seconds: seconds ?? ConfigStore.shared.config.cardAutoDismissSeconds,
                                      lapses: lapses, externalPluginID: card.externalPluginID, staleAt: staleAt)
        apply(queue.post(notice, now: Date()))
    }

    /// AgentCore 的事件变成卡，或撤掉过期的介入卡（docs/ui.md「卡片」2）
    func agentEvents(_ events: [AgentEvent], sessions: [Session]) {
        // 事件和会话列表出自同一次更新：弹卡的会话一定在列表里
        func session(_ pid: Int32) -> Session {
            guard let s = sessions.first(where: { $0.pid == pid }) else { preconditionFailure("事件的会话不在列表里") }
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

    /// 台面跟着队列走：换卡或收起、响这张卡的声音、定下一次到点
    private func apply(_ change: CardQueue<Card>.Change) {
        let card: Card?
        switch queue.showing {
        case .notice(let c): card = c
        case .alert:
            guard let a = alertCard else { preconditionFailure("红卡挂着时一定有内容") }
            card = a
        case nil: card = nil
        }
        if let card {
            if card.id != model.card?.id || !model.expanded {
                present(card)
            } else if card != model.card {
                // 同一张卡换了内容（活动原地刷新）：不重新进场
                model.card = card
            }
            if change.sound, ConfigStore.shared.config.soundEnabled, let sound = card.sound { NSSound(named: sound)?.play() }
        } else if model.expanded {
            collapse()
        }
        // 常驻红卡没有倒计时：边缘不流星，只画细边（docs/ui.md「卡片」）
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
        // 弹卡时 VoiceOver 念出标题，看不见卡的人也知道发生了什么（docs/ui.md「卡片」）。
        // 面板不激活 App、没有 main window，所以挂在面板上发，优先级高才会打断正在念的内容
        // @see https://developer.apple.com/documentation/appkit/nsaccessibility/notification/announcementrequested
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: card.title, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// 熄屏或锁屏：台面上的卡停住，新卡不放、不响；回来接着放
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

    /// 鼠标在卡片上：倒计时暂停；移开：从剩下的时间继续
    func setCardHover(_ over: Bool) {
        guard over != queue.hovering else { return }
        apply(queue.setHovering(over, now: Date()))
    }

    /// 守卫查完一轮，红卡要做的事（判定在 `ViolationAlert`）
    func alertAction(_ action: ViolationAlert.Action) {
        switch action {
        case .none: return
        case .raise:
            // 新的一次违规：红卡插到最前，响 Basso
            alertCard = .exitAlert
            let cfg = ConfigStore.shared.config
            apply(queue.raiseAlert(persistent: cfg.alertPersistent, seconds: cfg.cardAutoDismissSeconds, now: Date()))
        case .clear(let recovered):
            // 恢复卡先排上，红卡撤了马上轮到它，不排在违规期间攒下的外部卡后面
            if recovered { post(.recovered, key: .recovered, seconds: Card.recoveredSeconds) }
            apply(queue.clearAlert(now: Date()))
            alertCard = nil
        }
    }

    /// 卡片的内容留到收起动画做完才清掉，收的时候看得见缩回去的是哪张卡；中途又弹了卡就不清
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

    // MARK: 状态测试（只在内存里，见 StateTest.swift）

    var mode: NotchMode { model.mode }

    /// 强制 Pip 显示某个状态；nil 回到真实状态。只换 Pip 的样子：不碰 AppState 和红卡，
    /// 所以强制「危险」不弹红卡、不响，也不动「这次违规已关掉」的记录
    func force(_ l: Look?) {
        guard overrides.look != l else { return }
        overrides.look = l
    }

    /// 固定展开 / 固定收起 / 自动。换的时候清掉悬停，回到自动时按当前鼠标重新判断
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

    /// 「恢复真实状态」：两项覆盖一起清掉
    func restoreRealState() {
        force(nil)
        setPin(.auto)
    }

    // MARK: 悬停展开

    func setHoverEnabled(_ on: Bool) {
        hoverEnabled = on
        if !on { updateHover { $0.close() } }
    }

    /// 鼠标监听常驻：卡片的点击穿透也靠它，所以不随「悬停展开」开关装卸。
    /// 收起时点击发给的是别的 App，只有全局监听看得到；展开后窗口接收鼠标，点击改由本地监听接住。
    /// @see https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)
    private func installMouseMonitors() {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { _ in
            Task { @MainActor in self.mouseMoved() }
        }) { moveMonitors.append(g) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in
            let right = e.type == .rightMouseDown
            Task { @MainActor in _ = self.mouseDown(right: right) }
        }) { moveMonitors.append(g) }
        // 鼠标在收起的耳朵上时窗口接收鼠标（见 captures），左键点击也只有本地监听看得到
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in
            self.mouseDown(right: e.type == .rightMouseDown) ? nil : e
        }) { moveMonitors.append(l) }
    }

    /// 点刘海展开；在刘海或展开的形状上右键弹出菜单。返回 true 表示事件已处理
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

    /// 刘海本体在屏幕上的位置（Pip MascotDirector 贴着它走）
    var anchorRect: NSRect {
        let h = NotchLayout.topInset(model.notchSize)
        let w = model.notchSize.width
        return NSRect(x: screenFrame.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h)
    }

    /// 窗口收不收鼠标、在哪一层只由这里决定：鼠标落在当前看得见的形状里才接收，
    /// 其余（包括 580×320 窗口的透明部分）一律穿透，不挡菜单栏和别的 App
    private func updateMouseCapture() {
        let open = model.mode != .closed
        let level = open ? Self.openLevel : Self.restLevel
        if window.level != level { window.level = level }
        let capture = captures(NSEvent.mouseLocation)
        if window.ignoresMouseEvents == capture { window.ignoresMouseEvents = !capture }
    }

    /// 这一点上窗口要不要接收鼠标：展开时是整个形状；收起时是刘海加两只黑色耳朵（耳朵挡在菜单栏上，
    /// 点它不能漏给后面的菜单栏），没有刘海的屏幕收起时形状高 0，一律穿透
    func captures(_ p: NSPoint) -> Bool {
        (model.mode != .closed || hasNotch) && shapeRect.contains(p)
    }

    /// 收起的形状（刘海加两只耳朵，或无刘海屏顶端中间一条细带）略放大一点作为悬停、点击热区
    var triggerRect: NSRect {
        let f = screenFrame
        let n = NotchLayout.size(.closed, notch: model.notchSize, panel: state.panel, cardContent: 0, ears: state.ears(overrides))
        let w = (hasNotch ? n.width : 200) + 16
        let h = hasNotch ? n.height + 2 : 6
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h + Self.topEdgeSlack)
    }

    /// 鼠标顶到屏幕最上沿时 NSEvent.mouseLocation.y 恰好等于 frame.maxY，而 NSRect.contains 不含上边界，
    /// 所以命中区要越过屏幕顶边 1pt，否则贴顶的鼠标永远判在区外（在刘海机型上用 CGWarpMouseCursorPosition 实测）
    /// @see https://developer.apple.com/documentation/appkit/nsevent/mouselocation
    /// @see https://developer.apple.com/documentation/corefoundation/cgrect
    private static let topEdgeSlack: CGFloat = 1

    /// 当前可见形状的屏幕区域（与视图共用 NotchLayout 的尺寸）
    private var shapeRect: NSRect {
        let s = NotchLayout.size(model.mode, notch: model.notchSize, panel: state.panel, cardContent: model.cardContentHeight, ears: state.ears(overrides))
        let f = screenFrame
        return NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height + Self.topEdgeSlack)
    }

    /// 判断悬停是否离开时多留 10pt 余量
    private var visibleRect: NSRect { shapeRect.insetBy(dx: -10, dy: -10) }

    /// 卡片换了高度、鼠标没动：透明区要穿透、看得见的要接住点击；鼠标已不在卡上就不算悬停。
    /// 不因此算作悬停开始（docs/ui.md「卡片」：鼠标在这张卡上动了才暂停）
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

    /// 悬停状态机改完：面板跟着展开或收起，定下一次到点
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

/// 接住宿主视图 tracking area 的鼠标事件，转给 NotchController
final class NotchMouseTracker: NSResponder {
    var onMove: () -> Void = {}
    override func mouseMoved(with event: NSEvent) { onMove() }
    override func mouseEntered(with event: NSEvent) { onMove() }
    override func mouseExited(with event: NSEvent) { onMove() }
}

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// false 时不画顶边（描边用）：卡片顶部和刘海连成一体，不出现一条线
    var closed = true

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    /// 顶角外翻和底角实际用的半径：太小的矩形里压到放得下
    private func radii(in r: CGRect) -> (top: CGFloat, bottom: CGFloat) {
        let t = min(topRadius, r.width / 4, r.height / 2)
        return (t, max(0, min(bottomRadius, r.height - t, (r.width - 2 * t) / 2)))
    }

    /// 左半边：从左上外翻的顶端，沿左边、左下角走到底边中点。卡片边缘的流星沿它走，右边一颗走它的镜像
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
    /// 插件开关、顺序、常驻插件、左耳画不画 Pip 都在配置里
    @ObservedObject var store: ConfigStore
    let onDismiss: () -> Void
    let onOpenCard: (Card.Action) -> Void
    /// 卡片量出了新高度：命中区跟着变
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
                    // 面板是一条很淡的白线；卡片的边缘是流星，画在裁切外面（见下）
                    if mode != .card {
                        NotchShape(topRadius: t, bottomRadius: b, closed: false)
                            .stroke(Color.white.opacity(open ? 0.08 : 0), lineWidth: 1)
                    }
                }
                .clipShape(shape)
                .overlay {
                    // 卡片边缘的流星（docs/ui.md「卡片」）：压在边缘正中，柔光往里外两边晕开，所以放在裁切外面
                    if mode == .card, let card = model.card {
                        // 圆角是跟着弹簧变的，流星按最终外形画：等形状快长好再淡入，免得拐角错开；
                        // 一开始收起就立刻撤掉，不淡出，免得光团停在原处、跟不上缩回刘海的形状（灵动岛收起时也是内容先撤）
                        CardEdge(topRadius: t, bottomRadius: b, tint: card.tint, countdown: model.countdown)
                            // 盖满整张卡，点击交给下面的 × 和卡片
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

    /// Pip 和右边的指示：收起、面板、卡片里是**同一个视图**，只按形态改位置和缩放，
    /// 跟着形状的同一个弹簧走（HIG Live Activities：「Maintain the relative placement of elements」，
    /// 展开态是收起态放大，元素不移除再进场）。布局尺寸固定、只动 position / scaleEffect，
    /// 嵌进来的 Core Animation 视图在 macOS 14 上也会被逐帧插值（实测）。
    /// Pip 在左耳 → 面板左上 → 卡片左侧之间飞，到卡片上换成这张卡的造型、告示画回来（docs/ui.md「卡片」7）；
    /// 右边的一组在卡片形态时淡出，透明时停掉动画。
    /// 减弱动态效果时不飞：换形态就换一个新视图，旧的原地淡出、新的在新位置淡入（docs/mascot.md §5）
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
            // 右边跟着左边实际画的造型走（犯困时左耳睡着、晕的时候，右耳就不亮）；探针没结果的灰环不随造型变
            let indicator = shown == look ? ear : EarIndicator.for(shown, probeFailed: ear == .ring)
            let guardOn = store.config.isEnabled(PluginID.exitGuard)
            // 关掉了左耳的 Pip：收起时不画，展开时照常飞出来
            let mascotHidden = mode == .closed && !store.config.showsEarMascot
            let mascotAt: CGPoint = switch mode {
            case .closed: CGPoint(x: NotchLayout.earCenterInset, y: notch.height / 2)
            case .dashboard: CGPoint(x: flare + NotchLayout.contentInset + NotchLayout.rowIcon / 2, y: top)
            case .card: CGPoint(x: flare + NotchLayout.cardPadding + c / 2, y: NotchLayout.cardTop(notch) + NotchLayout.cardRowHeight / 2)
            }
            ZStack(alignment: .topLeading) {
                // 告示（sign）在右边，Pip 只管表情；卡片上没有右边，画回来
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
                                     // 外面已经把这一组的中心放在离右边 earCenterInset 处，这里以自身中心为准，不再偏一次
                                     center: CGPoint(x: NotchLayout.earWidth / 2, y: notch.height / 2),
                                     playing: mode == .closed)
                        .frame(width: NotchLayout.earWidth, height: notch.height)
                        .opacity(mode == .closed ? 1 : 0)
                    // 徽章是出口守卫那一段的：关掉守卫就不画
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
            // 点一下面板里的 Pip 晕一会儿（docs/mascot.md §2）。只在面板上：收起时点刘海是展开，卡片上点了是打开卡片
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
                    // 内容多高，形状就用弹簧长到多高：换卡、内容变了都平滑过渡
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

    /// 内容在形状长开之后进场：模糊变清晰 + 从 0.96 放大 + 淡入，稍等 0.06s 让形状先走（DynamicNotchKit 的 blur + scale + opacity，
    /// boring.notch 的 `.smooth(0.35)`）；退场只淡出、更快（docs/ui.md「原则」：进场稍慢、退场稍快）。减弱动态效果只淡入淡出
    static func contentTransition(_ reduceMotion: Bool) -> AnyTransition {
        let fadeOut = AnyTransition.opacity.animation(.easeIn(duration: 0.1))
        if reduceMotion { return .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2)), removal: fadeOut) }
        return .asymmetric(
            insertion: .modifier(active: Unfocus(amount: 1), identity: Unfocus(amount: 0))
                .animation(.smooth(duration: 0.35).delay(0.06)),
            removal: fadeOut)
    }
}

/// 进场用：模糊 8pt、缩到 0.96（锚在顶部）、透明
private struct Unfocus: ViewModifier {
    let amount: CGFloat
    func body(content: Content) -> some View {
        content
            .blur(radius: 8 * amount)
            .scaleEffect(1 - 0.04 * amount, anchor: .top)
            .opacity(1 - amount)
    }
}

/// 右上的出口状态徽章：和左上的 Pip 等大。颜色 + 图标 + 文案三者一起表达状态（docs/ui.md「原则」），
/// 文案在刘海下方的标题
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
                // 状态变了图标原地替换（Apple「Displaying live data」：符号用 Replace）；减弱动态效果只淡入淡出
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace)))
            .animation(.smooth, value: symbol)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(presentation.title)
    }
}

/// 悬停展开的内容：刘海正下方出口守卫的状态、各插件的段、底栏的齿轮。左上的 Pip 和右上的徽章在 NotchRoot。
/// 出口守卫那一段固定在顶上（状态区和徽章），关掉就不画；其余插件各一段，按设置里的顺序（docs/ui.md「面板布局」）。
/// 只显示路径 / 状态 / 时间，不显示任何对话内容。
struct NotchDashboard: View {
    let state: AppState
    let panel: PanelShape
    let onSettings: (SettingsPane?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = state.presentation
        VStack(spacing: 0) {
            if panel.header {
                // 刘海正下方（灵动岛的 center 区）：标题用中等以上字重（HIG Live Activities），圆体配圆润的 Pip（HIG Typography）
                VStack(spacing: 2) {
                    Text(p.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(state.display.egressIP ?? "—")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(p.ipColor)
                        // 出口换 IP 时数字逐位滚过去（Apple「Displaying live data」）；减弱动态效果只淡入淡出
                        .contentTransition(reduceMotion ? .opacity : .numericText())
                        .animation(.smooth, value: state.display.egressIP)
                }
                // 两侧让开 Pip 和徽章
                .padding(.horizontal, NotchLayout.contentInset + NotchLayout.rowIcon / 2 + NotchLayout.dashCorner / 2 + 6)
                .frame(height: NotchLayout.dashStatusHeight)
            }

            if let list = panel.list {
                PanelList(list: list, sections: state.sections, onSettings: { onSettings(.plugins) })
                    .padding(.top, NotchLayout.listGap)
                    .padding(.horizontal, NotchLayout.dashMargin)
            }

            // 底栏是全局的，只放齿轮：哪个插件都不是必须的，不放某个插件自己的东西（比如「出口检查于…」）。
            // 守卫数据旧了由顶上的状态说（出口守卫没响应）
            HStack {
                Spacer()
                NotchGearButton { onSettings(nil) }
                    .padding(.trailing, -5) // 齿轮的点击框 24、图形约 14：让图形右缘落在右对齐线上
            }
            .padding(.horizontal, NotchLayout.contentInset)
            .frame(height: NotchLayout.footerHeight)
        }
    }
}

/// 各插件的段：每段一个内嵌的圆角容器（HIG Live Activities：用内嵌圆角容器分隔内容），露 `PanelShape` 定的行数，多的在段里滚。
/// 段都空着时一行占位；一个插件都没开时是「没有开启的插件」和「打开插件设置」
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
                    Button("打开插件设置", action: onSettings)
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
                    .environment(\.colorScheme, .dark) // 系统亮色、滚动条设成「始终」时，别在黑底上画浅色槽
                    .frame(height: CGFloat(visible.rows) * NotchLayout.rowHeight)
                    .padding(NotchLayout.listInset)
                    .background(Self.container)
                }
            }
        }
    }

    private var placeholder: String {
        if sections.isEmpty { return String(localized: "没有开启的插件") }
        if sections.map(\.plugin) == [PluginID.claudeCode] { return String(localized: "Claude Code 没在运行") }
        return String(localized: "没有进行中的会话或活动")
    }

    private static var container: some View {
        RoundedRectangle(cornerRadius: NotchLayout.listRadius, style: .continuous).fill(.white.opacity(0.06))
    }
}

/// 面板底栏右边的设置入口。平时压暗不抢眼（白 0.55 在黑底上仍够 4.5:1），悬停时变亮、垫圆底、转一下，说明它能点
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
        .help("设置")
        .accessibilityLabel("设置")
    }
}

/// 面板里的一行（`PanelRow`）：图标、标题和可选的副标题、状态指示、右侧距今多久或短值。已停止的会话图标和标题变暗，时间不暗（保住对比度）。
/// 状态只用指示表达，不写字；状态名留给悬停提示和旁白
struct PanelRowView: View {
    let row: PanelRow
    @State private var hover = false

    /// 工作中、进行中和右耳一样是三蓝点；等你回答、批准用 Pip 这两个造型自己的装饰（带 ? 的气泡、举起的手），比一个点好认；进度是一圈环
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
        if row.dimmed { return String(localized: "已停止") }
        switch row.indicator {
        case .none: return ""
        case .working: return row.icon == .claude ? String(localized: "工作中") : String(localized: "进行中")
        case .question: return String(localized: "等你回答")
        case .approval: return String(localized: "等你批准")
        case .attention: return String(localized: "要你看")
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
            // 是哪个 agent 只靠行首的厂商标志表示
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
            // TimelineView 每秒重算一次 body，按当时的现在算
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(AgoText.string(date))
            }
        case .value(let v):
            Text(v)
        }
    }

    private static func hint(_ action: Card.Action) -> String {
        switch action {
        case .terminal: return String(localized: "在 Ghostty 中打开")
        case .open: return String(localized: "打开链接")
        case .activate: return String(localized: "切换 App")
        }
    }
}

struct NotchCardView: View {
    let card: Card
    let onDismiss: () -> Void
    /// 点卡片（有 `action` 时）或按钮
    let onAction: (Card.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Pip 的位置：NotchRoot 里那只飞过来（docs/ui.md「卡片」7）
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
        // × 是按钮，自己先接住点击；其余地方点了去这张卡说的地方
        .contentShape(Rectangle())
        .onTapGesture { card.action.map(onAction) }
        .accessibilityAddTraits(card.action == nil ? [] : .isButton)
    }

    /// 外部插件的卡标明是谁发的（CLAUDE.md 硬规则「外部插件可信但受限」）
    private var subtitle: some View {
        HStack(spacing: 4) {
            if case .plugin(_, let name, let symbol) = card.source {
                Image(systemName: symbol)
                Text(card.subtitle == nil ? name : "\(name) ·")
            }
            if let subtitle = card.subtitle { Text(subtitle) }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.65))
        .lineLimit(1)
    }
}

/// 卡片底部的内容块：按自然大小排，卡片量出高度后用弹簧长过去
struct CardBlockView: View {
    let block: Card.Block
    let tint: Color

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            // 同心：卡片底角 28 − 下边距 16
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
    }

    @ViewBuilder
    private var content: some View {
        switch block {
        case .text(let t):
            // 正文可以换行，整块最多露 3 行
            Text(Self.markdown(t.joined(separator: "\n")))
                .lineLimit(Card.maxLines)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        case .log(let l):
            // 日志不换行：一行截一行
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

    /// 只认行内的粗体、斜体、代码（Adaptive Cards 的 Markdown 子集）。链接和图片去掉：点卡片和按钮才是动作，不能绕过 URL 白名单，也不收图片路径。
    /// 解析不了的照原文显示：它是外部文字，不是我们的错
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

    /// 绿色只给出口正常：做完的用白，失败的用出错卡的浅橙
    private static func color(_ state: Card.Check.State) -> Color {
        switch state {
        case .ok: return .white.opacity(0.85)
        case .failed: return Color(cgColor: Look.error.gradient.bottom.cg)
        case .pending: return .white.opacity(NotchLayout.secondaryTextOpacity)
        }
    }
}
