import Foundation
import Testing
import GuardCore
import MascotCore
@testable import NotchCore

let violatedAt = Date(timeIntervalSince1970: 1_000)

/// 守卫一轮的结果；unknown 不给原因就是「第一轮还没查完」
func display(_ verdict: Verdict, unknown: UnknownReason? = nil, since: Date = violatedAt) -> GuardDisplay {
    GuardDisplay(verdict: verdict, checkedAt: verdict == .unknown && unknown == nil ? nil : violatedAt,
                 unknownReason: unknown, violatedSince: verdict == .violated ? since : nil)
}

/// docs/egress-guard.md「怎么画」、docs/mascot.md §2：守卫这一轮画成什么、要不要红卡
@Suite struct GuardPresentationTests {
    @Test(arguments: [
        (display(.healthy), GuardPresentation.Status.healthy, GuardPresentation.Tone.healthy, Look.idle),
        (display(.egressMismatch), .mismatch, .mismatch, .mismatch),
        (display(.unknown, unknown: .offline), .offline, .unknown, .offline),
        // 探针没结果不改造型，只让右耳显示灰环
        (display(.unknown, unknown: .probeFailed), .probeFailed, .unknown, .idle),
        // 刚启动、第一轮还没查完：灰环，不改造型
        (GuardDisplay.checking, .checking, .unknown, .idle),
        (display(.violated), .violated, .violated, .danger),
    ])
    func status(_ d: GuardDisplay, _ status: GuardPresentation.Status, _ tone: GuardPresentation.Tone, _ look: Look) {
        let p = GuardPresentation(d, dismissedViolationSince: nil)
        #expect(p.status == status && p.tone == tone && p.look == look)
    }

    @Test func alertOnlyWhileViolated() {
        #expect(GuardPresentation(display(.violated), dismissedViolationSince: nil).wantsAlert)
        for d in [display(.healthy), display(.egressMismatch), display(.unknown, unknown: .offline), .checking] {
            #expect(!GuardPresentation(d, dismissedViolationSince: nil).wantsAlert)
        }
    }

    /// 用户关掉的是哪一次：同一次不再要红卡，Pip 仍是危险、状态点仍是红的
    @Test func dismissedViolation() {
        let dv = GuardPresentation(display(.violated), dismissedViolationSince: .some(violatedAt))
        #expect(!dv.wantsAlert && dv.status == .violated && dv.tone == .violated && dv.look == .danger)
        // 新的一次违规照样要红卡
        let next = GuardPresentation(display(.violated, since: violatedAt + 60), dismissedViolationSince: .some(violatedAt))
        #expect(next.wantsAlert)
    }
}
