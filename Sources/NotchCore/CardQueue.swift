import Foundation

/// 回答：刘海上此刻放哪张卡、什么时候换下一张、放出来那一刻响不响（docs/ui.md「卡片」）。
/// 两层：红卡挂着时是底层；临时卡排一个先进先出队列，一次放一张，放完回到红卡。红卡挂着时外部插件的卡不上台，内置的越过它们先放。
/// 纯状态机：喂事件和当前时间；不知道卡长什么样、该响哪个音，不放声音、不起定时器（App 按 `deadline` 到点调 `tick`）。
/// 红卡该不该挂着由外面判定（当前状态 + dismissedViolationSince），这里只管它什么时候在台面上。
public struct CardQueue<Item: Equatable & Sendable>: Sendable {
    /// 同一个 key 还没放的旧卡，被后来的卡原地替换
    public enum Key: Hashable, Sendable {
        case session(Int32)
        case recovered
        /// 外部插件自己定的组：同一个插件里同组只留最新（照 terminal-notifier `-group`）
        case group(plugin: String, name: String)
        /// 外部插件的一个活动弹的卡：之后的更新原地刷新它（`update`）
        case activity(plugin: String, id: String)

        /// 组和活动的卡属于哪个外部插件；内置插件的是 nil
        public var plugin: String? {
            switch self {
            case .group(let p, _), .activity(let p, _): return p
            case .session, .recovered: return nil
            }
        }
    }

    /// 每个外部插件至多排这么多张，再来就丢它最旧的那张：红卡挂久了，撤掉后不补放一长串
    public static var maxWaitingPerPlugin: Int { 3 }

    /// 一张临时卡
    public struct Notice: Equatable, Sendable {
        public var card: Item
        /// nil：从不替换
        public var key: Key?
        /// 放多久（「卡片停留」设置；恢复卡固定 4 秒）
        public var seconds: TimeInterval
        /// 说的是此刻的状态（介入卡）：同一个会话来了新卡、或被 `withdraw`，排着的、正在放的都作废
        public var lapses: Bool
        /// 外部插件的 id；nil 是内置插件的卡。外部的卡红卡挂着时排着不放，红卡撤了再放（CLAUDE.md 硬规则「插件」）
        public var externalPluginID: String?
        /// 排到这个时刻还没放就不放了（外部插件的消息过期，红卡挂着或熄屏时可能排很久）
        public var staleAt: Date?

        public init(card: Item, key: Key?, seconds: TimeInterval, lapses: Bool = false, externalPluginID: String? = nil, staleAt: Date? = nil) {
            self.card = card
            self.key = key
            self.seconds = seconds
            self.lapses = lapses
            self.externalPluginID = externalPluginID
            self.staleAt = staleAt
        }
    }

    public enum Showing: Equatable, Sendable {
        case notice(Item)
        /// persistent：「红卡一直保留，直到恢复」
        case alert(persistent: Bool)
    }

    /// 每次输入之后 App 要做的事；台面上放什么看 `showing`
    public struct Change: Equatable, Sendable {
        /// 台面上这张卡刚放出来、该响它的声音
        public var sound = false
        /// 红卡收起了、但违规没恢复（用户点了 ×，或不常驻的红卡到时）：App 记作关掉了这一次违规
        public var alertDismissed = false

        public init(sound: Bool = false, alertDismissed: Bool = false) {
            self.sound = sound
            self.alertDismissed = alertDismissed
        }
    }

    private struct Entry: Sendable {
        var notice: Notice
        /// 放出来过、响过（被违规打断后回到队首的卡，重放时不再响）
        var sounded = false
    }

    private enum Stage: Sendable {
        case notice(Entry)
        case alert
    }

    /// 红卡挂着（不论此刻在不在台面上）时是它常不常驻；没挂着是 nil
    private var alert: Bool?
    private var stage: Stage?
    private var waiting: [Entry] = []
    /// 台面上这张卡的倒计时；nil 表示一直放着（常驻红卡放完第一次之后）。鼠标停在卡上或看不见时暂停
    public private(set) var countdown: CardCountdown?
    public private(set) var hovering = false
    /// 熄屏或锁屏：新卡不放、不响，倒计时停住
    private var away = false
    /// 看不见时挂上的红卡，回来再响
    private var alertSoundDue = false

    public init() {}

    public var showing: Showing? {
        switch stage {
        case .notice(let e): return .notice(e.notice.card)
        case .alert: return alert.map { .alert(persistent: $0) }
        case nil: return nil
        }
    }

    /// 台面上的卡到点要换的时刻；暂停中或一直放着时是 nil
    public func deadline(now: Date) -> Date? {
        guard let c = countdown, !c.isPaused else { return nil }
        return now.addingTimeInterval(c.remaining(at: now))
    }

    public mutating func post(_ notice: Notice, now: Date) -> Change {
        if case .notice(let e) = stage, e.notice.lapses, let key = notice.key, e.notice.key == key {
            // 正在放的介入卡被同一个会话的新卡顶掉
            waiting.removeAll { $0.notice.key == key }
            waiting.insert(Entry(notice: notice), at: 0)
            return next(now)
        }
        if let key = notice.key, let i = waiting.firstIndex(where: { $0.notice.key == key }) {
            waiting[i] = Entry(notice: notice)
        } else if notice.key == .recovered {
            // 恢复卡说的是守卫的事：排在违规期间攒下的外部卡前面
            waiting.insert(Entry(notice: notice), at: waiting.firstIndex { $0.notice.externalPluginID != nil } ?? waiting.endIndex)
        } else {
            waiting.append(Entry(notice: notice))
            if let plugin = notice.externalPluginID, waiting.count(where: { $0.notice.externalPluginID == plugin }) > Self.maxWaitingPerPlugin {
                waiting.remove(at: waiting.firstIndex { $0.notice.externalPluginID == plugin }!)
            }
        }
        return yieldable ? next(now) : Change()
    }

    /// 台面可以让给排着的卡：空着，或常驻红卡已经放过第一次；否则等台面上这张放完
    private var yieldable: Bool {
        switch stage {
        case nil: return true
        case .alert: return countdown == nil
        case .notice: return false
        }
    }

    /// 新的一次违规开始：正在放的临时卡回到队首，红卡插上来先放满一次 `seconds`，响 Basso（看不见时等看得见再响）。
    /// 恢复卡说的是上一次违规，不论排着还是正在放都作废
    public mutating func raiseAlert(persistent: Bool, seconds: TimeInterval, now: Date) -> Change {
        guard alert == nil else { return Change() }
        alert = persistent
        if case .notice(let e) = stage { waiting.insert(e, at: 0) }
        waiting.removeAll { $0.notice.key == .recovered }
        stage = .alert
        start(seconds, now: now)
        alertSoundDue = away
        return Change(sound: !away)
    }

    /// 红卡不该挂了（回到 healthy，或别处记下关掉了这一次）
    public mutating func clearAlert(now: Date) -> Change {
        alert = nil
        alertSoundDue = false
        guard case .alert = stage else { return Change() }
        return next(now)
    }

    /// 用户点了台面上这张卡的 ×
    public mutating func dismiss(now: Date) -> Change {
        switch stage {
        case .notice: return next(now)
        case .alert:
            alert = nil
            alertSoundDue = false
            var change = next(now)
            change.alertDismissed = true
            return change
        case nil: return Change()
        }
    }

    /// 到点了：换下一张（App 按 `deadline` 调；早调了不变）
    public mutating func tick(now: Date) -> Change {
        guard let c = countdown, c.remaining(at: now) <= 0, let stage else { return Change() }
        switch stage {
        case .notice: return next(now)
        case .alert:
            guard let persistent = alert else { preconditionFailure("台面上是红卡，红卡一定挂着") }
            if !persistent { return dismiss(now: now) }
            // 常驻红卡放满第一次：有能盖它的就让，没有就一直放着
            return next(now)
        }
    }

    /// 这个会话不再需要你介入：撤掉它的介入卡，排着的、正在放的都撤
    public mutating func withdraw(_ key: Key, now: Date) -> Change {
        waiting.removeAll { $0.notice.key == key && $0.notice.lapses }
        guard case .notice(let e) = stage, e.notice.key == key, e.notice.lapses else { return Change() }
        return next(now)
    }

    /// 撤掉排着的、正在放的这些卡（关掉了发它们的插件）
    public mutating func discard(where shouldGo: (Notice) -> Bool, now: Date) -> Change {
        waiting.removeAll { shouldGo($0.notice) }
        guard case .notice(let e) = stage, shouldGo(e.notice) else { return Change() }
        return next(now)
    }

    /// 同一个 key 的卡排着或正在放：原地换成这张，不重放、不响、不重新倒计时；返回找没找到。找不到不放
    public mutating func update(_ card: Item, key: Key) -> Bool {
        var found = false
        for i in waiting.indices where waiting[i].notice.key == key {
            waiting[i].notice.card = card
            found = true
        }
        if case .notice(var e) = stage, e.notice.key == key {
            e.notice.card = card
            stage = .notice(e)
            found = true
        }
        return found
    }

    /// 鼠标停在卡上：倒计时暂停；移开从剩下的时间继续
    public mutating func setHovering(_ on: Bool, now: Date) -> Change {
        hovering = on
        syncCountdown(now)
        return Change()
    }

    /// 熄屏或锁屏（docs/ui.md「卡片」8）：台面上的卡停住，新卡排着不放、不响；回来接着放，欠着的红卡声音这时响
    public mutating func setAway(_ on: Bool, now: Date) -> Change {
        guard on != away else { return Change() }
        away = on
        if on {
            syncCountdown(now)
            return Change()
        }
        // 能让的时候欠着的红卡声音一定已经响过（它只在红卡第一次放时欠下）
        if yieldable { return next(now) }
        syncCountdown(now)
        defer { alertSoundDue = false }
        return Change(sound: alertSoundDue)
    }

    /// 一张卡上台、开始倒计时。悬停按卡算：鼠标移进这张卡才停，换上来时鼠标恰好在原处不算
    private mutating func start(_ seconds: TimeInterval, now: Date) {
        countdown = CardCountdown(total: seconds, now: now)
        hovering = false
        syncCountdown(now)
    }

    private mutating func syncCountdown(_ now: Date) {
        if hovering || away { countdown?.pause(at: now) } else { countdown?.resume(at: now) }
    }

    /// 下一张能上台的：红卡挂着时跳过不能盖它的
    private var nextIndex: Int? {
        alert == nil ? waiting.indices.first : waiting.firstIndex { $0.notice.externalPluginID == nil }
    }

    /// 台面上这张放完了：丢掉排着过期的，放能上台的第一张临时卡；没有就回到挂着的红卡（一直放着、不再响）；都没有就收起
    private mutating func next(_ now: Date) -> Change {
        waiting.removeAll { $0.notice.staleAt.map { $0 <= now } ?? false }
        if let i = nextIndex, !away {
            var e = waiting.remove(at: i)
            let sound = !e.sounded
            e.sounded = true
            stage = .notice(e)
            start(e.notice.seconds, now: now)
            return Change(sound: sound)
        }
        stage = alert == nil ? nil : .alert
        countdown = nil
        return Change()
    }
}
