import Foundation
import GuardCore
import MascotCore

/// Answers: How the UI should draw and whether a red card is needed, given the guard's latest round and any user-dismissed violation.
/// Pure function, agnostic of copy and colors (App looks up via `status` and `tone`), rules in docs/egress-guard.md "Visual Rendering".
public struct GuardPresentation: Equatable, Sendable {
    /// Status message shown in UI (docs/egress-guard.md "Visual Rendering")
    public enum Status: Equatable, Sendable {
        /// App just launched, initial round still checking
        case checking
        case healthy
        case mismatch
        case offline
        /// Probe failed: look unchanged, gray ring on right ear when collapsed
        case probeFailed
        case violated
    }

    /// Status dot: healthy green, mismatch solid amber, unknown gray hollow ring, violated red
    public enum Tone: Equatable, Sendable { case healthy, mismatch, unknown, violated }

    public let status: Status
    /// Whether a red card is requested (does not imply dismissal: dismissal checks healthy only). Active only when violated and user has not dismissed this instance
    public let wantsAlert: Bool

    /// - dismissedViolationSince: nil = never dismissed; .some(x) = user dismissed violation with violatedSince == x
    public init(_ d: GuardDisplay, dismissedViolationSince: Date??) {
        wantsAlert = d.verdict == .violated && dismissedViolationSince != .some(d.violatedSince)
        switch d.verdict {
        case .healthy: status = .healthy
        case .egressMismatch: status = .mismatch
        case .violated: status = .violated
        case .unknown:
            switch d.unknownReason {
            case .offline: status = .offline
            case .probeFailed: status = .probeFailed
            case nil: status = .checking
            }
        }
    }

    public var tone: Tone {
        switch status {
        case .healthy: return .healthy
        case .mismatch: return .mismatch
        case .checking, .offline, .probeFailed: return .unknown
        case .violated: return .violated
        }
    }

    /// Mascot look for guard state; defaults to idle when guard is nominal (docs/mascot.md §2)
    public var look: Look {
        switch status {
        case .checking, .healthy, .probeFailed: return .idle
        case .mismatch: return .mismatch
        case .offline: return .offline
        case .violated: return .danger
        }
    }
}
