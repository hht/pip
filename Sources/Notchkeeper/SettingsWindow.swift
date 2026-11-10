import AppKit
import SwiftUI

/// Settings Window: standard NSWindow (full size content), fixed width 715, adjustable height. Appearance follows system (docs/ui.md "Light and Dark").
/// Title bar draws background normally: when transparent, scrolling content passes underneath the page title creating overlapping text;
/// when opaque, top fade and blur rely on system scroll edge effects (standard in macOS 14+), matching System Settings; toolbar must also contain buttons (see SettingsView sidebar).
/// @see https://developer.apple.com/documentation/swiftui/view/scrolledgeeffectstyle(_:for:)
/// Centered on first open, remembers frame afterwards; closing window does not quit App.
/// While open, App behaves as regular App (Dock icon, Command-Tab, menu bar); after closing, returns to accessory:
/// accessory Apps don't appear in Dock or Command-Tab, so if settings window was covered there would be no way to switch back.
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
            window.setFrame(frame, display: false)  // Changing content controller resizes window to content size; preserves position and size
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Dismounts SwiftUI view upon closing; hidden window incurs zero refresh overhead; selected pane and drafts preserved in model
    func windowWillClose(_ notification: Notification) {
        window.contentViewController = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func hostingController() -> NSViewController {
        let host = NSHostingController(rootView: SettingsView(model: model, state: state, store: ConfigStore.shared, notch: notch))
        // Delegate navigationTitle and toolbar to window display, matching System Settings
        // @see https://developer.apple.com/documentation/swiftui/nshostingcontroller/scenebridgingoptions
        host.sceneBridgingOptions = [.title, .toolbars]
        return host
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: true)
        w.toolbar = NSToolbar()  // Toolbar needed for page title to align left in detail pane like System Settings
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
