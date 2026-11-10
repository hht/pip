import AppKit
import NotchCore
import PluginCore
import PluginStore
import SwiftUI

/// Settings > Plugins: Install, uninstall, and create external plugins by picking a folder or dragging it in; inspects manifest before installing; uninstalled plugins move to backup.
/// File operations and validation belong to `PluginStore`, run in background: UI never stalls on large plugin folders or slow disks. Does not rely on config.json, working even if config is unparseable.
struct InstalledPluginsSection: View {
    let state: AppState
    /// Folder dropped onto the pane (handled by `PluginsPane`): validated upon arrival.
    @Binding var dropped: URL?
    @State private var pending: Pending?
    @State private var uninstalling: Manifest?
    @State private var creating = false
    @State private var choosing = false
    @State private var working = false
    @State private var error: String?

    /// Validated folder awaiting user click on "Install".
    struct Pending: Identifiable {
        var source: URL
        var manifest: Manifest
        var replacing: Bool
        var id: URL { source }
    }

    var body: some View {
        let installed = state.manifests.values.sorted { $0.id < $1.id }
        Section {
            ForEach(installed, id: \.id) { m in
                LabeledContent {
                    HStack(spacing: 4) {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([PluginPaths.plugins.appendingPathComponent(m.id)]) } label: {
                            Image(systemName: "folder")
                        }
                        .help("Show in Finder")
                        Button("Uninstall…") { uninstalling = m }
                    }
                    .buttonStyle(.borderless)
                    .disabled(working)
                } label: {
                    PluginLabel(plugin: m.id, state: state, detail: m.id)
                }
            }
            HStack {
                Button("Install Plugin…") { choosing = true }
                Button("New Plugin…") { creating = true }
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }
            .disabled(working)
        } header: {
            Text("Installed")
        } footer: {
            if let error {
                Text(error).foregroundStyle(.red)
            } else {
                Text("A plugin is a folder containing manifest.json; you can also drag one onto this page to install it. Pip never runs any file in a plugin. Uninstalled plugins move to ~/Library/Application Support/Notchkeeper/backup/plugins/ and aren’t deleted (except the built-in terminal plugin).")
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): inspect(url)
            case .failure(let e): error = String(localized: "Couldn’t open this folder: \(e.localizedDescription)")
            }
        }
        .sheet(item: $pending) { p in
            InstallPluginSheet(pending: p) { install(p.source) }
        }
        .sheet(isPresented: $creating) {
            NewPluginSheet { state.reloadManifests() }
        }
        .confirmationDialog(uninstalling.map { String(localized: "Uninstall “\($0.name)”?") } ?? "", isPresented: Binding(
            get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } }), presenting: uninstalling) { m in
            Button("Uninstall", role: .destructive) { uninstall(m) }
        } message: { m in
            // Terminal plugin directory is managed by App and refreshed on launch, containing no user data: delete directly.
            Text(m.id == PluginID.terminal ? String(localized: "Deletes the terminal plugin’s script; the line in ~/.zshrc can stay without errors. Cards from the terminal will be dropped after this.")
                                           : String(localized: "The plugin folder moves to the backup folder and isn’t deleted. Cards and activities it sends afterwards are discarded."))
        }
        .onChange(of: dropped) {
            guard let url = dropped else { return }
            dropped = nil
            inspect(url)
        }
    }

    private func inspect(_ url: URL) {
        error = nil
        run { store in
            let m = try store.inspect(url, symbolExists: InboxWatcher.symbolExists)
            let replacing = FileManager.default.fileExists(atPath: store.plugins.appendingPathComponent(m.id).path)
            return Pending(source: url, manifest: m, replacing: replacing)
        } then: { pending = $0 }
    }

    private func install(_ url: URL) {
        run { store in
            try store.install(url, symbolExists: InboxWatcher.symbolExists, now: Date())
        } then: { result in
            Log.write("Plugin: installed \(result.manifest.id)\(result.replaced == nil ? "" : ", previous version moved to backup")")
        }
    }

    private func uninstall(_ m: Manifest) {
        run { store in
            if m.id == PluginID.terminal { try TerminalPlugin.uninstall() } else { _ = try store.uninstall(m.id, now: Date()) }
        } then: { _ in
            Log.write("Plugin: uninstalled \(m.id)")
        }
    }

    /// Background file operations, returning to main thread to update UI and reload manifests. Errors surface locally on page.
    private func run<T: Sendable>(_ work: @escaping @Sendable (PluginStore) throws -> T, then: @escaping @MainActor (T) -> Void) {
        working = true
        error = nil
        Task {
            let result = await Task.detached { Result { try work(PluginStore()) } }.value
            switch result {
            case .success(let value): then(value)
            case .failure(let e): error = e.localizedDescription
            }
            state.reloadManifests()
            working = false
        }
    }
}

/// Explanations displayed in settings pane. Aligns with `pipctl plugin` output (`PluginCommand.describe`).
extension PluginStore.Problem: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noManifest: return String(localized: "The folder has no manifest.json")
        case .manifest(.malformed): return String(localized: "manifest.json isn’t valid JSON, or is missing id, name, or symbol")
        case .manifest(.badID): return String(localized: "The id may only contain lowercase letters, digits, and hyphens, up to 32 characters")
        case .manifest(.reservedID): return String(localized: "That id belongs to a built-in plugin (guard, claude); choose another")
        case .manifest(.missingField): return String(localized: "Name (name) and icon (symbol) can’t be empty")
        case .manifest(.tooLong): return String(localized: "Name can be at most \(Card.maxValue) characters, icon name at most \(Manifest.maxSymbol)")
        case .unknownSymbol(let s): return String(localized: "There’s no SF Symbol named \(s) (look up names in the SF Symbols app)")
        case .bundled: return String(localized: "terminal is the bundled Terminal plugin; install or uninstall it in Settings › Terminal")
        case .alreadyInstalled: return String(localized: "This folder is the installed copy itself")
        case .notInstalled: return String(localized: "This plugin isn’t installed")
        case .exists: return String(localized: "A plugin with this id is already installed")
        }
    }
}

/// Inspection sheet prior to installation: displays registered name, icon, id, and replacement warning.
struct InstallPluginSheet: View {
    let pending: InstalledPluginsSection.Pending
    let onInstall: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let m = pending.manifest
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PluginIcon(symbol: m.symbol, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install “\(m.name)”").font(.headline)
                    Text(m.id).font(.caption).monospaced().foregroundStyle(.secondary)
                }
            }
            Text(pending.source.path(percentEncoded: false)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if pending.replacing {
                Label("A plugin with the same id is installed: the old version moves to the backup folder and isn’t deleted.", systemImage: "arrow.triangle.2.circlepath")
            }
            Text("Pip only reads its manifest.json and never runs any file inside. Cards it sends will show where they came from.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(pending.replacing ? "Replace" : "Install") {
                    dismiss()
                    onInstall()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Creates a new plugin with manifest.json only, providing a runnable pipctl command on completion.
struct NewPluginSheet: View {
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var id = ""
    @State private var symbol = ""
    @State private var created: Manifest?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let created { done(created) } else { form }
        }
        .frame(width: 440)
    }

    private var form: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name, prompt: Text("Shown on its cards, e.g. “Backup”"))
                VStack(alignment: .leading, spacing: 4) {
                    TextField("id", text: $id, prompt: Text("e.g. backup"))
                    if let idProblem { Text(idProblem).font(.caption).foregroundStyle(.red) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent {
                        HStack {
                            TextField("Icon", text: $symbol, prompt: Text("SF Symbol name, e.g. externaldrive")).labelsHidden()
                            PluginIcon(symbol: symbolValid ? symbol : "questionmark", size: 22)
                        }
                    } label: {
                        Text("Icon")
                    }
                    if !symbol.isEmpty, !symbolValid { Text("No such icon; look up names in the SF Symbols app").font(.caption).foregroundStyle(.red) }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.allSatisfy(\.isWhitespace) || id.isEmpty || idProblem != nil || !symbolValid)
            }
            .padding([.horizontal, .bottom], 20)
        }
    }

    private func done(_ m: Manifest) -> some View {
        let command = "pipctl notify --plugin \(m.id) --title \"Hello\""
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PluginIcon(symbol: m.symbol, size: 40)
                Text("Created “\(m.name)”").font(.headline)
            }
            Text("Run this in Terminal and a card will pop out of the notch:")
            HStack {
                Text(command).monospaced().textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([PluginPaths.plugins.appendingPathComponent(m.id)]) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private var symbolValid: Bool { !symbol.isEmpty && InboxWatcher.symbolExists(symbol) }

    /// Live validation: format, reserved IDs, already installed.
    private var idProblem: String? {
        guard !id.isEmpty else { return nil }
        guard Message.isPluginID(id) else { return String(localized: "Only lowercase letters, digits, and hyphens, up to 32 characters") }
        guard !PluginID.builtIn.contains(id), id != PluginID.terminal else { return String(localized: "This id is reserved for a built-in plugin; choose another") }
        guard !FileManager.default.fileExists(atPath: PluginPaths.plugins.appendingPathComponent(id).path) else { return String(localized: "A plugin with this id is already installed") }
        return nil
    }

    private func create() {
        error = nil
        do {
            created = try PluginStore().create(id: id, name: name, symbol: symbol, symbolExists: InboxWatcher.symbolExists)
            Log.write("Plugin: created \(id)")
            onCreated()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// External plugin icon: rounded background matching settings sidebar, scalable.
struct PluginIcon: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4, style: .continuous)
            .fill(Color.indigo.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.6, weight: .semibold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}
