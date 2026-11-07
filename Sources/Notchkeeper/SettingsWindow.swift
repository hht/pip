import AppKit
import SwiftUI

/// 设置窗口：普通 NSWindow（内容铺满），宽度固定 715，高度可调。外观跟随系统（docs/ui.md「亮色与暗色」）。
/// 标题栏照常画背景：设成透明时，往下滚的内容从页面标题底下穿过去、字叠在一起；
/// 不透明时顶部的渐隐和模糊交给系统的滚动边缘效果（macOS 26 起滚动视图默认就有），和系统设置一样；工具栏里还得有按钮（见 SettingsView 的侧栏）
/// @see https://developer.apple.com/documentation/swiftui/view/scrolledgeeffectstyle(_:for:)
/// 第一次打开居中，之后记住位置；关掉窗口不退出 App。
/// 开着时 App 是普通 App（Dock 图标、⌘Tab、菜单栏），关掉后回到只有刘海的 accessory：accessory App 不在 Dock 和 ⌘Tab 里，
/// 设置窗口一被别的 App 盖住就没处切回来；有窗口的时候就该像普通 App 一样能切。
/// @see https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 715, height: 560)
    private static let autosaveName = "NotchkeeperSettings"

    private let model = SettingsModel()
    private let state: AppState
    private let notch: NotchController
    private lazy var window: NSWindow = makeWindow()

    init(state: AppState, notch: NotchController) {
        self.state = state
        self.notch = notch
    }

    func show(_ pane: SettingsPane? = nil) {
        if let pane { model.pane = pane }
        if window.contentViewController == nil {
            let frame = window.frame
            window.contentViewController = hostingController()
            window.setFrame(frame, display: false)  // 换内容控制器会按内容尺寸改窗口大小，保持原位置和大小
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// 关掉后卸载 SwiftUI 视图，隐藏的窗口不留任何刷新；选中页和输入框草稿在 model 里，重新打开不丢
    func windowWillClose(_ notification: Notification) {
        window.contentViewController = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func hostingController() -> NSViewController {
        let host = NSHostingController(rootView: SettingsView(model: model, state: state, store: ConfigStore.shared, notch: notch))
        // 让 navigationTitle 和工具栏交给窗口显示，与系统设置一致
        // @see https://developer.apple.com/documentation/swiftui/nshostingcontroller/scenebridgingoptions
        host.sceneBridgingOptions = [.title, .toolbars]
        return host
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: true)
        w.toolbar = NSToolbar()  // 有工具栏，页面标题才会像系统设置那样靠左显示在详情栏顶部
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: Self.size.width, height: 460)
        w.contentMaxSize = NSSize(width: Self.size.width, height: .greatestFiniteMagnitude)
        w.delegate = self
        // @see https://developer.apple.com/documentation/appkit/nswindow/setframeautosavename(_:)
        if !w.setFrameUsingName(Self.autosaveName) { w.center() }
        w.setFrameAutosaveName(Self.autosaveName)
        return w
    }
}
