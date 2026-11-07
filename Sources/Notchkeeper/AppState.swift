import AgentCore
import AppKit
import MascotCore
// 只取用到的：GuardCore 有个叫 `Observation` 的类型（守卫一轮的观测），整个导入会盖住 @Observable 展开时用的 Observation 模块
import struct GuardCore.GuardDisplay
import struct GuardCore.IPv4
import GuardProbes
import NotchCore
import Observation
import PluginCore

/// 视图按属性订阅（Observation）：只有读了 `display` 的视图（展开的面板、设置页）才随守卫每轮重算，
/// 收起的刘海只跟着 `presentation` 等真正变了的东西走
/// @see https://developer.apple.com/documentation/observation
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    let store = ConfigStore.shared

    /// 守卫最近一轮的结果（`GuardMonitor`）
    private(set) var display = GuardDisplay.checking
    /// 由 display 和用户关掉的是哪一次算出来（`ViolationAlert`），界面只看它
    private(set) var presentation: GuardPresentation
    /// 面板列的会话（AgentCore 判定的、活着的终端 claude）
    private(set) var sessions: [Session] = []
    /// Claude Code 各会话合起来此刻是什么（AgentCore 判定）；没有要画的是 nil
    private(set) var agentActivity: AgentActivity?
    /// 已登记的外部插件（`plugins/<id>/manifest.json`）
    private(set) var manifests: [String: Manifest] = [:]
    /// 外部插件开着的活动
    private(set) var activities = ActivityBoard()
    @ObservationIgnored private var activityExpiry: DispatchWorkItem?

    @ObservationIgnored private var violationAlert: ViolationAlert

    /// 守卫每查完一轮都调用（不论有没有变化），参数是红卡要做的事
    @ObservationIgnored var onAlertAction: ((ViolationAlert.Action) -> Void)?
    /// AgentCore 判定的事件，连同同一次更新的会话列表
    @ObservationIgnored var onAgentEvents: (([AgentEvent], [Session]) -> Void)?
    /// 外部插件被卸掉（设置页、`pipctl plugin uninstall`、手动删目录都算）：App 撤掉它排着的卡
    @ObservationIgnored var onPluginsRemoved: ((Set<String>) -> Void)?
    /// 订阅守卫每轮结果的长任务；`stopWatchingGuard()` / deinit 取消，流随之结束、探针停下
    @ObservationIgnored private var guardTask: Task<Void, Never>?
    @ObservationIgnored private var agentWatcher: AgentWatcher?

    init() {
        violationAlert = ViolationAlert(.checking)
        presentation = violationAlert.presentation
    }

    func start() {
        // 只在 App 运行时检查（docs/egress-guard.md「什么时候查」）；允许列表每轮从内存里的配置取
        let store = store
        watchGuard(GuardMonitor(probes: .live(), allowlist: { await store.allowlistIPs }).displays())
        let watcher = AgentWatcher { update in
            DispatchQueue.main.async { AppState.shared.applyAgent(update) }
        }
        watcher.start()
        agentWatcher = watcher
    }

    /// 每来一个显示就 apply 一次。参数是流，测试可以喂假的；再调一次会先取消旧的订阅
    func watchGuard(_ displays: AsyncStream<GuardDisplay>) {
        guardTask?.cancel()
        guardTask = Task { [weak self] in
            for await d in displays { self?.apply(d) }
        }
    }

    func stopWatchingGuard() {
        guardTask?.cancel()
        guardTask = nil
    }

    deinit { guardTask?.cancel() }

    func apply(_ d: GuardDisplay) {
        if d != display { display = d }
        let action = violationAlert.read(d, autoAlert: store.config.autoAlert)
        publishPresentation()
        onAlertAction?(action)
    }

    private func publishPresentation() {
        let old = presentation, new = violationAlert.presentation
        guard new != old else { return }
        presentation = new
        // 日志不记录 IP
        if new.title != old.title { Log.write("出口守卫：\(new.title)") }
    }

    private func applyAgent(_ update: AgentWatcher.Update) {
        if update.activity != agentActivity { agentActivity = update.activity }
        if update.sessions != sessions { sessions = update.sessions }
        for event in update.events {
            switch event {
            case .turnDone(let pid): Log.write("agent：回合做完（pid \(pid)）")
            case .turnFailed(let pid): Log.write("agent：回合出错（pid \(pid)）")
            case .needsYou(let need, let pid): Log.write("agent：需要你介入，\(need)（pid \(pid)）")
            case .needsYouEnded(let pid): Log.write("agent：介入结束（pid \(pid)）")
            }
        }
        // 关掉 Claude Code 插件：照常判定，只是不弹卡
        if !update.events.isEmpty, store.config.isEnabled(PluginID.claudeCode) { onAgentEvents?(update.events, update.sessions) }
    }

    // MARK: 插件

    /// 面板里各段的插件，按用户排的顺序：Claude Code 和登记了的外部插件，开没开都在。出口守卫固定在顶上，不在这里
    var sectionPlugins: [String] {
        store.config.ordered([PluginID.claudeCode] + manifests.keys.sorted())
    }

    /// 开着的插件各自的状态：守卫在前，其余按段的顺序（一样急时排在前面的上位）
    var statuses: [PluginStatus] {
        let c = store.config
        var all: [PluginStatus] = c.isEnabled(PluginID.exitGuard) ? [PluginStatus(guard: presentation)] : []
        for id in sectionPlugins where c.isEnabled(id) {
            all.append(id == PluginID.claudeCode ? PluginStatus(agent: agentActivity) : PluginStatus(external: id, urgency: activities.urgency(for: id)))
        }
        return all
    }

    /// 收起时 Pip 和右耳画谁（docs/ui.md「面板布局」）；nil：Pip 空闲、右耳空着
    var lead: PluginStatus? { PluginStatus.lead(statuses, resident: store.config.resident) }
    /// Pip 画哪个（docs/mascot.md §2「优先级」换成了插件的紧急程度）。晕、睡着由 `MascotDirector.shown` 叠上去
    var look: Look { lead?.look ?? .idle }

    /// 面板里开着的段和它们的行（空的段也在，画不画由面板定）
    var sections: [PanelSection] {
        let c = store.config
        return sectionPlugins.filter(c.isEnabled).map { id in
            PanelSection(plugin: id, rows: id == PluginID.claudeCode ? sessions.map(PanelRow.init) : activities.rows(for: id), maxRows: c.maxRows(id))
        }
    }

    /// 设置页上插件的名字：外部的用它登记的名字，登记读不到时用 id
    func pluginName(_ id: String) -> String {
        switch id {
        case PluginID.exitGuard: return String(localized: "出口守卫")
        case PluginID.claudeCode: return "Claude Code"
        default: return manifests[id]?.name ?? id
        }
    }

    /// 重读插件登记：启动、装卸终端插件、打开设置页时
    func reloadManifests() {
        setManifests(InboxWatcher.manifests())
    }

    /// 卸掉了的插件（目录没了）：撤它的行，告诉 App 撤卡。没登记的插件发来的已经一律丢掉，留下的卡和行也不该再出来。
    /// 目录还在、只是 manifest.json 一时读不了（编辑器正在写）的不算：撤掉的卡回不来
    private func setManifests(_ m: [String: Manifest]) {
        guard m != manifests else { return }
        let removed = Set(manifests.keys).subtracting(m.keys)
            .filter { !FileManager.default.fileExists(atPath: PluginPaths.plugins.appendingPathComponent($0).path) }
        manifests = m
        guard !removed.isEmpty else { return }
        for id in removed { activities.remove(plugin: id) }
        scheduleActivityExpiry()
        onPluginsRemoved?(removed)
    }

    /// 收件箱收下的一批：记下当时的登记，活动记上面板，返回要弹或要刷新的卡（App 交给刘海）
    func applyInbox(_ batch: InboxWatcher.Batch) -> [ActivityBoard.CardChange] {
        setManifests(batch.plugins)
        guard !batch.activities.isEmpty else { return [] }
        let now = Date()
        let changes = batch.activities.compactMap { activities.apply($0, now: now) }
        scheduleActivityExpiry()
        return changes
    }

    /// 设置里关掉一个外部插件：它的行撤掉
    func removeActivities(of plugin: String) {
        activities.remove(plugin: plugin)
        scheduleActivityExpiry()
    }

    /// 活动过期的时刻一次性定时（最长 8 小时一次），到点撤行
    private func scheduleActivityExpiry() {
        activityExpiry?.cancel()
        guard let at = activities.deadline else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.activities.expire(now: Date())
            self.scheduleActivityExpiry()
        }
        activityExpiry = work
        // 墙钟：睡眠期间也算时间，开盖后过了期的马上撤（`deadline:` 按开机时长算，睡眠时不走）
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, at.timeIntervalSinceNow), execute: work)
    }

    /// 开关出口守卫插件（关的是提醒，不是判定）：关掉撤红卡，打开按最近一轮的结果再判一次
    func setGuardEnabled(_ on: Bool) {
        onAlertAction?(violationAlert.setEnabled(on, autoAlert: store.config.autoAlert))
        Log.write("出口守卫插件：\(on ? "打开" : "关掉")")
    }

    /// 用户关掉了红卡（或非常驻红卡到时收起）
    func dismissViolation() {
        violationAlert.dismiss()
        publishPresentation()
    }

    #if DEBUG
    /// scripts/demo.sh alert
    func demoAlert() { onAlertAction?(violationAlert.demo()) }
    #endif

    /// 允许列表用 GuardCore 的 IPv4 校验，和守卫每轮取列表时的规则一致（`ConfigStore.allowlistIPs`）
    @discardableResult
    func addAllowed(_ raw: String) -> Bool {
        let ip = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPv4(ip) != nil, !store.config.allowlist.contains(ip) else { return false }
        store.config.allowlist.append(ip)
        Log.write("允许列表：新增 1 项")
        return true
    }

    func removeAllowed(_ ip: String) {
        store.config.allowlist.removeAll { $0 == ip }
        Log.write("允许列表：移除 1 项")
    }
}

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Notchkeeper/notchkeeper.log")
    /// 本地时间 + 时区偏移，例如 2026-10-28 14:03:21 -07:00
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss xxxxx"
        return f
    }()

    /// 主线程和 `AgentWatcher` 的队列都会写：串行起来，行不串、`formatter` 不被同时用
    private static let queue = DispatchQueue(label: "com.notchkeeper.log")

    static func write(_ msg: String) {
        queue.sync {
            // 带 pid：同时有两个实例时分得清是谁写的
            let line = "\(formatter.string(from: Date())) [pid \(getpid())] \(msg)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }
}
