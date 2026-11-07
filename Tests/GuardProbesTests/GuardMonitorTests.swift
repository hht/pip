import Foundation
import Testing
import GuardCore
@testable import GuardProbes

private let allowed = IPv4("198.51.100.8")!
private let up = NetworkPath(physicalInterfaceSatisfied: true, hasDefaultRoute: true)
private let down = NetworkPath(physicalInterfaceSatisfied: false, hasDefaultRoute: false)

private struct StubPath: NetworkPathSource {
    var path: NetworkPath?
    var hang = false
    func current() async -> NetworkPath? {
        if hang { try? await Task.sleep(for: .seconds(30)) }
        return path
    }
}

private func egress(_ ips: [IPv4]) -> EgressProbe {
    EgressProbe(endpoints: [URL(string: "https://example.invalid")!], fetch: { _ in
        guard let ip = ips.first else { throw URLError(.notConnectedToInternet) }
        return (Data(ip.description.utf8), 200)
    })
}

private func probes(route: String? = "utun1024", path: StubPath = StubPath(path: up), ips: [IPv4] = [allowed]) -> GuardMonitor.Probes {
    GuardMonitor.Probes(route: { route }, clash: { true }, path: path, egress: egress(ips))
}

@Suite struct RoundDeadline {
    private let clock = ContinuousClock()

    @Test func onTimeResultPassesThrough() async {
        #expect(await Deadline.run(by: clock.now + .seconds(5), clock: clock) { 42 } == 42)
    }

    /// 超时就是「没有结果」，而且要等被取消的工作真的停下才返回（不留后台任务）
    @Test func missedDeadlineIsNoResultAndCancelsWork() async {
        let begin = clock.now
        let result = await Deadline.run(by: begin + .milliseconds(50), clock: clock) { () async -> Int in
            do { try await Task.sleep(for: .seconds(3)) } catch { return -1 }
            return 42
        }
        #expect(result == nil)
        #expect(clock.now - begin < .seconds(1))
    }
}

@Suite struct RoundMerge {
    private func verdict(_ o: Observation) -> Verdict {
        var g = EgressGuard()
        return g.observe(o, allowlist: [allowed])
    }

    @Test func onTimeProbesPassThrough() {
        let o = GuardMonitor.merge(local: ("utun1024", true), egress: EgressProbe.Sample(ips: [allowed]))
        #expect(o.routeInterface == "utun1024" && o.clashRunning == true && o.egressIPs == [allowed])
        #expect(verdict(o) == .healthy)
    }

    /// 本地探针超时：路由和 Clash 都是未知，绝不算「好」
    @Test func missedLocalIsUnknown() {
        let o = GuardMonitor.merge(local: nil, egress: EgressProbe.Sample(ips: [allowed]))
        #expect(o.routeInterface == nil && o.clashRunning == nil)
        #expect(verdict(o) == .unknown)
    }

    /// 出口探针超时：没有 IP
    @Test func missedEgressIsUnknown() {
        let o = GuardMonitor.merge(local: ("utun1024", true), egress: nil)
        #expect(o.egressIPs.isEmpty)
        #expect(verdict(o) == .unknown)
    }
}

/// 网络快照接进一轮：和其他探针并发，共用截止时间
@Suite struct RoundNetworkPath {
    private let clock = ContinuousClock()

    @Test func snapshotReachesTheRound() async {
        let r = await GuardMonitor.observe(deadline: clock.now + .seconds(2), clock: clock, probes: probes(path: StubPath(path: down)))
        #expect(r.path == down)
        #expect(r.observation.clashRunning == true)
    }

    /// 快照卡住时按截止时间返回，不拖垮路由和 Clash 的结果；原因只能是 probeFailed
    @Test func stuckSnapshotIsCutByDeadline() async {
        let begin = clock.now
        let r = await GuardMonitor.observe(deadline: begin + .milliseconds(200), clock: clock,
                                           probes: probes(path: StubPath(path: down, hang: true)))
        #expect(clock.now - begin < .seconds(2))
        #expect(r.path == nil)
        #expect(r.observation.clashRunning == true)
        #expect(UnknownReason.decide(verdict: .unknown, path: r.path) == .probeFailed)
    }
}

/// 每轮的编排：判定接上一轮（粘性），每轮都发，取消后停
@Suite struct MonitorLoop {
    private func monitor(_ rounds: [GuardMonitor.Probes]) -> GuardMonitor {
        let index = Counter()
        var m = GuardMonitor(probes: rounds[0], allowlist: { [allowed] })
        m.interval = .milliseconds(10)
        m.probes = GuardMonitor.Probes(route: { await rounds[min(index.next(), rounds.count - 1)].route() },
                                       clash: { true }, path: StubPath(path: up), egress: egress([allowed]))
        return m
    }

    @Test func publishesEveryRoundAndKeepsStickiness() async {
        // 路由：走隧道 → 不走隧道（违规）→ 读不到（unknown，违规粘住）→ 走隧道（解除）
        let routes: [String?] = ["utun1024", "en0", nil, "utun1024"]
        let m = monitor(routes.map { r in probes(route: r) })
        var seen: [GuardDisplay] = []
        for await d in m.displays() {
            seen.append(d)
            if seen.count == routes.count { break } // 停止迭代即取消
        }
        #expect(seen.map(\.verdict) == [.healthy, .violated, .violated, .healthy])
        #expect(seen[1].violatedSince != nil && seen[2].violatedSince == seen[1].violatedSince)
        #expect(seen.allSatisfy { $0.checkedAt != nil && $0.egressIP == allowed.description })
    }

    /// 每轮开始时重新取允许列表：列表空着时判不了出口
    @Test func emptyAllowlistIsUnknown() async {
        var m = GuardMonitor(probes: probes(), allowlist: { [] })
        m.interval = .milliseconds(10)
        var first: GuardDisplay?
        for await d in m.displays() { first = d; break }
        #expect(first?.verdict == .unknown && first?.unknownReason == .probeFailed)
    }
}

/// 一轮还在跑时订阅方停了：什么都没发，探针被取消、流马上结束，不等截止时间
@Suite struct MonitorCancellation {
    @Test func cancellingMidRoundEndsAtOnce() async {
        let slowRoute = GuardMonitor.Probes(route: { try? await Task.sleep(for: .seconds(30)); return "utun1024" },
                                            clash: { true }, path: StubPath(path: up), egress: egress([allowed]))
        let stream = GuardMonitor(probes: slowRoute, allowlist: { [allowed] }).displays()
        let clock = ContinuousClock()
        let begin = clock.now
        let consumer = Task { await stream.reduce(0) { n, _ in n + 1 } }
        try? await Task.sleep(for: .milliseconds(100))
        consumer.cancel()
        #expect(await consumer.value == 0)
        #expect(clock.now - begin < .seconds(3))
    }
}

/// 第几轮：路由探针每轮调一次
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        defer { value += 1 }
        return value
    }
}
