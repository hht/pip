import AgentCore
import AppKit
import MascotCore
// Import specific symbols: GuardCore defines `Observation` (observation of a guard round) which shadows the Observation framework used by @Observable.
import struct GuardCore.GuardDisplay
import struct GuardCore.IPv4
import GuardProbes
import NotchCore
import Observation
import PluginCore

/// Views subscribe property-wise (Observation): only views that read `display` (expanded panel, settings pane) recalculate every round,
/// while the retracted notch observes only genuinely changing properties like `presentation`.
/// @see https://developer.apple.com/documentation/observation
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    let store = ConfigStore.shared

    /// Most recent round results from Egress Guard (`GuardMonitor`).
    private(set) var display = GuardDisplay.checking
    /// Computed from display and user dismiss state (`ViolationAlert`); UI observes this only.
    private(set) var presentation: GuardPresentation
    /// Sessions listed in panel (live terminal claude sessions evaluated by AgentCore).
    private(set) var sessions: [Session] = []
    /// Aggregated Claude Code session state (evaluated by AgentCore); nil if none to draw.
    private(set) var agentActivity: AgentActivity?
    /// Registered external plugins (`plugins/<id>/manifest.json`).
    private(set) var manifests: [String: Manifest] = [:]
    /// Active activities from external plugins.
    private(set) var activities = ActivityBoard()
    @ObservationIgnored private var activityExpiry: DispatchWorkItem?

    @ObservationIgnored private var violationAlert: ViolationAlert

    /// Invoked after each guard check round regardless of changes; parameter indicates alert action.
    @ObservationIgnored var onAlertAction: ((ViolationAlert.Action) -> Void)?
    /// Events evaluated by AgentCore, along with concurrent session list snapshot.
    @ObservationIgnored var onAgentEvents: (([AgentEvent], [Session]) -> Void)?
    /// External plugin uninstalled (settings pane, `pipctl plugin uninstall`, manual deletion): App removes queued cards.
    @ObservationIgnored var onPluginsRemoved: ((Set<String>) -> Void)?
    /// Long-running task subscribing to guard round results; cancelled via `stopWatchingGuard()` / deinit.
    @ObservationIgnored private var guardTask: Task<Void, Never>?
    @ObservationIgnored private var agentWatcher: AgentWatcher?

    init() {
        violationAlert = ViolationAlert(.checking)
        presentation = violationAlert.presentation
    }

    func start() {
        // Run checks only while App is running (docs/egress-guard.md "When to Check"); allowlist read each round from in-memory config.
        let store = store
        watchGuard(GuardMonitor(probes: .live(), allowlist: { await store.allowlistIPs }).displays())
        let watcher = AgentWatcher { update in
            DispatchQueue.main.async { AppState.shared.applyAgent(update) }
        }
        watcher.start()
        agentWatcher = watcher
    }

    /// Applies each display update. Accepts stream for testing; subsequent calls cancel previous subscription.
    func watchGuard(_ displays: AsyncStream<GuardDisplay>) {
        guardTask?.cancel()
        guardTask = Task { [weak self] in
            for await d in displays { self?.apply(d) }
        }
    }

    func stopWatchingGuard() {
        guardTask?.cancel()
        guardTask = nil
    }

    deinit { guardTask?.cancel() }

    func apply(_ d: GuardDisplay) {
        if d != display { display = d }
        let action = violationAlert.read(d, autoAlert: store.config.autoAlert)
        publishPresentation()
        onAlertAction?(action)
    }

    private func publishPresentation() {
        let old = presentation, new = violationAlert.presentation
        guard new != old else { return }
        presentation = new
        // Never log IP addresses
        if new.title != old.title { Log.write("Egress Guard: \(new.title)") }
    }

    private func applyAgent(_ update: AgentWatcher.Update) {
        if update.activity != agentActivity { agentActivity = update.activity }
        if update.sessions != sessions { sessions = update.sessions }
        for event in update.events {
            switch event {
            case .turnDone(let pid): Log.write("agent: turn completed (pid \(pid))")
            case .turnFailed(let pid): Log.write("agent: turn error (pid \(pid))")
            case .needsYou(let need, let pid): Log.write("agent: intervention needed, \(need) (pid \(pid))")
            case .needsYouEnded(let pid): Log.write("agent: intervention ended (pid \(pid))")
            }
        }
        // Disabled Claude Code plugin: evaluate normally, suppress popping cards.
        if !update.events.isEmpty, store.config.isEnabled(PluginID.claudeCode) { onAgentEvents?(update.events, update.sessions) }
    }

    // MARK: Plugins

    /// Panel section plugins ordered per user settings: Claude Code and registered external plugins. Egress Guard is pinned at top, omitted here.
    var sectionPlugins: [String] {
        store.config.ordered([PluginID.claudeCode] + manifests.keys.sorted())
    }

    /// Status of each enabled plugin: guard first, remaining per section order (higher priority breaks ties).
    var statuses: [PluginStatus] {
        let c = store.config
        var all: [PluginStatus] = c.isEnabled(PluginID.exitGuard) ? [PluginStatus(guard: presentation)] : []
        for id in sectionPlugins where c.isEnabled(id) {
            all.append(id == PluginID.claudeCode ? PluginStatus(agent: agentActivity) : PluginStatus(external: id, urgency: activities.urgency(for: id)))
        }
        return all
    }

    /// Determines who is rendered by Pip and right ear when retracted (docs/ui.md "Panel Layout"); nil: Pip idle, right ear empty.
    var lead: PluginStatus? { PluginStatus.lead(statuses, resident: store.config.resident) }
    /// Look rendered by Pip (docs/mascot.md §2 "Priorities" mapped to plugin urgency). Dizziness and sleepiness overlaid via `MascotDirector.shown`.
    var look: Look { lead?.look ?? .idle }

    /// Active sections in panel and their rows (empty sections retained, rendering determined by panel).
    var sections: [PanelSection] {
        let c = store.config
        return sectionPlugins.filter(c.isEnabled).map { id in
            PanelSection(plugin: id, rows: id == PluginID.claudeCode ? sessions.map(PanelRow.init) : activities.rows(for: id), maxRows: c.maxRows(id))
        }
    }

    /// Plugin display name in settings: external plugins use manifest name, falling back to id if unreadable.
    func pluginName(_ id: String) -> String {
        switch id {
        case PluginID.exitGuard: return String(localized: "Egress Guard")
        case PluginID.claudeCode: return "Claude Code"
        default: return manifests[id]?.name ?? id
        }
    }

    /// Reload plugin manifests: launch, terminal plugin install/uninstall, settings pane open.
    func reloadManifests() {
        setManifests(InboxWatcher.manifests())
    }

    /// Removed plugins (directory gone): dismiss rows, instruct App to dismiss cards.
    /// Directories temporarily unreadable during edit do not count, preserving existing cards.
    private func setManifests(_ m: [String: Manifest]) {
        guard m != manifests else { return }
        let removed = Set(manifests.keys).subtracting(m.keys)
            .filter { !FileManager.default.fileExists(atPath: PluginPaths.plugins.appendingPathComponent($0).path) }
        manifests = m
        guard !removed.isEmpty else { return }
        for id in removed { activities.remove(plugin: id) }
        scheduleActivityExpiry()
        onPluginsRemoved?(removed)
    }

    /// Batch received from inbox: records manifests, registers activities in panel, returns cards to post or refresh.
    func applyInbox(_ batch: InboxWatcher.Batch) -> [ActivityBoard.CardChange] {
        setManifests(batch.plugins)
        guard !batch.activities.isEmpty else { return [] }
        let now = Date()
        let changes = batch.activities.compactMap { activities.apply($0, now: now) }
        scheduleActivityExpiry()
        return changes
    }

    /// Disable external plugin in settings: removes associated rows.
    func removeActivities(of plugin: String) {
        activities.remove(plugin: plugin)
        scheduleActivityExpiry()
    }

    /// Single timer for activity expiration (up to 8h interval), removing expired rows.
    private func scheduleActivityExpiry() {
        activityExpiry?.cancel()
        guard let at = activities.deadline else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.activities.expire(now: Date())
            self.scheduleActivityExpiry()
        }
        activityExpiry = work
        // Wall clock: includes sleep time, expiring stale items immediately on wake.
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, at.timeIntervalSinceNow), execute: work)
    }

    /// Toggle Egress Guard plugin (disables alerts, not evaluation): dismissing removes red card; enabling re-evaluates latest round.
    func setGuardEnabled(_ on: Bool) {
        onAlertAction?(violationAlert.setEnabled(on, autoAlert: store.config.autoAlert))
        Log.write("Egress Guard plugin: \(on ? "enabled" : "disabled")")
    }

    /// User dismissed red card (or non-resident card timed out).
    func dismissViolation() {
        violationAlert.dismiss()
        publishPresentation()
    }

    #if DEBUG
    /// scripts/demo.sh alert
    func demoAlert() { onAlertAction?(violationAlert.demo()) }
    #endif

    /// Allowlist validated using GuardCore IPv4, matching guard evaluation rules (`ConfigStore.allowlistIPs`).
    @discardableResult
    func addAllowed(_ raw: String) -> Bool {
        let ip = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPv4(ip) != nil, !store.config.allowlist.contains(ip) else { return false }
        store.config.allowlist.append(ip)
        Log.write("Allowlist: added 1 entry")
        return true
    }

    func removeAllowed(_ ip: String) {
        store.config.allowlist.removeAll { $0 == ip }
        Log.write("Allowlist: removed 1 entry")
    }
}

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Notchkeeper/notchkeeper.log")
    /// Local time + timezone offset, e.g. 2026-10-28 14:03:21 -07:00
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss xxxxx"
        return f
    }()

    /// Main thread and `AgentWatcher` queue both log: serialized execution avoids race conditions on `formatter`.
    private static let queue = DispatchQueue(label: "com.notchkeeper.log")

    static func write(_ msg: String) {
        queue.sync {
            // Includes pid to distinguish instances when multiple processes run concurrently
            let line = "\(formatter.string(from: Date())) [pid \(getpid())] \(msg)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }
}
