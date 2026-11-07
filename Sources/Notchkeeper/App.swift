import AppKit
import AgentCore
import Combine
import NotchCore
import PluginCore

@main
@MainActor
enum NotchkeeperMain {
    static func main() {
        // 在创建 NSApplication 之前：第二个实例什么都不画就退出
        guard SingleInstance.claim() else { exit(0) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState.shared
    var settings: SettingsWindowController!
    var notch: NotchController!
    private var cancellables = Set<AnyCancellable>()
    private var sigterm: DispatchSourceSignal?
    private var inbox: InboxWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .utility).async { LegacyGuardd.remove() }
        ClaudeMod.refreshIfInstalled()
        CommandLineTool.install()
        TerminalPlugin.refreshIfInstalled()
        notch = NotchController()
        settings = SettingsWindowController(state: state, notch: notch)
        notch.onOpenSettings = { [weak self] pane in self?.settings.show(pane) }
        notch.contextMenu = buildMenu()
        NSApp.mainMenu = buildMainMenu()

        state.onAlertAction = { [weak self] in self?.notch.alertAction($0) }
        notch.onAlertDismissed = { [weak self] in self?.state.dismissViolation() }
        state.onAgentEvents = { [weak self] in self?.notch.agentEvents($0, sessions: $1) }
        state.onPluginsRemoved = { [weak self] ids in self?.notch.discard { $0.externalPluginID.map(ids.contains) ?? false } }

        #if DEBUG
        listenForDemo()
        #endif

        // 设置变化（含 config.json 热加载）实时生效
        ConfigStore.shared.$config
            .receive(on: RunLoop.main)
            .sink { [weak self] c in
                self?.notch.setHoverEnabled(c.hoverExpand)
                MascotDirector.shared.setFollowsMouse(c.mascotFollowsMouse)
                self?.pluginsChanged(c)
            }
            .store(in: &cancellables)

        MascotDirector.shared.onPausedChange = { [weak self] in self?.notch.setScreenAway($0) }
        MascotDirector.shared.start(notchRect: { [weak self] in self?.notch.anchorRect ?? .zero })
        // 守卫插件关着：在第一次读状态之前关掉提醒，免得启动时红卡闪一下
        if !ConfigStore.shared.config.isEnabled(PluginID.exitGuard) { state.setGuardEnabled(false) }
        state.start()
        state.reloadManifests()
        // 外部插件的卡和活动（docs/ui.md「卡片」）：红卡挂着时外部的卡排着，由 `CardQueue` 按 `externalPluginID` 管
        let inbox = InboxWatcher { batch in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // 开没开只在这里按当前配置判：收件箱的队列上读不到，异步告诉它又会和刚关掉的那一下竞争
                let c = ConfigStore.shared.config
                var on = batch
                on.cards.removeAll { !self.isEnabled($0.card) }
                on.activities.removeAll { !c.isEnabled($0.plugin) }
                let dropped = batch.cards.count + batch.activities.count - on.cards.count - on.activities.count
                if dropped > 0 { Log.write("插件：关着的插件发来 \(dropped) 条，丢掉") }
                for a in on.cards {
                    Log.write("插件 \(a.card.externalPluginID ?? "")：收到一张卡") // id 已按格式校验过，可以进日志
                    self.postExternal(a)
                }
                for change in self.state.applyInbox(on) { self.notch.activityCard(change) }
            }
        }
        inbox.start()
        self.inbox = inbox
        watchSIGTERM()
        Log.write("Notchkeeper 启动")
        Log.write("notch screen: \(notch.hasNotch)")
    }

    /// 退出前记一行日志（带原因），再取消守卫订阅，目录监听和定时器跟着关掉
    /// @see https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationwillterminate(_:)
    func applicationWillTerminate(_ notification: Notification) {
        Log.write("Notchkeeper 退出（\(Self.quitReason ?? "原因不明：有人调了 terminate")）")
        state.stopWatchingGuard()
    }

    /// 退出原因。本 App 自己发起的退出（菜单、设置页、SIGTERM）先记下再 terminate；
    /// 注销、关机或别的 App 让它退出时，AppKit 收到 quit Apple 事件后也走 terminate，在这里认出来。
    /// 崩溃和 SIGKILL 不经过 terminate，记不到。
    private static var quitReason: String?

    /// 自己发起的退出都走这里，日志里才分得清是谁让它退的
    /// @see https://developer.apple.com/documentation/appkit/nsapplication/terminate(_:)
    static func quit(reason: String) {
        if quitReason == nil { quitReason = reason }
        NSApp.terminate(nil)
    }

    /// terminate 之后、真正退出之前调用；此时正在处理的 Apple 事件若是 quit（'aevt'/'quit'），就是系统或别的 App 要它退出
    /// @see https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:)
    /// @see https://developer.apple.com/documentation/foundation/nsappleeventmanager/currentappleevent
    /// @see https://developer.apple.com/documentation/foundation/nsappleeventdescriptor/eventid
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.quitReason == nil, let e = NSAppleEventManager.shared().currentAppleEvent,
           e.eventClass == AEEventClass(kCoreEventClass), e.eventID == AEEventID(kAEQuitApplication) {
            Self.quitReason = "收到 quit Apple 事件：注销、关机或别的 App 要求退出"
        }
        return .terminateNow
    }

    /// kill / launchctl 发来的 SIGTERM 默认直接杀进程，applicationWillTerminate 不会跑。
    /// 先把默认动作设成忽略，再用 dispatch source 在主队列接住：记日志，然后正常 terminate。
    /// @see https://developer.apple.com/library/archive/documentation/General/Conceptual/ConcurrencyProgrammingGuide/GCDWorkQueues/GCDWorkQueues.html
    /// @see https://developer.apple.com/documentation/dispatch/dispatchsource/makesignalsource(signal:queue:)
    /// @see https://developer.apple.com/documentation/dispatch/dispatchobject/activate()
    private func watchSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                Log.write("收到 SIGTERM，正常退出")
                Self.quit(reason: "SIGTERM")
            }
        }
        source.activate()
        sigterm = source
    }

    /// 已经在运行时再打开（启动台、访达双击、`open -a`、设置开着时点 Dock 图标）：没有菜单栏图标可点，直接打开设置
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    /// 刘海右键菜单
    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item(String(localized: "设置…"), #selector(openSettings)))
        m.addItem(item(String(localized: "拷贝出口 IP"), #selector(copyEgressIP)))
        m.addItem(.separator())
        m.addItem(item(String(localized: "退出 Pip"), #selector(quit)))
        return m
    }

    /// 设置窗口开着时显示在菜单栏（那时是普通 App），也让 ⌘, / ⌘Q / ⌘W 和输入框的编辑快捷键生效
    func buildMainMenu() -> NSMenu {
        let app = NSMenu()
        app.addItem(item(String(localized: "设置…"), #selector(openSettings), ","))
        app.addItem(.separator())
        app.addItem(item(String(localized: "退出 Pip"), #selector(quit), "q"))

        // target 为 nil：沿响应链交给当前窗口 / 输入框
        let window = NSMenu(title: String(localized: "窗口"))
        window.addItem(withTitle: String(localized: "关闭"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenu(title: String(localized: "编辑"))
        edit.addItem(withTitle: String(localized: "撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "重做"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let main = NSMenu()
        for sub in [app, edit, window] {
            let root = NSMenuItem(title: sub.title, action: nil, keyEquivalent: "")
            root.submenu = sub
            main.addItem(root)
        }
        return main
    }

    private func item(_ title: String, _ sel: Selector, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    /// 上一次看到的插件开关：只在变了时动手
    private var enabledPlugins: [String: Bool] = [:]

    /// 关掉一个插件（docs/ui.md「面板布局」）：关的是提醒，不是判定。出口守卫撤红卡，Claude Code 撤会话的卡，外部插件撤卡、撤行、之后的消息丢掉
    private func pluginsChanged(_ c: Config) {
        let ids = [PluginID.exitGuard, PluginID.claudeCode] + state.manifests.keys
        let now = Dictionary(uniqueKeysWithValues: ids.map { ($0, c.isEnabled($0)) })
        defer { enabledPlugins = now }
        guard !enabledPlugins.isEmpty else { return } // 启动时只记下：守卫的开关在第一次读状态前已经设好
        for (id, on) in now where enabledPlugins[id, default: true] != on {
            switch id {
            case PluginID.exitGuard:
                state.setGuardEnabled(on)
                // 红卡由 setGuardEnabled 撤；守卫的另一种卡是恢复卡
                if !on { notch.discard { $0.key == .recovered } }
            case PluginID.claudeCode:
                if !on { notch.discard { if case .session = $0.key { true } else { false } } }
                Log.write("Claude Code 插件：\(on ? "打开" : "关掉")")
            default:
                if !on {
                    state.removeActivities(of: id)
                    notch.discard { $0.externalPluginID == id }
                }
                Log.write("插件 \(id)：\(on ? "打开" : "关掉")")
            }
        }
    }

    /// 点了要跳回的那个终端正在眼前（shell 发来的卡）：不弹
    private func postExternal(_ a: InboxGate.Admitted) {
        guard case .terminal(let terminal) = a.card.action, case .tty = terminal.identity else {
            notch.post(a.card, key: a.key, staleAt: a.staleAt)
            return
        }
        Ghostty.isFocused(terminal) { focused in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if focused {
                    Log.write("插件：正看着要跳回的终端，这张卡不弹")
                } else if self.isEnabled(a.card) { // 等 Ghostty 回话时可能刚关掉这个插件
                    self.notch.post(a.card, key: a.key, staleAt: a.staleAt)
                }
            }
        }
    }

    private func isEnabled(_ card: Card) -> Bool {
        card.externalPluginID.map(ConfigStore.shared.config.isEnabled) ?? true
    }

    @objc func openSettings() { settings.show() }
    /// 拷贝完整的出口 IP（和刘海、设置页显示的同一个值）
    @objc func copyEgressIP() {
        guard let ip = state.display.egressIP else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
    }
    @objc func quit() { Self.quit(reason: "菜单里点了退出") }
}

/// 没有出口 IP 时「拷贝出口 IP」灰掉
/// @see https://developer.apple.com/documentation/appkit/nsmenuitemvalidation/validatemenuitem(_:)
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(copyEgressIP) ? state.display.egressIP != nil : true
    }
}
