import Foundation
import Testing
import GuardCore
@testable import NotchCore

private let healthy = display(.healthy)
private let mismatch = display(.egressMismatch)
private let offline = display(.unknown, unknown: .offline)
private let probeFailed = display(.unknown, unknown: .probeFailed)
private let checking = GuardDisplay.checking
private let violated = display(.violated)
private let laterViolation = display(.violated, since: violatedAt + 60)

/// 从刚启动开始，依次查完每一轮，返回每一步的动作
private func run(_ reads: [GuardDisplay], autoAlert: Bool = true, on alert: inout ViolationAlert) -> [ViolationAlert.Action] {
    reads.map { alert.read($0, autoAlert: autoAlert) }
}
private func run(_ reads: [GuardDisplay], autoAlert: Bool = true) -> [ViolationAlert.Action] {
    var alert = ViolationAlert(checking)
    return run(reads, autoAlert: autoAlert, on: &alert)
}

/// docs/egress-guard.md、docs/ui.md「卡片」：红卡什么时候挂上、撤掉，恢复了弹不弹恢复卡
@Suite struct ViolationAlertTests {
    @Test func violationRaisesOnceUntilHealthy() {
        #expect(run([violated, offline, violated, probeFailed, violated, healthy])
                == [.raise, .none, .none, .none, .none, .clear(recovered: true)])
    }

    @Test func recoveredOnlyOnce() {
        #expect(run([violated, healthy, healthy, offline, healthy]) == [.raise, .clear(recovered: true), .none, .none, .none])
    }

    @Test func healthyWithoutAlertDoesNothing() {
        #expect(run([mismatch, healthy]) == [.none, .none])
        #expect(run([offline, healthy]) == [.none, .none])
        #expect(run([probeFailed, healthy]) == [.none, .none])
    }

    @Test func dismissedViolationStaysQuiet() {
        var a = ViolationAlert(checking)
        #expect(a.read(violated, autoAlert: true) == .raise)
        a.dismiss()
        #expect(a.presentation.tone == .violated && !a.presentation.wantsAlert)
        #expect(run([violated, offline], on: &a) == [.none, .none])
        #expect(a.presentation.tone == .unknown)
        // 新的一次违规不经过 healthy 也再弹
        #expect(a.read(laterViolation, autoAlert: true) == .raise)
    }

    @Test func healthyAfterDismissRecoversAndForgets() {
        var a = ViolationAlert(checking)
        _ = a.read(violated, autoAlert: true)
        a.dismiss()
        #expect(a.read(healthy, autoAlert: true) == .clear(recovered: true))
        // healthy 清掉关掉的记录：同一个 violatedSince 也再弹
        #expect(a.read(violated, autoAlert: true) == .raise)
    }

    /// 只在违规还挂着时记：没有违规时关掉（演示红卡）不算
    @Test func dismissWithoutViolationIsNotRemembered() {
        var a = ViolationAlert(checking)
        a.dismiss()
        #expect(a.read(violated, autoAlert: true) == .raise)
    }

    @Test func autoAlertOffNeverRaisesNorRecovers() {
        #expect(run([violated, healthy], autoAlert: false) == [.none, .none])
    }

    #if DEBUG
    @Test func demoAlertClearsOnHealthyWithoutRecovered() {
        var a = ViolationAlert(checking)
        #expect(a.demo() == .raise)
        #expect(a.read(healthy, autoAlert: true) == .clear(recovered: false))
        #expect(a.read(healthy, autoAlert: true) == .none)
    }

    @Test func demoAlertThenRealViolationRecovers() {
        var a = ViolationAlert(checking)
        _ = a.demo()
        #expect(run([violated, healthy], on: &a) == [.none, .clear(recovered: true)])
    }
    #endif
}

/// 旧 --selftest 的「任何以 healthy 结尾的序列都没有红卡」
@Suite struct ViolationAlertEndings {
    @Test(arguments: [
        [violated, healthy], [violated, offline, healthy], [violated, probeFailed, healthy], [violated, offline, probeFailed, healthy],
        [mismatch, violated, mismatch, healthy],
    ])
    func endsCleared(_ reads: [GuardDisplay]) {
        #expect(run(reads).last == .clear(recovered: true))
    }

    /// 红卡挂着时关掉「出口异常时弹出红卡」：不再动它，回到 healthy 照样撤、照样弹恢复卡
    @Test func autoAlertTurnedOffWhileShown() {
        var a = ViolationAlert(checking)
        _ = a.read(violated, autoAlert: true)
        #expect(a.read(offline, autoAlert: false) == .none)
        #expect(a.read(healthy, autoAlert: false) == .clear(recovered: true))
    }
}

/// 关掉出口守卫插件（设置）：关的是提醒，不是判定。红卡撤掉、不弹恢复卡；再打开按最近一轮再判一次（docs/egress-guard.md）
@Suite struct DisabledGuard {
    @Test func disablingClearsAlertWithoutRecoveredCard() {
        var alert = ViolationAlert(checking)
        _ = alert.read(violated, autoAlert: true)
        #expect(alert.setEnabled(false, autoAlert: true) == .clear(recovered: false))
        #expect(alert.read(healthy, autoAlert: true) == .none)
    }

    @Test func disabledReadsNeverAlert() {
        var alert = ViolationAlert(checking)
        #expect(alert.setEnabled(false, autoAlert: true) == .none)
        #expect(run([violated, offline, healthy], on: &alert) == [.none, .none, .none])
        // 判定照旧：设置页还看得到真实状态
        _ = alert.read(violated, autoAlert: true)
        #expect(alert.presentation.status == .violated)
    }

    @Test func enablingDuringViolationRaisesAgain() {
        var alert = ViolationAlert(checking)
        _ = alert.read(violated, autoAlert: true)
        _ = alert.setEnabled(false, autoAlert: true)
        #expect(alert.setEnabled(true, autoAlert: true) == .raise)
        #expect(alert.read(healthy, autoAlert: true) == .clear(recovered: true))
    }

    @Test func enablingWhileHealthyDoesNothing() {
        var alert = ViolationAlert(checking)
        _ = alert.setEnabled(false, autoAlert: true)
        _ = alert.read(healthy, autoAlert: true)
        #expect(alert.setEnabled(true, autoAlert: true) == .none)
    }

    /// 关掉期间用户关红卡的记录不该留着：关之前点过 ×，再打开同一次违规也不再挂（这一次已经关掉了）
    @Test func dismissedViolationStaysDismissed() {
        var alert = ViolationAlert(checking)
        _ = alert.read(violated, autoAlert: true)
        alert.dismiss()
        _ = alert.setEnabled(false, autoAlert: true)
        #expect(alert.setEnabled(true, autoAlert: true) == .none)
    }

    @Test func settingSameValueDoesNothing() {
        var alert = ViolationAlert(checking)
        _ = alert.read(violated, autoAlert: true)
        #expect(alert.setEnabled(true, autoAlert: true) == .none)
    }
}
