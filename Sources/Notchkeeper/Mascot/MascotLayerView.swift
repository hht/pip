import AppKit
import QuartzCore
import MascotCore

/// Pip 和右耳共用的两件事：此刻看不看得见；把 MascotCore 的 `Track` 提交成 Core Animation 动画。
/// 不知道画的是什么（子类搭图层树、给出 `Part` 对应哪一层）。
///
/// 看得见 = 外面说在画（`playing`）、在窗口里、窗口没收起也没被完全挡住、没熄屏也没锁屏（docs/mascot.md §5「渲染」）。
/// 窗口收起后 SwiftUI 不会移除里面的视图，所以要自己看窗口的遮挡状态。看不见时撤掉全部动画，
/// 静止值都在模型层上，回来时重新挂循环就行。
/// @see https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.property
@MainActor
class MascotLayerView: NSView {
    private(set) var active = false
    /// 外面说它此刻画不画出来：SwiftUI 把它设成透明时窗口的遮挡状态看不出来，要外面告诉
    var playing = true {
        didSet { if playing != oldValue { refreshActive() } }
    }
    private var serial = 0
    /// 挂着的循环：哪一层、键、编排、起播的媒体时间。撤的时候按编排算出循环自己叠了多少
    private var loops: [(layer: CALayer, key: String, track: Track, begin: CFTimeInterval)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("只用代码创建") }

    /// 和画布坐标一致：原点左上、+y 向下。AppKit 会把翻转视图的 layer 设成 geometryFlipped，子层跟着翻转。
    /// 实测：rotation.y 正 = 脸朝右，rotation.x 正 = 抬头，rotation.z 正 = 顺时针
    /// @see https://developer.apple.com/documentation/quartzcore/calayer/isgeometryflipped
    override var isFlipped: Bool { true }
    /// 点击交给外面的 SwiftUI
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
    }

    /// @see https://developer.apple.com/documentation/appkit/nswindow/didchangeocclusionstatenotification
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            MascotDirector.shared.attach(self)
        } else {
            MascotDirector.shared.detach(self)
        }
        refreshActive()
    }

    @objc private func occlusionChanged() { refreshActive() }

    /// 形状、渐变按屏幕倍率栅格化，换到别的屏幕时跟着换
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        func walk(_ l: CALayer) {
            l.contentsScale = scale
            l.sublayers?.forEach(walk)
            l.mask.map(walk)
        }
        layer?.sublayers?.forEach(walk)
    }

    func refreshActive() {
        let on = playing && window?.occlusionState.contains(.visible) == true && !MascotDirector.shared.paused
        guard on != active else { return }
        active = on
        if !on {
            quietly { layer?.sublayers?.forEach(Self.removeAnimations) }
            loops = []
        }
        activeChanged(on)
        MascotDirector.shared.activityChanged()
    }

    /// 子类：变得看得见时挂上循环，看不见时这里之前所有动画已经撤掉
    func activeChanged(_ on: Bool) {}

    /// 子类：Track 作用在哪一层
    func layer(for part: Part) -> CALayer? { nil }

    /// 1 画布单位多少 pt：位移的值要换算
    var unit: CGFloat { 1 }

    /// 马上播一组一次性的 Track
    func play(_ tracks: [Track]) {
        let now = CACurrentMediaTime()
        for t in tracks { add(t, begin: now, loop: false) }
    }

    /// 挂上循环，delay 秒后从各自的相位起播。起播前就停在循环自己的第一帧上：
    /// 有些装饰循环的第一帧不是静止值（第一个 Z 先藏着、Wi-Fi 先暗），等到起播那一刻再跳过去会闪一下
    func startLoops(_ tracks: [Track], delay: Double = 0) {
        let begin = CACurrentMediaTime() + delay
        for t in tracks { add(t, begin: begin, loop: true) }
    }

    /// 撤掉循环。ease：不一下子跳回静止值，循环此刻叠着的那一份用 0.25s 正弦补间回去（摆锤、找信号的头停在半路时）
    func stopLoops(ease: Bool) {
        let now = CACurrentMediaTime()
        var offsets: [ObjectIdentifier: (layer: CALayer, values: [Property: Double])] = [:]
        for l in loops {
            l.layer.removeAnimation(forKey: l.key)
            guard ease else { continue }
            // 还没起播的循环停在第一帧上，也要从那里收尾
            offsets[ObjectIdentifier(l.layer), default: (l.layer, [:])].values[l.track.property, default: 0] += l.track.value(at: max(0, now - l.begin))
        }
        loops = []
        for (layer, values) in offsets.values {
            for (p, v) in values where abs(v) > 1e-6 {
                let a = CABasicAnimation(keyPath: Self.keyPath(p))
                a.fromValue = ca(v, p)
                a.toValue = 0
                a.isAdditive = true
                a.duration = 0.25
                a.timingFunction = Self.function(.sineInOut)
                serial += 1
                layer.add(a, forKey: "settle.\(serial)")
            }
        }
    }

    private func add(_ t: Track, begin: CFTimeInterval, loop: Bool) {
        guard let target = layer(for: t.part) else { preconditionFailure("没有这一层：\(t.part)") }
        let values = t.values.map { ca($0, t.property) }
        let a: CAPropertyAnimation
        if case .spring(let response, let damping) = t.timings.first {
            let s = Self.spring(response: response, damping: damping)
            s.fromValue = values[0]
            s.toValue = values[1]
            a = s
        } else {
            let k = CAKeyframeAnimation()
            k.values = values
            k.keyTimes = t.keyTimes.map { NSNumber(value: $0) }
            k.timingFunctions = t.timings.map(Self.function)
            k.duration = t.duration
            a = k
        }
        a.keyPath = Self.keyPath(t.property)
        a.isAdditive = true
        a.beginTime = target.convertTime(begin, from: nil)
        if t.repeats {
            a.repeatCount = .infinity
            a.timeOffset = t.phase
            a.fillMode = .backwards
        }
        serial += 1
        let key = "\(loop ? "loop" : "once").\(serial)"
        target.add(a, forKey: key)
        if loop { loops.append((target, key, t, begin)) }
    }

    /// 改模型层不带隐式动画：独立的 CALayer 改属性默认会自己动 0.25s
    /// @see https://developer.apple.com/documentation/quartzcore/catransaction/setdisableactions(_:)
    func quietly(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// 静止值，单位同 Track（位移是画布单位）。transform 的子键路径走 Core Animation 的 KVC 扩展：
    /// 读的是分解出来的分量，写的时候重组整个 transform。只用来读写 yaw、pitch 层的单轴旋转和 body 的缩放，分解才唯一
    /// @see https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/Key-ValueCodingExtensions/Key-ValueCodingExtensions.html
    func model(_ l: CALayer, _ p: Property) -> Double { Self.value(l, p) / ca(1, p) }

    func setModel(_ l: CALayer, _ p: Property, _ v: Double) {
        l.setValue(ca(v, p), forKeyPath: Self.keyPath(p))
    }

    private func ca(_ v: Double, _ p: Property) -> Double {
        p == .translationX || p == .translationY ? v * unit : v
    }

    private static func value(_ l: CALayer, _ p: Property) -> Double {
        (l.value(forKeyPath: keyPath(p)) as? NSNumber)?.doubleValue ?? 0
    }

    static func keyPath(_ p: Property) -> String {
        switch p {
        case .translationX: return "transform.translation.x"
        case .translationY: return "transform.translation.y"
        case .scaleX: return "transform.scale.x"
        case .scaleY: return "transform.scale.y"
        case .scale: return "transform.scale"
        case .rotationX: return "transform.rotation.x"
        case .rotationY: return "transform.rotation.y"
        case .rotationZ: return "transform.rotation.z"
        case .opacity: return "opacity"
        }
    }

    /// 弹簧：response 是感知时长，damping 是阻尼比（docs/mascot.md §5「缓动」）
    /// @see https://developer.apple.com/documentation/quartzcore/caspringanimation
    static func spring(response: Double, damping: Double, keyPath: String? = nil) -> CASpringAnimation {
        let s = CASpringAnimation(keyPath: keyPath)
        s.mass = 1
        s.stiffness = pow(2 * .pi / response, 2)
        s.damping = 4 * .pi * damping / response
        s.duration = s.settlingDuration
        return s
    }

    static func function(_ t: Timing) -> CAMediaTimingFunction {
        guard case .bezier(let a, let b, let c, let d) = t else { preconditionFailure("关键帧里不能有弹簧：\(t)") }
        return CAMediaTimingFunction(controlPoints: Float(a), Float(b), Float(c), Float(d))
    }

    private static func removeAnimations(_ l: CALayer) {
        l.removeAllAnimations()
        l.sublayers?.forEach(removeAnimations)
    }
}
