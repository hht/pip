/// Timestamp on monotonic clock: `CLOCK_MONOTONIC_RAW` (see firewalld `FirewallSystem`), starts from boot, runs across sleep, unaffected by clock adjustments, millisecond precision.
public struct MonotonicTime: Comparable, Hashable, Sendable {
    public var milliseconds: Int64
    public init(milliseconds: Int64) { self.milliseconds = milliseconds }
    public static func < (a: Self, b: Self) -> Bool { a.milliseconds < b.milliseconds }
}

/// Instant in time for a specific boot session
public struct Moment: Sendable {
    /// `kern.bootsessionuuid`, refreshed every boot; `nil` if unreadable
    public var bootSession: String?
    public var now: MonotonicTime
    public init(bootSession: String?, now: MonotonicTime) {
        self.bootSession = bootSession
        self.now = now
    }
}

public enum FirewallMode: Equatable, Sendable {
    case off
    case trial(deadline: MonotonicTime)
    case on
}

public struct FirewallState: Equatable, Sendable {
    public var mode: FirewallMode = .off
    /// Boot session for this state (`kern.bootsessionuuid`); `nil` if unknown
    public var bootSession: String?
    /// pf enabled reference acquired during current boot session; `nil` if unacquired
    public var reference: PFReference?
    /// Rules installed into anchor during current boot session; `nil` if uninstalled (or flushed)
    public var loadedRules: FirewallRules?
    /// Anchor Evaluations during previous round check; cleared on rule reload (counter resets to 0)
    public var lastEvaluations: UInt64?

    public init(bootSession: String?) { self.bootSession = bootSession }

    /// Duration before automatic rollback to off if Keep not clicked (docs/firewall.md §3)
    public static let trialMilliseconds: Int64 = 120_000

    /// Enable: transitions into trial
    public mutating func enable(at moment: Moment) throws(FirewallCommandError) {
        advance(to: moment, liveTokens: nil)
        guard moment.bootSession != nil else { throw .bootSessionUnknown }
        guard mode == .off else { throw .notOff }
        mode = .trial(deadline: MonotonicTime(milliseconds: moment.now.milliseconds + Self.trialMilliseconds))
        // Snapshot taken before enable: forces reinstall on next round even if rule text unchanged
        loadedRules = nil
    }

    /// Keep: promotes trial to on
    public mutating func keep(at moment: Moment) throws(FirewallCommandError) {
        advance(to: moment, liveTokens: nil)
        guard moment.bootSession != nil else { throw .bootSessionUnknown }
        guard case .trial = mode else { throw .notInTrial }
        mode = .on
    }

    /// Disable: unconditionally returns to off (disable is an emergency rescue path)
    public mutating func disable() { mode = .off }

    /// Advance time to `moment`: boot session changes treat trial as off; expired trials roll back to off.
    /// Executed first by rounds and commands, guaranteeing invariants without caller enforcement.
    /// `liveTokens` contains tokens from `pfctl -s References`; `nil` if unreadable
    private mutating func advance(to moment: Moment, liveTokens: Set<String>?) {
        switch moment.bootSession {
        case nil:
            // Boot session unreadable: fails safely by treating trial as off; retains reference and recorded session
            if case .trial = mode { mode = .off }
        case let session? where session != bootSession:
            bootSession = session
            if case .trial = mode { mode = .off }
            loadedRules = nil
            // On boot session change, retain reference only if observed in live list
            switch reference {
            case .held(let token) where liveTokens?.contains(token) == true: break
            default: reference = nil
            }
        default:
            break
        }
        if case .trial(let deadline) = mode, moment.now >= deadline { mode = .off }
    }
}

/// Command mismatched with state machine
public enum FirewallCommandError: Error, Equatable {
    case notOff
    case notInTrial
    /// `kern.bootsessionuuid` unreadable
    case bootSessionUnknown
}

/// pf enabled reference (docs/firewall.md §4 "Enabling pf")
public enum PFReference: Equatable, Sendable {
    /// Releasable via `pfctl -X <token>`
    case held(token: String)
    /// `pfctl -E` succeeded but token unparseable: acquired but unreleasable
    case unknownToken
}

/// Single pf action executed sequentially by daemon
public enum PFAction: Equatable, Sendable {
    /// `pfctl -a <anchor> -f -`
    case load(FirewallRules)
    /// `pfctl -E`, acquires enabled reference
    case enable
    /// `pfctl -a <anchor> -F rules`
    case flush
    /// `pfctl -X <token>`
    case release(token: String)

    public var step: PFStep {
        switch self {
        case .load: .load
        case .enable: .enable
        case .flush: .flush
        case .release: .release
        }
    }
}

/// Action name recorded in status summary for failed operations
public enum PFStep: String, Codable, Sendable {
    case load, enable, flush, release
}

/// Snapshot of pf at start of round
public struct PFSnapshot: Sendable {
    /// Anchor has no rules (`pfctl -a <anchor> -sr` produces no output)
    public var anchorEmpty: Bool
    /// Tokens from `pfctl -s References`; `nil` if unreadable
    public var tokens: Set<String>?

    public init(anchorEmpty: Bool, tokens: Set<String>?) {
        self.anchorEmpty = anchorEmpty
        self.tokens = tokens
    }
}

extension FirewallState {
    /// Actions to execute on pf this round, in order.
    /// Invariants: off never loads rules; identical rules on non-empty anchor skip reload; held references skip -E.
    public mutating func tick(at moment: Moment, pf: PFSnapshot, rules: FirewallRules) -> [PFAction] {
        advance(to: moment, liveTokens: pf.tokens)
        if pf.anchorEmpty { loadedRules = nil }
        if case .held(let token) = reference, let live = pf.tokens, !live.contains(token) { reference = nil }
        var actions: [PFAction] = []
        if mode == .off {
            if !pf.anchorEmpty { actions.append(.flush) }
            if case .held(let token) = reference, pf.tokens?.contains(token) == true { actions.append(.release(token: token)) }
        } else {
            if loadedRules != rules { actions.append(.load(rules)) }
            if reference == nil { actions.append(.enable) }
        }
        return actions
    }

    /// Verification for round (parameters in `FirewallCheck`), recording counters for subsequent rounds.
    public mutating func check(mainRules: String, anchorRules: String, info: String, interfaces: String, tunnel: String) -> FirewallCheck {
        let c = FirewallCheck(mainRules: mainRules, anchorRules: anchorRules, info: info, interfaces: interfaces, tunnel: tunnel,
                              previousEvaluations: lastEvaluations)
        lastEvaluations = c.evaluations
        if reference == .unknownToken, c.pfEnabled == false { reference = nil }
        return c
    }

    /// Records completed action; failed actions are omitted and retried next round.
    public mutating func record(_ done: PFAction, token: String? = nil) {
        switch done {
        case .load(let r): (loadedRules, lastEvaluations) = (r, nil)
        case .enable: reference = token.map(PFReference.held) ?? .unknownToken
        case .flush: loadedRules = nil
        case .release: reference = nil
        }
    }

    /// Cross-checks reference against immediate live list after -E.
    public mutating func confirmReference(liveTokens: Set<String>?) {
        if case .held(let token) = reference, let live = liveTokens, !live.contains(token) { reference = .unknownToken }
    }
}
