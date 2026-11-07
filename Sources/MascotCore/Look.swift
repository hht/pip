import CoreGraphics

/// Pip 此刻是哪个造型、这个造型长什么样（颜色、头的朝向、睁不睁眼、装饰算哪一类、右耳）。
/// 不知道造型从哪来（守卫、agent、鼠标），那是 App 的事；眼形见 `Eyes`，装饰见 `decoration(_:)`，怎么动见 `Choreography`。
/// 数据全部出自 docs/mascot.md §2。
public enum Look: String, CaseIterable, Sendable {
    case idle, sleeping, thinking, working, longTurn, question, approval, finished, error, interrupted, dizzy
    case offline, mismatch, stale, danger, shielded

    /// 身体的竖直渐变，上 → 下
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

    /// 停在这个造型时头的朝向
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

    /// 睁着眼：会眨眼、看鼠标、探头。闭眼、笑眼、> <、螺旋本身就是表情
    public var opensEyes: Bool {
        switch self {
        case .idle, .thinking, .working, .longTurn, .question, .approval, .offline, .mismatch, .stale, .shielded: return true
        case .sleeping, .finished, .error, .interrupted, .dizzy, .danger: return false
        }
    }

    /// 装饰是告示（sign）：收起时挪到右耳当图标，左耳只留脸。其余有装饰的是心情装饰（mood），留在 Pip 身上
    public var isSign: Bool {
        switch self {
        case .error, .offline, .mismatch, .stale, .danger, .shielded: return true
        default: return false
        }
    }
}

/// 头的朝向，弧度。yaw + = 脸朝右，pitch + = 抬头，roll + = 顺时针（docs/mascot.md §1）
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

    /// 眼睛、▲ 里的 !、气泡里的 ?、锁孔
    public static let ink = RGB(0x16171A)
    /// 守卫的琥珀、红、灰（状态点、卡片、右耳灰环）
    public static let amber = RGB(0xFFB020)
    public static let red = RGB(0xFF453A)
    public static let grey = RGB(0x8E8E93)
    /// agent 状态的颜色：右耳和面板会话行的指示共用（docs/mascot.md §2「右耳指示」、docs/ui.md「面板布局」）
    public static let working = RGB(0x3B9EFF)
    public static let question = RGB(0x3CC8DC)
    public static let approval = RGB(0xB5E04A)
}

/// 收起时右耳显示什么（docs/mascot.md §2「右耳指示」）。右耳只有一个位置：sign 盖过灰环，灰环盖过点
public enum EarIndicator: Equatable, Sendable {
    case none
    /// 三蓝点 `#3B9EFF`，直径 3pt，依次亮
    case dots
    /// 一个 7pt 的点
    case dot(RGB)
    /// 灰色空心环，7pt、1pt 描边：探针没结果
    case ring
    /// 造型的装饰原样挂出来：sign 造型挂到右耳；面板会话行挂等你回答、等你批准的装饰（docs/ui.md「面板布局」）
    case decoration(Look)

    /// probeFailed：守卫 unknown、原因是探针没结果。这种 unknown 不改造型，只在右耳表达
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
