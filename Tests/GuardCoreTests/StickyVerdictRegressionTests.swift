import Foundation
import Testing
@testable import GuardCore

/// 红卡撤不掉的回归（断网→恢复后红卡一直在）。这里钉守卫判定一侧：
/// - 只有路由不走 utun 才 violated；断网、探针失败、出口不符都不会产生 violated。
/// - violated 粘住，只有一轮 healthy 才解除；经过 unknown / egressMismatch 不解除，也不卡死。
/// App 侧（任何路径进入 healthy 都撤卡）由 Notchkeeper 的测试覆盖，见 Vera 的回归清单 1–12。
/// 已有的单步用例不重复：`Verdicts.violationIsStickyUntilHealthy`、`fullHealthyRoundClearsViolation`、
/// `UnknownReasonDecision.*`。

private let allowed = IPv4("198.51.100.8")!
private let leaked = IPv4("198.51.100.66")!
private let allowlist: Set<IPv4> = [allowed]
private let up = NetworkPath(physicalInterfaceSatisfied: true, hasDefaultRoute: true)
private let down = NetworkPath(physicalInterfaceSatisfied: false, hasDefaultRoute: false)
private let start = Date(timeIntervalSince1970: 1_800_000_000)

/// 一轮：观测 + 这一轮的网络快照
private struct Step {
    var observation: Observation
    var path: NetworkPath?
}

private let healthy = Step(observation: Observation(clashRunning: true, routeInterface: "utun4", egressIPs: [allowed]), path: up)
/// 关代理 / TUN 掉了：公网路由走物理网卡
private let routeOff = Step(observation: Observation(clashRunning: true, routeInterface: "en0", egressIPs: [allowed]), path: up)
/// 断网，TUN 还在：路由仍走 utun，出口探针全失败
private let offlineOnTunnel = Step(observation: Observation(clashRunning: true, routeInterface: "utun4", egressIPs: []), path: down)
/// 断网，连路由都读不到
private let offlineNoRoute = Step(observation: Observation(clashRunning: true, routeInterface: nil, egressIPs: []), path: down)
/// 网通着但探针没结果
private let probesFail = Step(observation: Observation(clashRunning: true, routeInterface: "utun4", egressIPs: []), path: up)
private let mismatch = Step(observation: Observation(clashRunning: true, routeInterface: "utun4", egressIPs: [leaked]), path: up)

/// 按 `GuardMonitor` 每轮的做法走一遍 GuardCore：判定 → 这一轮的结果。每轮间隔 5 秒
private func run(_ steps: [Step]) -> [GuardDisplay] {
    var g = EgressGuard()
    return steps.enumerated().map { i, s in
        let checkedAt = start.addingTimeInterval(Double(i) * 5)
        let v = g.observe(s.observation, allowlist: allowlist, at: checkedAt)
        return GuardDisplay(verdict: v, observation: s.observation, allowlist: allowlist, networkPath: s.path,
                            violatedSince: g.violatedSince, checkedAt: checkedAt)
    }
}

private func verdicts(_ d: [GuardDisplay]) -> [Verdict] { d.map(\.verdict) }

@Suite struct StickyVerdictRegression {
    /// 1. 断网一下又恢复：全程没有 violated，最后 healthy
    @Test func outageBetweenHealthyRoundsNeverViolates() {
        let d = run([healthy, offlineOnTunnel, healthy])
        #expect(verdicts(d) == [.healthy, .unknown, .healthy])
        #expect(d[1].unknownReason == .offline)
    }

    /// 2. 违规后经过 unknown（断网 / 探针失败 / 读不到路由）不解除，一轮 healthy 才解除，且不卡死
    @Test func violatedStaysThroughUnknownUntilHealthy() {
        let d = run([routeOff, offlineOnTunnel, probesFail, offlineNoRoute, healthy])
        #expect(verdicts(d) == [.violated, .violated, .violated, .violated, .healthy])
        // 粘住的 violated 不带 unknown 原因（显示红卡，不是灰环文字）
        #expect(d.dropLast().allSatisfy { $0.unknownReason == nil })
        #expect(d.last?.unknownReason == nil)
    }

    /// 3. 违规后出口不符不解除（不降成琥珀），healthy 才解除
    @Test func violatedStaysThroughMismatchUntilHealthy() {
        #expect(verdicts(run([routeOff, mismatch, mismatch, healthy])) == [.violated, .violated, .violated, .healthy])
    }

    /// 3b. 解除后再出口不符就只是琥珀，不会回到 violated
    @Test func afterReleaseMismatchIsAmberNotViolated() {
        #expect(verdicts(run([routeOff, healthy, mismatch, healthy])) == [.violated, .healthy, .egressMismatch, .healthy])
    }

    /// 4. 路由一直走 utun 的断网→恢复（两种断法、来回几轮）：永不 violated；原因 offline，网回来探针还没结果时 probeFailed，healthy 时没有原因
    @Test func outageAndRecoveryOnTunnelNeverViolates() {
        let d = run([healthy, offlineOnTunnel, offlineNoRoute, offlineOnTunnel, probesFail, healthy])
        #expect(!d.contains { $0.verdict == .violated })
        #expect(verdicts(d) == [.healthy, .unknown, .unknown, .unknown, .unknown, .healthy])
        #expect(d.map(\.unknownReason) == [nil, .offline, .offline, .offline, .probeFailed, nil])
    }

    /// 4b. 一开机就断网（没有过 healthy）然后恢复
    @Test func startingOfflineThenRecoveringNeverViolates() {
        let d = run([offlineNoRoute, offlineOnTunnel, healthy])
        #expect(verdicts(d) == [.unknown, .unknown, .healthy])
        #expect(d.map(\.unknownReason) == [.offline, .offline, nil])
    }

    /// 5. healthy 连续多轮：一直 healthy，不产生任何变化
    @Test func healthyIsIdempotent() {
        let d = run([healthy, healthy, healthy])
        #expect(verdicts(d) == [.healthy, .healthy, .healthy])
        #expect(d.allSatisfy { $0.unknownReason == nil })
    }
}
