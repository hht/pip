import AppKit
import FirewallCore
import SwiftUI

/// Settings > Firewall: Toggles, status, trial countdown, "Keep", installation, and uninstallation (`FirewallInstaller`). Status sourced from summary (`FirewallReading`),
/// polling every 2s while visible (halts when occluded, minimized, or screen locked); install, enable, keep, disable, and uninstall explain effects before prompting for administrator credentials, holding toggle disabled until daemon round settles.
/// Does not rely on config.json, remaining usable even if config file is unparseable.
struct FirewallPane: View {
    @State private var reading = FirewallInstaller.reading(now: Date()).reading
    /// Timestamp when enable, keep, or disable began (recorded only on command success): toggle remains pending until `FirewallReading.settled`.
    @State private var waitingSince: Date?
    @State private var visible = false
    @State private var tunnel = "utun1024"
    @State private var confirmInstall = false
    @State private var confirmEnable = false
    @State private var confirmUninstall = false
    @State private var working = false
    @State private var error: String?
    /// Post-action notification: script output is simplified into a single user-facing sentence.
    @State private var notice: String?

    private var installed: Bool { reading != .notInstalled }

    var body: some View {
        Form {
            if installed {
                Section {
                    Toggle(isOn: Binding(get: { reading.switchedOn }, set: { $0 ? (confirmEnable = true) : disable() })) {
                        Text("Firewall")
                        if waitingSince != nil {
                            Text("Waiting for the daemon to confirm…").foregroundStyle(.secondary)
                        } else {
                            FirewallStatusLine(reading: reading, live: visible)
                        }
                    }
                    .disabled(working || waitingSince != nil)
                    if case .trial = reading {
                        LabeledContent {
                            Button("Keep", action: keep).disabled(!reading.canKeep || working || waitingSince != nil)
                        } label: {
                            Text(reading.canKeep ? String(localized: "If your connection works, click Keep: it stays on, even after a restart")
                                                 : String(localized: "Can’t keep while there’s a problem: do nothing and it turns off when time’s up"))
                        }
                    }
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else if let notice {
                        Text(notice).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("While on, traffic that bypasses the Clash tunnel is blocked, except for the local network, addresses Clash connects to directly, and mainland China IPs. Each time you turn it on, it runs a 2-minute trial and turns itself off unless you click Keep. Turning on, keeping, and turning off all need an administrator password.")
                }
            }
            Section {
                LabeledContent {
                    HStack {
                        if working { ProgressView().controlSize(.small) }
                        if installed {
                            Button("Uninstall…") { confirmUninstall = true }
                        } else {
                            Button("Install…") { confirmInstall = true }
                        }
                    }
                    .disabled(working)
                } label: {
                    Text(installed ? "Uninstall" : "Install")
                    if !installed, let error {
                        Text(error).foregroundStyle(.red)
                    } else if !installed, let notice {
                        Text(notice)
                    } else {
                        Text(installed ? String(localized: "Removes the daemon, rules, and files and lifts any blocking immediately; use it if you lose your connection") : String(localized: "Not installed"))
                    }
                }
                if !installed {
                    TextField("Tunnel Interface", text: $tunnel, prompt: Text("utun1024"))
                        .disabled(working)
                }
            } footer: {
                if !installed {
                    Text("Installing needs an administrator password; the firewall starts off and blocks nothing. Enter Clash’s TUN interface name — utun followed by digits (Clash Verge defaults to utun1024): a wrong name blocks all internet traffic once the firewall is on.")
                }
            }
        }
        .confirmationDialog("Install the firewall?", isPresented: $confirmInstall) {
            Button("Install", action: install)
        } message: {
            Text("It’s off after installing and blocks nothing; turn it on when you need it. Requires an administrator password.")
        }
        .confirmationDialog("Turn on the firewall?", isPresented: $confirmEnable) {
            Button("Start Trial", action: enable)
        } message: {
            Text("Traffic that bypasses the Clash tunnel will be blocked, except for the local network, addresses Clash connects to directly, and mainland China IPs. It starts with a 2-minute trial: if you lose your connection, do nothing and it turns itself off; if all is well, click Keep. It reads the proxy nodes and China IP ranges from Clash Verge once when turned on; after changing subscriptions, turn it off and on again.")
        }
        .confirmationDialog("Uninstall the firewall?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive, action: uninstall)
        } message: {
            Text("Removes the daemon, rules, and files, and lifts any blocking immediately. Needs an administrator password.")
        }
        .background(WindowVisibility(visible: $visible))
        // Read only when visible (no scheduling when invisible): daemon updates every 10s, 2s polling is responsive enough.
        .task(id: visible) {
            while visible, !Task.isCancelled {
                refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func enable() {
        command("trial started") { try await FirewallInstaller.enable() }
    }

    private func keep() {
        command("kept") { try await FirewallInstaller.keep() }
    }

    private func disable() {
        command("turned off") { try await FirewallInstaller.disable() }
    }

    /// Enable, Keep, Disable: outcome reflected in toggle row.
    private func command(_ log: String, _ run: @escaping @MainActor () async throws -> FirewallInstaller.Outcome) {
        let started = Date()
        perform {
            guard try await run() == .done else { return }
            waitingSince = started
            Log.write("Firewall: \(log)")
        }
    }

    private func refresh() {
        let now = Date()
        let r = FirewallInstaller.reading(now: now)
        reading = r.reading
        if let since = waitingSince, FirewallReading.settled(checkedAt: r.checkedAt, commandStarted: since, now: now) {
            waitingSince = nil
        }
    }

    private func install() {
        let tunnel = tunnel.trimmingCharacters(in: .whitespaces)
        perform {
            let staged = try FirewallInstaller.stage()
            defer { FirewallInstaller.discard(staged) }
            guard try await FirewallInstaller.install(staged, tunnel: tunnel) == .done else { return }
            Log.write("Firewall: installed")
            notice = String(localized: "Installed. It’s off and blocks nothing")
        }
    }

    private func uninstall() {
        perform {
            let staged = try FirewallInstaller.stage()
            defer { FirewallInstaller.discard(staged) }
            guard try await FirewallInstaller.uninstall(staged) == .done else { return }
            Log.write("Firewall: uninstalled")
            notice = String(localized: "Uninstalled. Rules and files are removed")
        }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        working = true
        error = nil
        notice = nil
        Task {
            do {
                try await work()
            } catch {
                self.error = String(localized: "Failed: \(error.localizedDescription)")
                Log.write("Firewall: operation failed")
            }
            refresh()
            working = false
        }
    }
}

/// Row beneath toggle: trial countdown (updates every second in this row only).
private struct FirewallStatusLine: View {
    let reading: FirewallReading
    /// Stops countdown when invisible.
    let live: Bool

    var body: some View {
        switch reading {
        case .trial(let endsAt?, let problem):
            // Retain countdown even when problem occurs: crucial context for "do nothing, will turn off automatically".
            if live {
                TimelineView(.periodic(from: .now, by: 1)) { context in Self.countdown(endsAt, at: context.date) }
            } else {
                Self.countdown(endsAt, at: Date())
            }
            if let problem { Text(Self.text(problem)).foregroundStyle(.red) }
        default:
            Text(Self.caption(reading)).foregroundStyle(Self.isWarning(reading) ? Color.red : .secondary)
        }
    }

    private static func countdown(_ endsAt: Date, at now: Date) -> Text {
        let left = max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
        return Text(left > 0 ? String(localized: "In trial, \(left / 60):\(String(format: "%02d", left % 60)) left; turns off automatically")
                             : String(localized: "Trial ended, turning off"))
    }

    private static func caption(_ r: FirewallReading) -> String {
        switch r {
        case .notInstalled: return String(localized: "Not installed")
        case .off(nil): return String(localized: "Off, blocking nothing")
        case .trial(_, nil): return String(localized: "In trial; turns off automatically when it ends")
        case .on(nil): return String(localized: "Protected")
        case .off(let p?), .trial(_, let p?), .on(let p?), .unknown(let p): return text(p)
        }
    }

    private static func isWarning(_ r: FirewallReading) -> Bool {
        switch r {
        case .notInstalled, .off(nil), .trial(_, nil), .on(nil): return false
        default: return true
        }
    }

    private static func text(_ p: FirewallReading.Problem) -> String {
        switch p {
        case .noSummary: return String(localized: "No status yet: just installed or halfway through uninstalling; wait a few seconds. If it stays like this, uninstall and reinstall")
        case .unreadable: return String(localized: "The status summary can’t be read")
        case .stale: return String(localized: "Problem: the daemon hasn’t updated its status for 30 seconds, so it’s unclear whether anything is blocked; turn it off or uninstall")
        case .stateUnreadable: return String(localized: "The firewall state file can’t be read, so it’s treated as off; to turn it on again, uninstall and reinstall")
        case .testRules: return String(localized: "Test rules are installed: only traffic to the test address is blocked, which isn’t protection")
        case .rulesNotLoaded: return String(localized: "The rules failed to load this round and will be retried; it may not be blocking right now")
        case .tunnelMissing: return String(localized: "Tunnel interface missing (Clash TUN is off, or the name is wrong): all internet traffic is blocked right now")
        case .checkFailed: return String(localized: "Problem: the check failed (pf stopped, rules replaced, or the tunnel interface is missing); it may not be blocking")
        case .failedSteps: return String(localized: "A pf step failed and will be retried next round; rules may still be loaded even while off")
        }
    }
}

/// Window visibility probe (occluded, minimized, or screen locked all count as invisible).
/// @see https://developer.apple.com/documentation/appkit/nswindow/didchangeocclusionstatenotification
private struct WindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> Probe { Probe { visible = $0 } }
    func updateNSView(_ view: Probe, context: Context) { view.onChange = { visible = $0 } }

    final class Probe: NSView {
        var onChange: (Bool) -> Void

        init(_ onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { preconditionFailure("code initialization only") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(report), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            }
            report()
        }

        @objc private func report() {
            let v = window?.occlusionState.contains(.visible) == true
            // Mutating SwiftUI state during view update throws warning: dispatch to next run loop.
            DispatchQueue.main.async { [onChange] in onChange(v) }
        }
    }
}
