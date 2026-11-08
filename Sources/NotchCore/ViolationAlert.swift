import Foundation
import GuardCore

/// Answers: Whether to raise, clear, or keep red card after a guard check round, and whether to show recovery card when cleared.
/// Tracks "which violation instance user dismissed" and "whether this violation raised a red card" here (docs/egress-guard.md, docs/ui.md "Cards").
/// Pure state machine: display scheduling on notch handled by `CardQueue`, card visual styling handled by App.
public struct ViolationAlert: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// New violation: insert red card at front, play Basso
        case raise
        /// Healthy detected: clear red card; present recovery card if recovered
        case clear(recovered: Bool)
    }

    private var display: GuardDisplay
    /// nil = never dismissed; .some(x) = user dismissed violation with violatedSince == x. In-memory only: reappears after restart to err on caution
    private var dismissedViolationSince: Date??
    /// Red card currently active
    private var shown = false
    /// Red card was raised for this violation: recovery card only pops when returning to healthy. Intermittent offline, probe failure, or manual dismissal still count as same instance
    private var alerted = false
    /// Egress guard plugin enabled in settings: when disabled, check still runs, but red and recovery cards suppressed
    private var enabled = true

    public init(_ d: GuardDisplay) { display = d }

    public var presentation: GuardPresentation { GuardPresentation(display, dismissedViolationSince: dismissedViolationSince) }

    /// Called each time guard finishes a check round. autoAlert: "Pop red card on egress anomaly" setting
    public mutating func read(_ d: GuardDisplay, autoAlert: Bool) -> Action {
        display = d
        if d.verdict == .healthy { dismissedViolationSince = nil }
        guard enabled else { return .none }
        if presentation.status == .healthy {
            defer { shown = false; alerted = false }
            return shown || alerted ? .clear(recovered: alerted) : .none
        }
        guard presentation.wantsAlert, autoAlert else { return .none }
        alerted = true
        guard !shown else { return .none }
        shown = true
        return .raise
    }

    /// Toggle egress guard plugin. Disabled: dismiss red card without recovery card; enabled: re-evaluate with latest round
    public mutating func setEnabled(_ on: Bool, autoAlert: Bool) -> Action {
        guard on != enabled else { return .none }
        enabled = on
        if on { return read(display, autoAlert: autoAlert) }
        defer { shown = false; alerted = false }
        return shown ? .clear(recovered: false) : .none
    }

    /// Red card dismissed while violation persists (user clicked x, or non-persistent red card timed out). Recorded only when violation remains active, demo red card dismissed does not count
    public mutating func dismiss() {
        shown = false
        guard presentation.status == .violated else { return }
        dismissedViolationSince = .some(display.violatedSince)
    }

    #if DEBUG
    /// scripts/demo.sh alert: post a red card, cleared on next healthy without recovery card. Only DEBUG builds respond to demo.sh
    public mutating func demo() -> Action {
        shown = true
        return .raise
    }
    #endif
}
