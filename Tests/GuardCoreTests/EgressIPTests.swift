import Foundation
import Testing
@testable import GuardCore

// 测试只用 TEST-NET-2（198.51.100.0/24，RFC 5737）地址
private let allowedA = IPv4("198.51.100.10")!
private let allowedB = IPv4("198.51.100.11")!
private let outsideX = IPv4("198.51.100.9")!
private let outsideY = IPv4("198.51.100.200")!
private let allowlist: Set<IPv4> = [allowedA, allowedB]
private let up = NetworkPath(physicalInterfaceSatisfied: true, hasDefaultRoute: true)
private let down = NetworkPath(physicalInterfaceSatisfied: false, hasDefaultRoute: false)
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func obs(iface: String? = "utun4", ips: [IPv4]) -> Observation {
    Observation(clashRunning: true, routeInterface: iface, egressIPs: ips)
}

private func state(_ o: Observation, guard g: inout EgressGuard, path: NetworkPath? = up, at t: Date = t0) -> GuardDisplay {
    let v = g.observe(o, allowlist: allowlist, at: t)
    return GuardDisplay(verdict: v, observation: o, allowlist: allowlist, networkPath: path, violatedSince: g.violatedSince, checkedAt: t)
}

private func state(_ o: Observation, path: NetworkPath? = up) -> GuardDisplay {
    var g = EgressGuard()
    return state(o, guard: &g, path: path)
}

/// 面板显示的出口 IP 和判定同源：这一轮观测到的出口 IP 放进 `GuardDisplay.egressIP`（完整地址，界面完整显示）
@Suite struct EgressIPInDisplay {
    @Test func healthyRoundWritesTheObservedIP() {
        let s = state(obs(ips: [allowedA, allowedA]))
        #expect(s.verdict == .healthy)
        #expect(s.egressIP == "198.51.100.10")
    }

    /// 出口不符时显示的是不在允许列表的那个，不是碰巧对上的那个
    @Test func mismatchPrefersTheIPOutsideTheAllowlist() {
        let s = state(obs(ips: [allowedA, outsideX, allowedB]))
        #expect(s.verdict == .egressMismatch)
        #expect(s.egressIP == "198.51.100.9")
    }

    /// 回显服务说法不一时：取出现次数最多的；一样多取数值最小的。和探针返回的先后顺序无关
    @Test func pickIsDeterministicRegardlessOfProbeOrder() {
        for ips in [[outsideY, outsideX, outsideY], [outsideX, outsideY, outsideY], [outsideY, outsideY, outsideX]] {
            #expect(obs(ips: ips).shownEgressIP(allowlist: allowlist) == outsideY)
        }
        for ips in [[outsideY, outsideX], [outsideX, outsideY]] {
            #expect(obs(ips: ips).shownEgressIP(allowlist: allowlist) == outsideX) // .9 < .200 按数值比，不按字符串
        }
        #expect(obs(ips: [allowedB, allowedA]).shownEgressIP(allowlist: allowlist) == allowedA)
    }

    /// 允许列表为空（配置问题）：verdict 是 unknown，但出口确实观测到了，照样写
    @Test func emptyAllowlistStillReportsTheObservedIP() {
        #expect(obs(ips: [outsideX]).shownEgressIP(allowlist: []) == outsideX)
    }

    /// 这一轮没观测到出口（断网、探针全失败或超时）就是 nil，界面显示「—」
    @Test(arguments: [up, down, nil] as [NetworkPath?])
    func noObservedEgressIsNil(_ path: NetworkPath?) {
        let s = state(obs(ips: []), path: path)
        #expect(s.verdict == .unknown)
        #expect(s.egressIP == nil)
    }

    /// 绝不沿用上一轮的 IP：上一轮拿到了，这一轮探针失败，就写 nil
    @Test func neverCarriesOverThePreviousRoundsIP() {
        var g = EgressGuard()
        #expect(state(obs(ips: [allowedA]), guard: &g).egressIP == "198.51.100.10")
        #expect(state(obs(ips: []), guard: &g, at: t0.addingTimeInterval(5)).egressIP == nil)
    }

    /// 粘住的 violated 期间，IP 照样是这一轮的观测（verdict 粘，IP 不粘）
    @Test func stickyViolatedReportsThisRoundsIP() {
        var g = EgressGuard()
        let first = state(obs(iface: "en0", ips: [outsideX]), guard: &g)
        #expect(first.verdict == .violated && first.egressIP == "198.51.100.9")
        let sticky = state(obs(ips: [allowedA, outsideY]), guard: &g, at: t0.addingTimeInterval(5))
        #expect(sticky.verdict == .violated && sticky.egressIP == "198.51.100.200")
        let blind = state(obs(ips: []), guard: &g, at: t0.addingTimeInterval(10))
        #expect(blind.verdict == .violated && blind.egressIP == nil)
    }
}
