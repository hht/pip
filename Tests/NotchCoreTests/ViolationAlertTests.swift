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

/// Sequential check rounds starting from launch, returns actions for each step
private func run(_ reads: [GuardDisplay], autoAlert: Bool = true, on alert: inout ViolationAlert) -> [ViolationAlert.Action] {
    reads.map { alert.read($0, autoAlert: autoAlert) }
}
private func run(_ reads: [GuardDisplay], autoAlert: Bool = true) -> [ViolationAlert.Action] {
    var alert = ViolationAlert(checking)
    return run(reads, autoAlert: autoAlert, on: &alert)
}

/// docs/egress-guard.md, docs/ui.md "Cards": when red card is raised/cleared, whether recovery card pops on recovery
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
        // New violation instance raises again even without passing through healthy
        #expect(a.read(laterViolation, autoAlert: true) == .raise)
    }

    @Test func healthyAfterDismissRecoversAndForgets() {
        var a = ViolationAlert(checking)
        _ = a.read(violated, autoAlert: true)
        a.dismiss()
        #expect(a.read(healthy, autoAlert: true) == .clear(recovered: true))
        // Healthy clears dismissal record: same violatedSince raises again
        #expect(a.read(violated, autoAlert: true) == .raise)
    }

    /// Recorded only while violation persists: dismissal without violation (demo red card) does not count
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

/// Former --selftest invariant: "Any sequence ending in healthy leaves no active red card"
@Suite struct ViolationAlertEndings {
    @Test(arguments: [
        [violated, healthy], [violated, offline, healthy], [violated, probeFailed, healthy], [violated, offline, probeFailed, healthy],
        [mismatch, violated, mismatch, healthy],
    ])
    func endsCleared(_ reads: [GuardDisplay]) {
        #expect(run(reads).last == .clear(recovered: true))
    }

    /// Disabling "Pop red card on egress anomaly" while red card active: leaves it alone, clears on healthy and pops recovery card as usual
    @Test func autoAlertTurnedOffWhileShown() {
        var a = ViolationAlert(checking)
        _ = a.read(violated, autoAlert: true)
        #expect(a.read(offline, autoAlert: false) == .none)
        #expect(a.read(healthy, autoAlert: false) == .clear(recovered: true))
    }
}

/// Disabling egress guard plugin (Settings): disables alerts, not checks. Red card dismissed without recovery card; re-enabling evaluates with latest round (docs/egress-guard.md)
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
        // Evaluation continues: Settings view still displays actual state
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

    /// User dismissal preserved across disable/enable: dismissed before disable, re-enabling does not re-raise same violation
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
