import Foundation
import GuardCore

/// 回答：出口守卫每一轮做什么、下一轮什么时候开始——三路探针并发跑、交给 `EgressGuard` 判定，每轮的结果推给 App。
/// 判定规则在 GuardCore，探测细节在各个 Probe，这里只编排；不画界面，也不拦截（拦截归防火墙，docs/firewall.md）。
/// 只在 App 运行时检查：App 退出、流被取消就停（docs/egress-guard.md「什么时候查」）。
///
/// 网络路径（有没有物理网络）只用来给 unknown 标原因（offline / probeFailed），不影响 verdict。
public struct GuardMonitor: Sendable {
    public var probes: Probes
    /// 每轮开始时取一次允许列表：设置页改了下一轮就生效
    public var allowlist: @Sendable () async -> Set<IPv4>
    public var interval: Duration = .seconds(5)
    /// 一轮的总截止时间。比出口探针的 6 秒 HTTP 超时多留 2 秒；那个超时是连接空闲时长，不封顶一次请求的总时长。
    /// 赶不上截止的探针算「没有结果」，见 `Deadline`
    public var roundDeadline: Duration = .seconds(8)
    public var now: @Sendable () -> Date = Date.init

    public init(probes: Probes, allowlist: @escaping @Sendable () async -> Set<IPv4>) {
        self.probes = probes
        self.allowlist = allowlist
    }

    /// 一轮要跑的探针。测试换成桩；`live()` 是真实探针（网络路径监视器在这里创建，所以只调一次）
    public struct Probes: Sendable {
        public var route: @Sendable () async -> String?
        public var clash: @Sendable () -> Bool?
        public var path: any NetworkPathSource
        public var egress: EgressProbe

        public init(route: @escaping @Sendable () async -> String?, clash: @escaping @Sendable () -> Bool?,
                    path: any NetworkPathSource, egress: EgressProbe) {
            self.route = route
            self.clash = clash
            self.path = path
            self.egress = egress
        }

        public static func live() -> Probes {
            Probes(route: { await RouteProbe.current() }, clash: { ClashProbe.current() }, path: LiveNetworkPath(), egress: .live)
        }
    }

    /// 开始检查：每查完一轮发一次结果（结果没变也发，订阅方自己比）。只留最新一个值，订阅方慢了不会积压旧结果。
    /// 订阅方停止迭代（任务取消或流被释放）时，正在跑的探针被取消，被打断的那一轮不发。
    public func displays() -> AsyncStream<GuardDisplay> {
        let (stream, continuation) = AsyncStream.makeStream(of: GuardDisplay.self, bufferingPolicy: .bufferingNewest(1))
        let loop = Task {
            await run { continuation.yield($0) }
            continuation.finish()
        }
        continuation.onTermination = { _ in loop.cancel() }
        return stream
    }

    func run(_ publish: (GuardDisplay) -> Void) async {
        var egressGuard = EgressGuard()
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let start = clock.now
            let allowlist = await allowlist()
            let round = await Self.observe(deadline: start + roundDeadline, clock: clock, probes: probes)
            if Task.isCancelled { break } // 探针被取消，这一轮的数据不完整
            let checkedAt = now()
            let verdict = egressGuard.observe(round.observation, allowlist: allowlist, at: checkedAt)
            publish(GuardDisplay(verdict: verdict, observation: round.observation, allowlist: allowlist, networkPath: round.path,
                                 violatedSince: egressGuard.violatedSince, checkedAt: checkedAt))
            // 上一轮没结束绝不开下一轮（路由子进程、HTTP 最长 6 秒都可能比间隔长）；慢了不补跑，紧接着开一轮。
            // ContinuousClock 在睡眠时照走：Mac 醒来后马上查一轮
            let next = max(start + interval, clock.now)
            do { try await Task.sleep(until: next, clock: clock) } catch { break } // 只有取消会抛
        }
    }

    /// 一轮的探针结果。`path == nil` 是没拿到网络快照（没赶上截止或监视器还没回调）
    struct Round {
        var observation: Observation
        var path: NetworkPath?
    }

    /// 路由 + Clash、出口 IP、网络路径三路并发，共用一个截止时间；各自单独截止，一路卡住不拖掉另两路的结果。
    /// Clash 是一次很快的系统调用，放到 GCD 线程，不占 Swift 并发的协作线程池；路由子进程超时会被结束（`RouteProbe.output`）。
    static func observe(deadline: ContinuousClock.Instant, clock: ContinuousClock, probes: Probes) async -> Round {
        let route = probes.route, clashProbe = probes.clash, pathSource = probes.path, egressProbe = probes.egress
        async let local = Deadline.run(by: deadline, clock: clock) { () async -> (String?, Bool?) in
            async let clash = withCheckedContinuation { c in
                DispatchQueue.global(qos: .utility).async { c.resume(returning: clashProbe()) }
            }
            return (await route(), await clash)
        }
        async let egress = Deadline.run(by: deadline, clock: clock) { await egressProbe.current() }
        async let path = Deadline.run(by: deadline, clock: clock) { await pathSource.current() }
        return Round(observation: merge(local: await local, egress: await egress), path: await path ?? nil)
    }

    /// 把赶上 / 没赶上截止的探针结果合成一轮观测。`nil` 是没赶上：只能算「没有结果」，绝不算「好」
    static func merge(local: (String?, Bool?)?, egress: EgressProbe.Sample?) -> Observation {
        Observation(clashRunning: local?.1, routeInterface: local?.0, egressIPs: egress?.ips ?? [])
    }
}
