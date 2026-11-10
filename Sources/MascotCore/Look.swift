import CoreGraphics

/// Which look Pip currently exhibits and look properties (colors, rest pose, eyes open/closed, decoration category, right ear).
/// Unaware of where look origins come from (guard, agent, mouse), which is App's concern; eye geometry in `Eyes`, decoration in `decoration(_:)`, motions in `Choreography`.
/// All data follows docs/mascot.md §2.
public enum Look: String, CaseIterable, Sendable {
    case idle, sleeping, thinking, working, longTurn, question, approval, finished, error, interrupted, dizzy
    case offline, mismatch, stale, danger, shielded

    /// Vertical body gradient, top -> bottom
    public var gradient: (top: RGB, bottom: RGB) {
        switch self {
        case .idle, .sleeping, .interrupted: return (RGB(0xF2EEE6), RGB(0xCFCAC0))
        case .thinking: return (RGB(0xE9E2FB), RGB(0xBFB2EE))
        case .working, .longTurn: return (RGB(0xDCEBFF), RGB(0x9CC6F5))
        case .question: return (RGB(0xD8F4F7), RGB(0x8FD9E2))
        case .approval: return (RGB(0xF0F7D4), RGB(0xC6DE7E))
        case .finished: return (RGB(0xE3F6EE), RGB(0xAEDCC7))
        case .error: return (RGB(0xFBE6D6), RGB(0xEDB892))
        case .dizzy: return (RGB(0xFBE3EC), RGB(0xEBB3C7))
        case .offline: return (RGB(0xE6E8EC), RGB(0xB4BAC4))
        case .mismatch: return (RGB(0xFBEFC9), RGB(0xE8CD84))
        case .stale: return (RGB(0xEFE9DD), RGB(0xCFC2A6))
        case .danger: return (RGB(0xFFB8B0), RGB(0xF2645A))
        case .shielded: return (RGB(0xFFC9C2), RGB(0xE8857B))
        }
    }

    /// Head rest pose when dwelling in this look
    public var pose: HeadPose {
        switch self {
        case .sleeping: return HeadPose(degrees: 0, -14, 0)
        case .thinking: return HeadPose(degrees: 10, 10, 4)
        case .working, .longTurn: return HeadPose(degrees: 0, -10, 0)
        case .question: return HeadPose(degrees: 0, 0, -10)
        case .approval: return HeadPose(degrees: 0, 8, 0)
        case .finished: return HeadPose(degrees: 0, 10, 0)
        case .error: return HeadPose(degrees: 0, -8, 0)
        case .stale: return HeadPose(degrees: 0, -6, 0)
        case .shielded: return HeadPose(degrees: 0, 4, 0)
        case .idle, .interrupted, .dizzy, .offline, .mismatch, .danger: return .level
        }
    }

    /// Eyes open: enables blinks, mouse tracking, peek. Closed eyes, smiling eyes, > <, and spirals represent fixed expressions
    public var opensEyes: Bool {
        switch self {
        case .idle, .thinking, .working, .longTurn, .question, .approval, .offline, .mismatch, .stale, .shielded: return true
        case .sleeping, .finished, .error, .interrupted, .dizzy, .danger: return false
        }
    }

    /// Decoration is a sign: moves to right ear as an icon when collapsed, leaving only face on left ear. Other decorations are mood decorations staying on Pip
    public var isSign: Bool {
        switch self {
        case .error, .offline, .mismatch, .stale, .danger, .shielded: return true
        default: return false
        }
    }
}

/// Head pose, radians. yaw + = face right, pitch + = tilt up, roll + = clockwise (docs/mascot.md §1)
public struct HeadPose: Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public static let level = HeadPose(degrees: 0, 0, 0)

    init(degrees yaw: Double, _ pitch: Double, _ roll: Double) {
        let d = Double.pi / 180
        self.yaw = yaw * d
        self.pitch = pitch * d
        self.roll = roll * d
    }
}

public struct RGB: Hashable, Sendable {
    public let hex: UInt32
    public init(_ hex: UInt32) { self.hex = hex }
    public var r: Double { Double((hex >> 16) & 0xFF) / 255 }
    public var g: Double { Double((hex >> 8) & 0xFF) / 255 }
    public var b: Double { Double(hex & 0xFF) / 255 }
    public var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    /// Eyes, ! inside triangle, ? inside bubble, keyhole
    public static let ink = RGB(0x16171A)
    /// Guard amber, red, grey (status dots, cards, right ear grey ring)
    public static let amber = RGB(0xFFB020)
    public static let red = RGB(0xFF453A)
    public static let grey = RGB(0x8E8E93)
    /// Agent state colors: shared between right ear and panel session rows (docs/mascot.md §2 "Right ear indicator", docs/ui.md "Panel layout")
    public static let working = RGB(0x3B9EFF)
    public static let question = RGB(0x3CC8DC)
    public static let approval = RGB(0xB5E04A)
}

/// What right ear displays when collapsed (docs/mascot.md §2 "Right ear indicator"). Right ear has one slot: sign overrides grey ring, grey ring overrides dots
public enum EarIndicator: Equatable, Sendable {
    case none
    /// Three blue dots `#3B9EFF`, 3pt diameter, lighting up sequentially
    case dots
    /// A single 7pt dot
    case dot(RGB)
    /// Grey hollow ring, 7pt with 1pt stroke: probe gave no result
    case ring
    /// Look's decoration displayed as-is: sign looks display on right ear; panel session rows display question/approval decorations (docs/ui.md "Panel layout")
    case decoration(Look)

    /// probeFailed: guard is unknown due to probe giving no result. This kind of unknown does not change look, expressed only on right ear
    public static func `for`(_ look: Look, probeFailed: Bool) -> EarIndicator {
        if look.isSign { return .decoration(look) }
        if probeFailed { return .ring }
        switch look {
        case .thinking, .working, .longTurn: return .dots
        case .question: return .dot(.question)
        case .approval: return .dot(.approval)
        default: return .none
        }
    }
}
