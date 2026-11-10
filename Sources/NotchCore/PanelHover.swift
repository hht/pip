import Foundation

/// Answers: Whether mouse hover has expanded the panel — how long to hover before expanding, how long after leaving before collapsing.
/// Pure state machine: fed hover target hit states and current time; agnostic of screen coordinates, runs no timers (App calls `tick` on `deadline`).
/// Card precedence over panel and pinned states handled outside
public struct PanelHover: Sendable {
    /// Hover this long before expanding: avoids popping open while cursor passes by
    public static let openDelay: TimeInterval = 0.12
    /// Wait this long after leaving before collapsing: prevents jitter when briefly crossing boundary
    public static let closeDelay: TimeInterval = 0.35

    private enum Phase: Equatable {
        case closed, opening(at: Date), open, closing(at: Date)
    }

    private var phase = Phase.closed

    public init() {}

    public var isOpen: Bool {
        switch phase {
        case .open, .closing: true
        case .closed, .opening: false
        }
    }

    /// Next deadline for `tick`; nil if idle
    public var deadline: Date? {
        switch phase {
        case .opening(let at), .closing(let at): at
        case .closed, .open: nil
        }
    }

    /// onNotch: Over collapsed shape (slightly enlarged hit area); nearShape: Over expanded shape (+10pt margin);
    /// canOpen: Hover expand enabled and not pinned. Panels expanded via click still collapse on leave, ignoring canOpen
    public mutating func mouseMoved(onNotch: Bool, nearShape: Bool, canOpen: Bool, now: Date) {
        switch phase {
        case .open, .closing:
            if onNotch || nearShape {
                phase = .open
            } else if phase == .open {
                phase = .closing(at: now + Self.closeDelay)
            }
        case .closed, .opening:
            if !(canOpen && onNotch) {
                phase = .closed
            } else if phase == .closed {
                phase = .opening(at: now + Self.openDelay)
            }
        }
    }

    /// Clicked notch
    public mutating func open() { phase = .open }

    /// Open settings, change pin mode, disable hover expand: collapse immediately, cancel pending expand
    public mutating func close() { phase = .closed }

    public mutating func tick(now: Date) {
        switch phase {
        case .opening(let at) where at <= now: phase = .open
        case .closing(let at) where at <= now: phase = .closed
        default: break
        }
    }
}
