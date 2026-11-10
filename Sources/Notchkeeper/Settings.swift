import AppKit
import SwiftUI
import MascotCore
import NotchCore
import PluginCore

// Settings window: Follows macOS System Settings layout, using native controls only.
// Every toggle binds directly to ConfigStore, writing to disk immediately without view-side caching.

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, plugins, exitGuard, claudeCode, terminal, firewall, mascot, stateTest, about
    var id: Self { self }

    /// Sidebar grouping, separated by blank lines. Built-in plugins and bundled terminal plugin have dedicated pages; other external plugins are toggled in "Plugins" page.
    static let groups: [[SettingsPane]] = [[.general], [.plugins, .exitGuard, .claudeCode, .terminal], [.firewall], [.mascot], [.stateTest], [.about]]

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .plugins: return String(localized: "Plugins")
        case .exitGuard: return String(localized: "Egress Guard")
        case .claudeCode: return "Claude Code"
        case .terminal: return String(localized: "Terminal")
        case .firewall: return String(localized: "Firewall")
        case .mascot: return "Pip" // Matches App name
        case .stateTest: return String(localized: "State Test")
        case .about: return String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .plugins: return "puzzlepiece.extension.fill"
        case .exitGuard: return "shield.lefthalf.filled"
        case .claudeCode: return "sparkle"
        case .terminal: return "terminal.fill"
        case .firewall: return "lock.shield.fill"
        case .mascot: return "face.smiling.inverse"
        case .stateTest: return "testtube.2"
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: return .gray
        case .plugins: return .indigo
        case .exitGuard: return .green
        case .claudeCode: return .brown
        case .terminal: return .gray
        case .firewall: return .blue
        case .mascot: return .orange
        case .stateTest: return .purple
        case .about: return .gray
        }
    }
}

/// Holds selected pane and draft inputs across window close/reopen.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var pane: SettingsPane = .general
    @Published var allowDraft = ""
    @Published var schemeDraft = ""
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let state: AppState
    @ObservedObject var store: ConfigStore
    let notch: NotchController

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.pane }, set: { if let p = $0 { model.pane = p } })) {
                Button { model.pane = .exitGuard } label: { StatusCard(presentation: state.presentation) }
                    .buttonStyle(.plain)
                ForEach(SettingsPane.groups, id: \.self) { group in
                    Section {
                        ForEach(group) { p in
                            Label { Text(p.title) } icon: { SettingsIcon(symbol: p.symbol, color: p.color) }
                                .tag(p)
                        }
                    }
                }
            }
            // Retains sidebar toggle: toolbar needs a button to get System Settings-style smooth gradient blur.
            .navigationSplitViewColumnWidth(215)
        } detail: {
            detail
                .formStyle(.grouped)
                .navigationTitle(model.pane.title)
                .safeAreaInset(edge: .top) {
                    if store.fileUnreadable { ConfigUnreadableBanner(store: store) }
                }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.pane {
        case .general: GeneralPane(store: store)
        case .plugins: PluginsPane(model: model, state: state, store: store)
        case .exitGuard: ExitGuardPane(model: model, state: state, store: store)
        case .claudeCode: Form { PluginOffNote(store: store, plugin: PluginID.claudeCode); ClaudeModSection() }
        case .terminal: Form { TerminalPluginSection(state: state) }
        case .firewall: FirewallPane()
        case .mascot: MascotPane(store: store)
        case .stateTest: StateTestPane(overrides: notch.overrides, state: state, notch: notch)
        case .about: AboutPane(store: store)
        }
    }
}

/// When config.json cannot be parsed, edits cannot be saved (ConfigStore preserves original file); locks controls with banner.
private struct ConfigUnreadableBanner: View {
    let store: ConfigStore

    var body: some View {
        HStack(spacing: 8) {
            // Multicolor exclamation mark in yellow triangle
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            Text("The config file can't be read, so settings can't be changed for now. They come back once the file is fixed.")
            Spacer()
            Button("Open Config File") { store.openFile() }.controlSize(.small)
        }
        .font(.callout)
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

/// System settings-style icon: 20x20 corner radius 5 color block with white symbol.
struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(color.gradient)
            .frame(width: 20, height: 20)
            .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
    }
}

/// Status card at top of sidebar; clicking jumps to Egress Guard.
private struct StatusCard: View {
    let presentation: GuardPresentation

    var body: some View {
        HStack(spacing: 10) {
            MascotStage(look: presentation.look, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pip").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    GuardDot(presentation: presentation, size: 6)
                    Text(presentation.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var store: ConfigStore
    /// SMAppService status does not notify SwiftUI: store local copy, reload after toggle or appear.
    @State private var loginStatus = LoginItem.status
    @State private var loginError: String?
    @State private var confirmQuit = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle(isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                                     set: setLogin)) {
                    Text("Open at Login")
                    Text(loginError ?? LoginItem.text(loginStatus))
                }
                if loginStatus == .requiresApproval {
                    LabeledContent("Approve in System Settings") {
                        Button("Open…") { LoginItem.openSettings() }.controlSize(.small)
                    }
                }
            }
            Section {
                Toggle(isOn: $store.config.hoverExpand) {
                    Text("Expand on Hover")
                    Text("Expands the panel to view egress status and plugins")
                }
                LabeledContent("Card Duration") {
                    HStack {
                        Slider(value: $store.config.cardAutoDismissSeconds, in: 2...10, step: 1)
                            .labelsHidden()
                        Text("\(Int(store.config.cardAutoDismissSeconds)) s").monospacedDigit()
                    }
                }
                Toggle(isOn: $store.config.soundEnabled) {
                    Text("Sound Effects")
                    Text("Done: Glass - Error: Funk - Waiting: Ping - Bypassing proxy: Basso")
                }
            } header: {
                Text("Notch")
            }
            .disabled(store.fileUnreadable)
            // App does not switch language itself, delegating to system per-app setting (docs/ui.md "Localization").
            Section {
                LabeledContent {
                    Button("Change Language in System Settings…") { NSWorkspace.shared.open(Self.languageSettings) }
                        .controlSize(.small)
                } label: {
                    Text("Language")
                    Text("Follows the system language by default; you can also choose a language for Pip under Language & Region")
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Quit Pip…") { confirmQuit = true }
                }
            } footer: {
                Text("Quitting stops the notch, cards, and the Egress Guard. If the firewall is on, it keeps blocking.")
            }
        }
        .onAppear { loginStatus = LoginItem.status } // May have just been approved in System Settings
        .confirmationDialog("Quit Pip?", isPresented: $confirmQuit) {
            Button("Quit", role: .destructive) { AppDelegate.quit(reason: "quit clicked in settings") }
        } message: {
            Text("Quitting stops the notch, cards, and the Egress Guard. If the firewall is on, it keeps blocking.")
        }
    }

    /// System Settings > General > Language & Region. ID sourced from Localization.appex CFBundleIdentifier.
    private static let languageSettings = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!

    private func setLogin(_ on: Bool) {
        loginError = LoginItem.set(on)
        loginStatus = LoginItem.status
    }
}

// MARK: - Egress Guard

private struct ExitGuardPane: View {
    @ObservedObject var model: SettingsModel
    let state: AppState
    @ObservedObject var store: ConfigStore
    @State private var invalid = false

    var body: some View {
        let p = state.presentation
        Form {
            PluginOffNote(store: store, plugin: PluginID.exitGuard)
            Section("Current Status") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        GuardDot(presentation: p, size: 6)
                        Text(p.title)
                    }
                }
                // Same value as egress in expanded notch (GuardDisplay egressIP), selectable and copyable.
                LabeledContent("Current Egress") {
                    Text(state.display.egressIP ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(p.tone == .mismatch ? AnyShapeStyle(p.color) : AnyShapeStyle(.secondary))
                        .textSelection(.enabled)
                }
                LabeledContent("Last Checked") {
                    if let d = state.display.checkedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in Text(AgoText.string(d)) }
                    } else {
                        Text("—")
                    }
                }
            }
            Section {
                ForEach(store.config.allowlist, id: \.self) { ip in
                    LabeledContent {
                        Button { state.removeAllowed(ip) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove \(ip)")
                    } label: {
                        Text(ip).monospacedDigit()
                        if ip == state.display.egressIP { Text("Current Egress") }
                    }
                }
                HStack {
                    TextField("Add", text: $model.allowDraft, prompt: Text("e.g. 198.51.100.10"))
                        .onSubmit(add)
                        .onChange(of: model.allowDraft) { invalid = false }
                    Button("Add", action: add).disabled(model.allowDraft.isEmpty)
                }
            } header: {
                Text("Allowed Egress IPs (IPv4)")
            } footer: {
                if invalid {
                    Text("Not a valid IPv4 address, or already in the list.").foregroundStyle(.red)
                } else if store.fileUnreadable {
                    Text("The configuration file can’t be read; default values are shown instead of the file’s list.")
                } else if store.config.allowlist.isEmpty {
                    Text("When the list is empty, the guard cannot verify whether the egress IP is correct, showing “Can’t verify the egress”; traffic bypassing the proxy will still be alerted.")
                }
            }
            .disabled(store.fileUnreadable)
            Section("Alerts") {
                Toggle("Pop up an alert card when traffic bypasses the proxy", isOn: $store.config.autoAlert)
                Toggle("Keep the alert card up until recovered", isOn: $store.config.alertPersistent)
            }
            .disabled(store.fileUnreadable)
        }
    }

    private func add() {
        if state.addAllowed(model.allowDraft) { model.allowDraft = "" } else { invalid = true }
    }
}

// MARK: - Plugins

/// Banner on built-in plugin pane explaining effects when disabled.
private struct PluginOffNote: View {
    @ObservedObject var store: ConfigStore
    let plugin: String

    var body: some View {
        if !store.config.isEnabled(plugin) {
            Section {
                LabeledContent {
                    Button("Enable Plugin") { store.config.setEnabled(true, for: plugin) }
                        .controlSize(.small)
                        .disabled(store.fileUnreadable)
                } label: {
                    Text("Plugin Disabled")
                    Text(plugin == PluginID.exitGuard ? String(localized: "Alert cards are suppressed, and Pip and the panel will not show egress; background checks continue") : String(localized: "Cards are suppressed, and the panel will not show sessions"))
                }
            }
        }
    }
}

/// Plugin toggles, panel section order/row counts, resident plugin, and URL scheme allowlist (docs/ui.md "Panel Layout", "Card").
private struct PluginsPane: View {
    @ObservedObject var model: SettingsModel
    let state: AppState
    @ObservedObject var store: ConfigStore
    @State private var confirmGuardOff = false
    @State private var badScheme = false
    @State private var dropped: URL?
    @State private var dropTargeted = false

    var body: some View {
        let c = store.config
        let ids = state.sectionPlugins
        Form {
            Section {
                Toggle(isOn: Binding(get: { c.isEnabled(PluginID.exitGuard) }, set: setGuard)) {
                    PluginLabel(plugin: PluginID.exitGuard, state: state, detail: String(localized: "Alert card when traffic bypasses the proxy; egress shown at top of panel"))
                }
                ForEach(ids, id: \.self) { id in
                    Toggle(isOn: Binding(get: { c.isEnabled(id) }, set: { store.config.setEnabled($0, for: id) })) {
                        PluginLabel(plugin: id, state: state,
                                    detail: id == PluginID.claudeCode ? String(localized: "Lists sessions; alerts when finished, errored, or waiting for you") : String(localized: "External plugin - \(id)"))
                    }
                }
            } footer: {
                Text("Disabling a plugin only turns off its alerts; Egress Guard continues checking in the background. When an external plugin is disabled, cards and activities it sends are dropped.")
            }
            .disabled(store.fileUnreadable)

            InstalledPluginsSection(state: state, dropped: $dropped)

            let enabled = ids.filter(c.isEnabled)
            if !enabled.isEmpty {
                Section {
                    ForEach(enabled, id: \.self) { id in
                        LabeledContent {
                            HStack(spacing: 8) {
                                Stepper("Up to \(c.maxRows(id)) rows", value: Binding(get: { c.maxRows(id) }, set: { store.config.setMaxRows($0, for: id) }),
                                        in: PluginSettings.rowRange)
                                ControlGroup {
                                    Button { store.config.move(id, by: -1, in: enabled) } label: { Image(systemName: "chevron.up") }
                                        .disabled(enabled.first == id)
                                        .help("Move Up")
                                    Button { store.config.move(id, by: 1, in: enabled) } label: { Image(systemName: "chevron.down") }
                                        .disabled(enabled.last == id)
                                        .help("Move Down")
                                }
                                .fixedSize()
                            }
                        } label: {
                            PluginLabel(plugin: id, state: state, detail: nil)
                        }
                    }
                } header: {
                    Text("Panel")
                } footer: {
                    Text("Egress Guard is pinned to the top. All sections combined show up to \(PanelShape.maxRows) rows, allocated to earlier sections first; excess rows scroll within their section.")
                }
                .disabled(store.fileUnreadable)
            }

            Section {
                Picker("Resident Plugin", selection: $store.config.residentPlugin) {
                    Text("None").tag("")
                    Divider()
                    ForEach([PluginID.exitGuard] + ids, id: \.self) { id in
                        Text(state.pluginName(id)).tag(id)
                    }
                }
            } header: {
                Text("When Retracted")
            } footer: {
                Text("When plugins are active or require attention, the retracted notch displays the most urgent one; when all are quiet, it displays the resident plugin.")
            }
            .disabled(store.fileUnreadable)

            Section {
                ForEach(c.urlSchemes, id: \.self) { scheme in
                    LabeledContent {
                        Button { store.config.urlSchemes.removeAll { $0 == scheme } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove \(scheme)")
                    } label: {
                        Text("\(scheme)://").monospaced()
                    }
                }
                HStack {
                    TextField("Add", text: $model.schemeDraft, prompt: Text("e.g. raycast"))
                        .onSubmit(addScheme)
                        .onChange(of: model.schemeDraft) { badScheme = false }
                    Button("Add", action: addScheme).disabled(model.schemeDraft.isEmpty)
                }
            } header: {
                Text("URL Scheme Allowlist")
            } footer: {
                if badScheme {
                    Text("Not a valid scheme, or already in the list.").foregroundStyle(.red)
                } else {
                    Text("Links in cards and the panel open https by default. Schemes added here are also allowed: they can trigger actions in other apps, so add only ones you trust.")
                }
            }
            .disabled(store.fileUnreadable)

            CommandLineSection()
        }
        .onAppear { state.reloadManifests() } // May have just installed a plugin
        // Dropped folder inspected by InstalledPluginsSection (non-folders report missing manifest.json); recognizes first item only.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            dropped = url
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6])).padding(6)
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog("Traffic is still bypassing the proxy. Turn off alerts anyway?", isPresented: $confirmGuardOff) {
            Button("Turn Off Alerts", role: .destructive) { store.config.setEnabled(false, for: PluginID.exitGuard) }
        } message: {
            Text("The alert card will dismiss, and Pip and the panel will no longer show the egress. Background checks continue, and turning it back on restores everything immediately.")
        }
    }

    /// Confirm before disabling guard during active violation.
    private func setGuard(_ on: Bool) {
        if !on, state.presentation.status == .violated {
            confirmGuardOff = true
        } else {
            store.config.setEnabled(on, for: PluginID.exitGuard)
        }
    }

    private func addScheme() {
        guard let scheme = URLPolicy.scheme(model.schemeDraft), !store.config.urlSchemes.contains(scheme) else {
            badScheme = true
            return
        }
        store.config.urlSchemes.append(scheme)
        model.schemeDraft = ""
    }
}

/// Plugin icon and name: built-in plugins use sidebar icon, external plugins use manifest SF Symbol.
struct PluginLabel: View {
    let plugin: String
    let state: AppState
    let detail: String?

    var body: some View {
        HStack(spacing: 8) {
            switch plugin {
            case PluginID.exitGuard: SettingsIcon(symbol: SettingsPane.exitGuard.symbol, color: SettingsPane.exitGuard.color)
            case PluginID.claudeCode: SettingsIcon(symbol: SettingsPane.claudeCode.symbol, color: SettingsPane.claudeCode.color)
            default: SettingsIcon(symbol: state.manifests[plugin]?.symbol ?? "questionmark", color: .indigo)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(state.pluginName(plugin))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// CLI tool pipctl location, symlinked to ~/.local/bin upon user request (`CommandLineTool`). Works even if config file is unparseable.
private struct CommandLineSection: View {
    @State private var link = CommandLineTool.linkState()
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent {
                switch link {
                case .linked: Button("Remove Symlink") { run { try CommandLineTool.removeLink() } }
                case .absent: Button("Link to ~/.local/bin") { run { try CommandLineTool.createLink() } }
                case .occupied: EmptyView()
                }
            } label: {
                Text("pipctl")
                Text(error ?? caption)
            }
            LabeledContent {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(CommandLineTool.installed.path, forType: .string)
                }
            } label: {
                Text(CommandLineTool.installed.path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        } header: {
            Text("Command Line")
        } footer: {
            Text("Scripts use pipctl to post cards and update activities; run pipctl without arguments for usage. ~/.local/bin must be in your PATH to run pipctl directly (check with echo $PATH in Terminal).")
        }
    }

    private var caption: String {
        switch link {
        case .linked: return String(localized: "Linked: you can run pipctl directly in Terminal")
        case .absent: return String(localized: "Not linked: use the full path below, or link to ~/.local/bin")
        case .occupied: return String(localized: "~/.local/bin/pipctl is already another file; not overwriting it. Use the full path below")
        }
    }

    private func run(_ action: () throws -> Void) {
        error = nil
        do {
            try action()
        } catch {
            self.error = String(localized: "Failed: \(error.localizedDescription)")
        }
        link = CommandLineTool.linkState()
    }
}

/// Install/uninstall terminal plugin, providing line to add to ~/.zshrc. Notchkeeper never edits ~/.zshrc (CLAUDE.md hard rule). Toggled in "Plugins" pane.
private struct TerminalPluginSection: View {
    let state: AppState
    @State private var installed = TerminalPlugin.isInstalled
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent {
                Button(installed ? "Uninstall" : "Install") {
                    error = nil
                    do {
                        try installed ? TerminalPlugin.uninstall() : TerminalPlugin.install()
                    } catch {
                        self.error = String(localized: "Failed: \(error.localizedDescription)")
                        Log.write("Terminal plugin: operation failed: \(error.localizedDescription)")
                    }
                    installed = TerminalPlugin.isInstalled
                    state.reloadManifests()
                }
            } label: {
                Text("Alert when a command finishes")
                Text(error ?? (installed ? String(localized: "Installed: add the line below to ~/.zshrc; takes effect in new terminals") : String(localized: "Not installed")))
            }
            if installed {
                LabeledContent {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(TerminalPlugin.sourceLine, forType: .string)
                    }
                } label: {
                    Text(TerminalPlugin.sourceLine)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Terminal")
        } footer: {
            Text("Alerts when a command that ran in zsh for over 10 seconds finishes; clicking the card switches back to that terminal. Suppressed when you are already looking at that terminal (other tabs or splits in the same window do not count). The command line reveals only the command name, without arguments; full-screen or interactive commands like vim, ssh, and top do not alert.")
        }
    }
}

/// Install/uninstall Notchkeeper's Claude Code mod (docs/agent-integration.md "Installation & Uninstallation"). Works even if config file is unparseable.
private struct ClaudeModSection: View {
    /// nil: query in progress
    @State private var status: ClaudeMod.Status?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent {
                switch status {
                case nil:
                    ProgressView().controlSize(.small)
                case .installed?, .disabled?:
                    Button("Uninstall") { run(ClaudeMod.uninstall) }.disabled(working)
                case .notInstalled?, .unknown?:
                    Button("Install") { run(ClaudeMod.install) }.disabled(working)
                case .noClaude?:
                    EmptyView()
                }
            } label: {
                Text("Completed and Error Cards")
                Text(error ?? caption)
            }
        } header: {
            Text("Claude Code")
        } footer: {
            Text("Installs Pip’s bundled mod into Claude Code: records only how each turn finishes, never conversation contents. Installation adds a plugin entry to ~/.claude/settings.json, removed upon uninstallation. Open sessions must be restarted or run /reload-plugins to take effect.")
        }
        .task { status = await ClaudeMod.status() }
    }

    private var caption: String {
        switch status {
        case nil: return String(localized: "Checking…")
        case .installed?: return String(localized: "Installed: alerts when a turn finishes or errors")
        case .disabled?: return String(localized: "Installed, but disabled in Claude Code (enable with /plugin)")
        case .notInstalled?: return String(localized: "Not installed: panel displays session state as usual, but completed and error cards will not alert")
        case .noClaude?: return String(localized: "Can’t find claude (checked ~/.local/bin, /opt/homebrew/bin, /usr/local/bin)")
        case .unknown(let reason)?: return String(localized: "Cannot verify installation: \(reason)")
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do {
                try await action()
            } catch {
                self.error = String(localized: "Failed: \(error.localizedDescription)")
                Log.write("Claude Code mod: operation failed: \(error.localizedDescription)")
            }
            status = await ClaudeMod.status()
            working = false
        }
    }
}

// MARK: - Pip

private struct MascotPane: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    MascotStage(look: .idle, size: 40)
                    Text("Pip").font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            Section {
                Toggle(isOn: $store.config.mascotFollowsMouse) {
                    Text("Follow Mouse")
                    Text("Eyes track the mouse and the body turns toward it; peeks when the mouse moves onto the notch. When off, Pip always looks forward.")
                }
                Toggle(isOn: $store.config.showsEarMascot) {
                    Text("Show Pip When Retracted")
                    Text("When off, Pip is hidden from the left ear; if the right ear is also empty, the retracted notch is solid black. Shows normally when expanded or popping up cards.")
                }
            }
            .disabled(store.fileUnreadable)
        }
    }
}

// MARK: - State Test (in-memory only, see StateTest.swift)

private struct StateTestPane: View {
    @ObservedObject var overrides: NotchOverrides
    let state: AppState
    let notch: NotchController
    @ObservedObject private var director = MascotDirector.shared

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    MascotStage(look: overrides.mascot(real: state.look), size: 40)
                        .environment(\.mascotLiteral, overrides.look != nil)
                    // Displays look rendered above by Pip (active plugin with dizziness/sleepiness), not egress status.
                    Text(overrides.look.map { String(localized: "Forced: \($0.title)") } ?? String(localized: "Real state: \(director.shown(state.look).title)"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            Section {
                Picker("Pip", selection: Binding(get: { overrides.look }, set: { notch.force($0) })) {
                    Text("Real State").tag(Look?.none)
                    Divider()
                    ForEach(Look.allCases, id: \.self) { l in
                        Text(l.title).tag(Look?.some(l))
                    }
                }
                Picker("Notch", selection: Binding(get: { overrides.pin }, set: { notch.setPin($0) })) {
                    ForEach(NotchPin.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Force Display")
            } footer: {
                Text("Only changes how Pip and the notch look; doesn’t affect egress decisions, doesn’t pop up alert cards or play sounds. Real alert cards still appear as usual. Nothing is written to disk; restarting the app restores the real state.")
            }
            MotionSection()
            Section {
                HStack {
                    Spacer()
                    Button("Restore Real State") { notch.restoreRealState() }
                        .disabled(overrides.isReal)
                }
            }
        }
    }
}

/// "Play Motion": visible Pips play action once regardless of current look. In-memory only.
private struct MotionSection: View {
    var body: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), alignment: .leading)], alignment: .leading) {
                ForEach(Motion.allCases, id: \.self) { m in
                    Button(m.title) { MascotDirector.shared.play(.idle(m)) }
                }
                Button("Blink") { MascotDirector.shared.play(.blink(double: false)) }
            }
        } header: {
            Text("Play Motion")
        } footer: {
            Text("Every visible Pip plays it once; with Reduce Motion on, only blinking. Nothing is written to disk.")
        }
    }
}

private extension Motion {
    var title: String {
        switch self {
        case .spinAround: return String(localized: "Spin")
        case .flip: return String(localized: "Flip")
        case .lookAround: return String(localized: "Look Around")
        case .nod: return String(localized: "Nod")
        case .tilt: return String(localized: "Tilt Head")
        case .shake: return String(localized: "Shake Head")
        case .lookUp: return String(localized: "Look Up")
        case .lookDown: return String(localized: "Look Down")
        case .sideways: return String(localized: "Turn 90°")
        case .curious: return String(localized: "Curious Tilt")
        case .finishJump: return String(localized: "Victory Hop")
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    MascotStage(look: .finished, size: 64)
                    Text("Pip").font(.title3.weight(.semibold))
                    Text("Version \(version) (signed locally)").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            Section("Files") {
                LabeledContent {
                    HStack {
                        Button("Open") { store.openFile() }
                        Button("Show in Finder") { store.revealInFinder() }
                    }
                    .controlSize(.small)
                } label: {
                    Text("Config File")
                    Text(tilde(store.url.path))
                }
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Log.url]) }
                        .controlSize(.small)
                } label: {
                    Text("Log")
                    Text(tilde(Log.url.path))
                }
            }
        }
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
    }

    private func tilde(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }
}
