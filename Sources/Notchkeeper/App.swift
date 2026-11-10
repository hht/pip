import AppKit
import AgentCore
import Combine
import NotchCore
import PluginCore

@main
@MainActor
enum NotchkeeperMain {
    static func main() {
        // Prior to creating NSApplication: second instance exits without drawing anything.
        guard SingleInstance.claim() else { exit(0) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState.shared
    var settings: SettingsWindowController!
    var notch: NotchController!
    private var cancellables = Set<AnyCancellable>()
    private var sigterm: DispatchSourceSignal?
    private var inbox: InboxWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.global(qos: .utility).async { LegacyGuardd.remove() }
        ClaudeMod.refreshIfInstalled()
        CommandLineTool.install()
        TerminalPlugin.refreshIfInstalled()
        notch = NotchController()
        settings = SettingsWindowController(state: state, notch: notch)
        notch.onOpenSettings = { [weak self] pane in self?.settings.show(pane) }
        notch.contextMenu = buildMenu()
        NSApp.mainMenu = buildMainMenu()

        state.onAlertAction = { [weak self] in self?.notch.alertAction($0) }
        notch.onAlertDismissed = { [weak self] in self?.state.dismissViolation() }
        state.onAgentEvents = { [weak self] in self?.notch.agentEvents($0, sessions: $1) }
        state.onPluginsRemoved = { [weak self] ids in self?.notch.discard { $0.externalPluginID.map(ids.contains) ?? false } }

        #if DEBUG
        listenForDemo()
        #endif

        // Configuration updates (including config.json hot reload) take effect immediately.
        ConfigStore.shared.$config
            .receive(on: RunLoop.main)
            .sink { [weak self] c in
                self?.notch.setHoverEnabled(c.hoverExpand)
                MascotDirector.shared.setFollowsMouse(c.mascotFollowsMouse)
                self?.pluginsChanged(c)
            }
            .store(in: &cancellables)

        MascotDirector.shared.onPausedChange = { [weak self] in self?.notch.setScreenAway($0) }
        MascotDirector.shared.start(notchRect: { [weak self] in self?.notch.anchorRect ?? .zero })
        // Guard plugin disabled: suppress alerts prior to initial status read, preventing startup flashes.
        if !ConfigStore.shared.config.isEnabled(PluginID.exitGuard) { state.setGuardEnabled(false) }
        state.start()
        state.reloadManifests()
        // External plugin cards and activities (docs/ui.md "Card"): queued behind active red cards, managed by `CardQueue` via `externalPluginID`.
        let inbox = InboxWatcher { batch in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Evaluated on main queue per current config: reading on inbox queue causes races with toggling off.
                let c = ConfigStore.shared.config
                var on = batch
                on.cards.removeAll { !self.isEnabled($0.card) }
                on.activities.removeAll { !c.isEnabled($0.plugin) }
                let dropped = batch.cards.count + batch.activities.count - on.cards.count - on.activities.count
                if dropped > 0 { Log.write("Plugin: received \(dropped) messages from disabled plugin, discarded") }
                for a in on.cards {
                    Log.write("Plugin \(a.card.externalPluginID ?? ""): received card") // ID format validated, safe to log
                    self.postExternal(a)
                }
                for change in self.state.applyInbox(on) { self.notch.activityCard(change) }
            }
        }
        inbox.start()
        self.inbox = inbox
        watchSIGTERM()
        Log.write("Notchkeeper launched")
        Log.write("notch screen: \(notch.hasNotch)")
    }

    /// Log exit reason prior to termination, then cancel guard subscription to halt watchers and timers.
    /// @see https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationwillterminate(_:)
    func applicationWillTerminate(_ notification: Notification) {
        Log.write("Notchkeeper exiting (\(Self.quitReason ?? "unknown reason: terminate called"))")
        state.stopWatchingGuard()
    }

    /// Exit reason: internal termination (menu, settings pane, SIGTERM) records reason before terminate;
    /// system logout/shutdown or external quit events are detected in `applicationShouldTerminate`.
    /// Crashes and SIGKILL bypass terminate and cannot be logged.
    private static var quitReason: String?

    /// Internal terminations route through here so logs identify initiator.
    /// @see https://developer.apple.com/documentation/appkit/nsapplication/terminate(_:)
    static func quit(reason: String) {
        if quitReason == nil { quitReason = reason }
        NSApp.terminate(nil)
    }

    /// Called after terminate but before actual exit; inspects Apple Event to identify external quit requests.
    /// @see https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:)
    /// @see https://developer.apple.com/documentation/foundation/nsappleeventmanager/currentappleevent
    /// @see https://developer.apple.com/documentation/foundation/nsappleeventdescriptor/eventid
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.quitReason == nil, let e = NSAppleEventManager.shared().currentAppleEvent,
           e.eventClass == AEEventClass(kCoreEventClass), e.eventID == AEEventID(kAEQuitApplication) {
            Self.quitReason = "received quit Apple Event: logout, shutdown, or another app requested quit"
        }
        return .terminateNow
    }

    /// SIGTERM from kill / launchctl terminates immediately without applicationWillTerminate by default.
    /// Ignore default signal action and catch via dispatch source on main queue: log then terminate cleanly.
    /// @see https://developer.apple.com/library/archive/documentation/General/Conceptual/ConcurrencyProgrammingGuide/GCDWorkQueues/GCDWorkQueues.html
    /// @see https://developer.apple.com/documentation/dispatch/dispatchsource/makesignalsource(signal:queue:)
    /// @see https://developer.apple.com/documentation/dispatch/dispatchobject/activate()
    private func watchSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                Log.write("Received SIGTERM, exiting normally")
                Self.quit(reason: "SIGTERM")
            }
        }
        source.activate()
        sigterm = source
    }

    /// Re-opened while running (Launchpad, Finder double-click, `open -a`, Dock icon click while settings open): opens settings window directly.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    /// Notch context menu.
    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item(String(localized: "Settings…"), #selector(openSettings)))
        m.addItem(item(String(localized: "Copy Egress IP"), #selector(copyEgressIP)))
        m.addItem(.separator())
        m.addItem(item(String(localized: "Quit Pip"), #selector(quit)))
        return m
    }

    /// Main menu shown when settings window is open; enables Command+, / Command+Q / Command+W and standard text editing shortcuts.
    func buildMainMenu() -> NSMenu {
        let app = NSMenu()
        app.addItem(item(String(localized: "Settings…"), #selector(openSettings), ","))
        app.addItem(.separator())
        app.addItem(item(String(localized: "Quit Pip"), #selector(quit), "q"))

        // Target nil routes down responder chain to key window / text field.
        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let main = NSMenu()
        for sub in [app, edit, window] {
            let root = NSMenuItem(title: sub.title, action: nil, keyEquivalent: "")
            root.submenu = sub
            main.addItem(root)
        }
        return main
    }

    private func item(_ title: String, _ sel: Selector, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    /// Previous plugin enablement snapshot: acts only on changes.
    private var enabledPlugins: [String: Bool] = [:]

    /// Toggle plugin (docs/ui.md "Panel Layout"): toggles notifications, not evaluation. Egress Guard dismisses red card, Claude Code dismisses session cards, external plugins dismiss cards, rows, and drop future messages.
    private func pluginsChanged(_ c: Config) {
        let ids = [PluginID.exitGuard, PluginID.claudeCode] + state.manifests.keys
        let now = Dictionary(uniqueKeysWithValues: ids.map { ($0, c.isEnabled($0)) })
        defer { enabledPlugins = now }
        guard !enabledPlugins.isEmpty else { return } // Snapshot on launch: guard state set prior to initial check
        for (id, on) in now where enabledPlugins[id, default: true] != on {
            switch id {
            case PluginID.exitGuard:
                state.setGuardEnabled(on)
                // Red card dismissed by setGuardEnabled; recovered card dismissed here
                if !on { notch.discard { $0.key == .recovered } }
            case PluginID.claudeCode:
                if !on { notch.discard { if case .session = $0.key { true } else { false } } }
                Log.write("Claude Code plugin: \(on ? "enabled" : "disabled")")
            default:
                if !on {
                    state.removeActivities(of: id)
                    notch.discard { $0.externalPluginID == id }
                }
                Log.write("Plugin \(id): \(on ? "enabled" : "disabled")")
            }
        }
    }

    /// Target terminal already focused right in front of user (shell cards): suppress alert.
    private func postExternal(_ a: InboxGate.Admitted) {
        guard case .terminal(let terminal) = a.card.action, case .tty = terminal.identity else {
            notch.post(a.card, key: a.key, staleAt: a.staleAt)
            return
        }
        Ghostty.isFocused(terminal) { focused in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if focused {
                    Log.write("Plugin: already focused on target terminal, card suppressed")
                } else if self.isEnabled(a.card) { // Plugin may have been disabled while awaiting Ghostty reply
                    self.notch.post(a.card, key: a.key, staleAt: a.staleAt)
                }
            }
        }
    }

    private func isEnabled(_ card: Card) -> Bool {
        card.externalPluginID.map(ConfigStore.shared.config.isEnabled) ?? true
    }

    @objc func openSettings() { settings.show() }
    /// Copies full egress IP (same value shown in notch and settings).
    @objc func copyEgressIP() {
        guard let ip = state.display.egressIP else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
    }
    @objc func quit() { Self.quit(reason: "quit clicked in menu") }
}

/// "Copy Egress IP" is dimmed when no egress IP is available.
/// @see https://developer.apple.com/documentation/appkit/nsmenuitemvalidation/validatemenuitem(_:)
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(copyEgressIP) ? state.display.egressIP != nil : true
    }
}
