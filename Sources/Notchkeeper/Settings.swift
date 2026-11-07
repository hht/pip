import AppKit
import SwiftUI
import MascotCore
import NotchCore
import PluginCore

// 设置窗口：按 macOS 系统设置的布局，只用原生控件。
// 每个开关直接绑定 ConfigStore，改了立刻写盘，不在视图里缓存配置值。

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, plugins, exitGuard, claudeCode, terminal, firewall, mascot, stateTest, about
    var id: Self { self }

    /// 侧边栏分组，组与组之间空一行。内置插件和自带的终端插件各有一页，别的外部插件只在「插件」页里开关
    static let groups: [[SettingsPane]] = [[.general], [.plugins, .exitGuard, .claudeCode, .terminal], [.firewall], [.mascot], [.stateTest], [.about]]

    var title: String {
        switch self {
        case .general: return String(localized: "通用")
        case .plugins: return String(localized: "插件")
        case .exitGuard: return String(localized: "出口守卫")
        case .claudeCode: return "Claude Code"
        case .terminal: return String(localized: "终端")
        case .firewall: return String(localized: "防火墙")
        case .mascot: return "Pip" // 和 App 同名
        case .stateTest: return String(localized: "状态测试")
        case .about: return String(localized: "关于")
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

/// 关掉窗口后 SwiftUI 视图会卸载，选中的页和白名单输入框里的半截地址放这里
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
            // 留着侧栏开关：工具栏一个按钮都没有时，系统按普通标题栏画，滚动时是一条硬边线；有按钮才是系统设置那种柔和渐隐（实测）
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

/// config.json 解不开时，改了也存不进去（ConfigStore 不覆盖原文件），所以先说清楚，并把改配置的控件禁掉
private struct ConfigUnreadableBanner: View {
    let store: ConfigStore

    var body: some View {
        HStack(spacing: 8) {
            // 多色：黄三角里是黑色的 !，亮色的浅底上也看得清
            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            Text("配置文件读不了，暂时不能改设置。修好文件后自动恢复。")
            Spacer()
            Button("打开配置文件") { store.openFile() }.controlSize(.small)
        }
        .font(.callout)
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

/// 系统设置式图标：20×20 圆角 5 的色块，白色符号
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

/// 侧边栏顶部的状态卡，点它跳到「出口守卫」
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

// MARK: - 通用

private struct GeneralPane: View {
    @ObservedObject var store: ConfigStore
    /// SMAppService 的状态不会通知 SwiftUI：存一份，改完开关和每次出现时重读
    @State private var loginStatus = LoginItem.status
    @State private var loginError: String?
    @State private var confirmQuit = false

    var body: some View {
        Form {
            Section("启动") {
                Toggle(isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                                     set: setLogin)) {
                    Text("登录时打开")
                    Text(loginError ?? LoginItem.text(loginStatus))
                }
                if loginStatus == .requiresApproval {
                    LabeledContent("在系统设置中批准") {
                        Button("打开…") { LoginItem.openSettings() }.controlSize(.small)
                    }
                }
            }
            Section {
                Toggle(isOn: $store.config.hoverExpand) {
                    Text("鼠标悬停时展开")
                    Text("展开面板，查看出口状态和各插件")
                }
                LabeledContent("卡片停留") {
                    HStack {
                        Slider(value: $store.config.cardAutoDismissSeconds, in: 2...10, step: 1)
                            .labelsHidden()
                        Text("\(Int(store.config.cardAutoDismissSeconds)) 秒").monospacedDigit()
                    }
                }
                Toggle(isOn: $store.config.soundEnabled) {
                    Text("提示音")
                    Text("完成 Glass · 出错 Funk · 等你 Ping · 有流量没走代理 Basso")
                }
            } header: {
                Text("刘海")
            }
            .disabled(store.fileUnreadable)
            // App 不自己切语言，交给系统按 App 设（docs/ui.md「多语言」）
            Section {
                LabeledContent {
                    Button("在系统设置中更改语言…") { NSWorkspace.shared.open(Self.languageSettings) }
                        .controlSize(.small)
                } label: {
                    Text("语言")
                    Text("默认跟随系统；也可以在「语言与地区」里单独给 Pip 选")
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("退出 Pip…") { confirmQuit = true }
                }
            } footer: {
                Text("退出后刘海和卡片都会停止，后台的出口守卫照常运行；要停止守卫，请运行卸载脚本。")
            }
        }
        .onAppear { loginStatus = LoginItem.status } // 可能刚在系统设置里批准过
        .confirmationDialog("退出 Pip？", isPresented: $confirmQuit) {
            Button("退出", role: .destructive) { AppDelegate.quit(reason: "设置里点了退出") }
        } message: {
            Text("退出后刘海和卡片都会停止，后台的出口守卫照常运行；要停止守卫，请运行卸载脚本。")
        }
    }

    /// 系统设置 › 通用 › 语言与地区。id 取自 /System/Library/ExtensionKit/Extensions/Localization.appex 的 CFBundleIdentifier（macOS 26 实查）
    private static let languageSettings = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!

    private func setLogin(_ on: Bool) {
        loginError = LoginItem.set(on)
        loginStatus = LoginItem.status
    }
}

// MARK: - 出口守卫

private struct ExitGuardPane: View {
    @ObservedObject var model: SettingsModel
    let state: AppState
    @ObservedObject var store: ConfigStore
    @State private var invalid = false

    var body: some View {
        let p = state.presentation
        Form {
            PluginOffNote(store: store, plugin: PluginID.exitGuard)
            Section("当前状态") {
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        GuardDot(presentation: p, size: 6)
                        Text(p.title)
                    }
                }
                // 和刘海展开后的出口是同一个值（GuardDisplay 的 egressIP），完整显示，可选中拷贝
                LabeledContent("当前出口") {
                    Text(state.display.egressIP ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(p.tone == .mismatch ? AnyShapeStyle(p.color) : AnyShapeStyle(.secondary))
                        .textSelection(.enabled)
                }
                LabeledContent("上次检查") {
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
                            .help("移除 \(ip)")
                    } label: {
                        Text(ip).monospacedDigit()
                        if ip == state.display.egressIP { Text("当前出口") }
                    }
                }
                HStack {
                    TextField("新增", text: $model.allowDraft, prompt: Text("例如 198.51.100.10"))
                        .onSubmit(add)
                        .onChange(of: model.allowDraft) { invalid = false }
                    Button("添加", action: add).disabled(model.allowDraft.isEmpty)
                }
            } header: {
                Text("允许的出口 IP（IPv4）")
            } footer: {
                if invalid {
                    Text("不是有效的 IPv4 地址，或已在列表里。").foregroundStyle(.red)
                } else if store.fileUnreadable {
                    Text("配置文件读不了，这里显示的是默认值，不是文件里的列表。")
                } else if store.config.allowlist.isEmpty {
                    Text("列表为空时，守卫判断不了出口 IP 对不对，只能显示「暂时判断不了出口」；有流量没走代理仍然会报。")
                }
            }
            .disabled(store.fileUnreadable)
            Section("提示") {
                Toggle("有流量没走代理时弹红卡", isOn: $store.config.autoAlert)
                Toggle("红卡一直保留，直到恢复", isOn: $store.config.alertPersistent)
            }
            .disabled(store.fileUnreadable)
        }
    }

    private func add() {
        if state.addAllowed(model.allowDraft) { model.allowDraft = "" } else { invalid = true }
    }
}

// MARK: - 插件

/// 内置插件的页上：插件关着时说清楚关掉的是什么
private struct PluginOffNote: View {
    @ObservedObject var store: ConfigStore
    let plugin: String

    var body: some View {
        if !store.config.isEnabled(plugin) {
            Section {
                LabeledContent {
                    Button("打开插件") { store.config.setEnabled(true, for: plugin) }
                        .controlSize(.small)
                        .disabled(store.fileUnreadable)
                } label: {
                    Text("插件已关闭")
                    Text(plugin == PluginID.exitGuard ? "不弹红卡，Pip 和面板也不显示出口；后台照常检查" : "不弹卡，面板里也不显示会话")
                }
            }
        }
    }
}

/// 插件的开关、面板里各段的顺序和行数、收起时常驻谁、链接白名单（docs/ui.md「面板布局」「卡片」）
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
                    PluginLabel(plugin: PluginID.exitGuard, state: state, detail: String(localized: "有流量没走代理时弹红卡，面板顶上显示出口"))
                }
                ForEach(ids, id: \.self) { id in
                    Toggle(isOn: Binding(get: { c.isEnabled(id) }, set: { store.config.setEnabled($0, for: id) })) {
                        PluginLabel(plugin: id, state: state,
                                    detail: id == PluginID.claudeCode ? String(localized: "列出会话；做完、出错、等你时弹卡") : String(localized: "外部插件 · \(id)"))
                    }
                }
            } footer: {
                Text("关掉插件只关提醒，出口守卫照常在后台检查。外部插件关掉后，它发来的卡片和活动都会丢掉。")
            }
            .disabled(store.fileUnreadable)

            InstalledPluginsSection(state: state, dropped: $dropped)

            let enabled = ids.filter(c.isEnabled)
            if !enabled.isEmpty {
                Section {
                    ForEach(enabled, id: \.self) { id in
                        LabeledContent {
                            HStack(spacing: 8) {
                                Stepper("最多 \(c.maxRows(id)) 行", value: Binding(get: { c.maxRows(id) }, set: { store.config.setMaxRows($0, for: id) }),
                                        in: PluginSettings.rowRange)
                                ControlGroup {
                                    Button { store.config.move(id, by: -1, in: enabled) } label: { Image(systemName: "chevron.up") }
                                        .disabled(enabled.first == id)
                                        .help("上移")
                                    Button { store.config.move(id, by: 1, in: enabled) } label: { Image(systemName: "chevron.down") }
                                        .disabled(enabled.last == id)
                                        .help("下移")
                                }
                                .fixedSize()
                            }
                        } label: {
                            PluginLabel(plugin: id, state: state, detail: nil)
                        }
                    }
                } header: {
                    Text("面板")
                } footer: {
                    Text("出口守卫固定在最上面。各段合起来最多显示 \(PanelShape.maxRows) 行，排在前面的先占；多出来的在段里滚动。")
                }
                .disabled(store.fileUnreadable)
            }

            Section {
                Picker("常驻插件", selection: $store.config.residentPlugin) {
                    Text("不常驻").tag("")
                    Divider()
                    ForEach([PluginID.exitGuard] + ids, id: \.self) { id in
                        Text(state.pluginName(id)).tag(id)
                    }
                }
            } header: {
                Text("收起时")
            } footer: {
                Text("有插件在忙或要你看时，收起的刘海显示最急的那个；都平静时显示常驻插件。")
            }
            .disabled(store.fileUnreadable)

            Section {
                ForEach(c.urlSchemes, id: \.self) { scheme in
                    LabeledContent {
                        Button { store.config.urlSchemes.removeAll { $0 == scheme } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("移除 \(scheme)")
                    } label: {
                        Text("\(scheme)://").monospaced()
                    }
                }
                HStack {
                    TextField("新增", text: $model.schemeDraft, prompt: Text("例如 raycast"))
                        .onSubmit(addScheme)
                        .onChange(of: model.schemeDraft) { badScheme = false }
                    Button("添加", action: addScheme).disabled(model.schemeDraft.isEmpty)
                }
            } header: {
                Text("链接白名单")
            } footer: {
                if badScheme {
                    Text("不是有效的 scheme，或已在列表里。").foregroundStyle(.red)
                } else {
                    Text("卡片和面板里的链接默认只打开 https。这里加的 scheme 也放行：它们能让别的 App 执行动作，只加你信得过的。")
                }
            }
            .disabled(store.fileUnreadable)

            CommandLineSection()
        }
        .onAppear { state.reloadManifests() } // 可能刚装了插件
        // 拖进来的交给「已安装」那一段校验（不是文件夹的报「没有 manifest.json」）；只认第一个
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
        .confirmationDialog("还有流量没走代理，确定关掉提醒？", isPresented: $confirmGuardOff) {
            Button("关掉提醒", role: .destructive) { store.config.setEnabled(false, for: PluginID.exitGuard) }
        } message: {
            Text("红卡会撤下，Pip 和面板不再显示出口；后台照常检查，重新打开立即恢复。")
        }
    }

    /// 违规中关守卫要确认
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

/// 插件的图标和名字：内置的用设置页侧栏的图标，外部的用它登记的 SF Symbol
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

/// 命令行工具 pipctl 在哪，点了才链进 ~/.local/bin（`CommandLineTool`）。不靠 config.json，配置文件解不开也能用
private struct CommandLineSection: View {
    @State private var link = CommandLineTool.linkState()
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent {
                switch link {
                case .linked: Button("移除链接") { run { try CommandLineTool.removeLink() } }
                case .absent: Button("链接到 ~/.local/bin") { run { try CommandLineTool.createLink() } }
                case .occupied: EmptyView()
                }
            } label: {
                Text("pipctl")
                Text(error ?? caption)
            }
            LabeledContent {
                Button("拷贝") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(CommandLineTool.installed.path, forType: .string)
                }
            } label: {
                Text(CommandLineTool.installed.path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        } header: {
            Text("命令行")
        } footer: {
            Text("脚本用 pipctl 发卡片、报活动，pipctl 不带参数看用法。~/.local/bin 要在 PATH 里才能直接敲 pipctl（终端里 echo $PATH 看）。")
        }
    }

    private var caption: String {
        switch link {
        case .linked: return String(localized: "已链接：终端里可以直接用 pipctl")
        case .absent: return String(localized: "未链接：用下面的完整路径，或链接到 ~/.local/bin")
        case .occupied: return String(localized: "~/.local/bin/pipctl 已经是别的文件，不覆盖；用下面的完整路径")
        }
    }

    private func run(_ action: () throws -> Void) {
        error = nil
        do {
            try action()
        } catch {
            self.error = String(localized: "操作失败：\(error.localizedDescription)")
        }
        link = CommandLineTool.linkState()
    }
}

/// 装、卸终端插件，给出要加进 ~/.zshrc 的一行。Notchkeeper 不改 ~/.zshrc（CLAUDE.md 硬规则）。开关在「插件」页（它是外部插件）
private struct TerminalPluginSection: View {
    let state: AppState
    @State private var installed = TerminalPlugin.isInstalled
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent {
                Button(installed ? "卸载" : "安装") {
                    error = nil
                    do {
                        try installed ? TerminalPlugin.uninstall() : TerminalPlugin.install()
                    } catch {
                        self.error = String(localized: "操作失败：\(error.localizedDescription)")
                        Log.write("终端插件：操作失败：\(error.localizedDescription)")
                    }
                    installed = TerminalPlugin.isInstalled
                    state.reloadManifests()
                }
            } label: {
                Text("命令跑完时弹卡")
                Text(error ?? (installed ? String(localized: "已安装：把下面这行加进 ~/.zshrc，新开的终端生效") : String(localized: "未安装")))
            }
            if installed {
                LabeledContent {
                    Button("拷贝") {
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
            Text("终端")
        } footer: {
            Text("zsh 里跑了 10 秒以上的命令结束时弹卡，点卡片跳回那个终端。你正看着那个终端时不弹（同一窗口的其他标签、分屏不算）。命令行只交出命令名，不带参数；vim、ssh、top 这类全屏或交互的命令不弹。")
        }
    }
}

/// 装、卸 Notchkeeper 的 Claude Code mod（docs/agent-integration.md「安装和卸载」）。不靠 config.json，配置文件解不开也能用
private struct ClaudeModSection: View {
    /// nil：还在查
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
                    Button("卸载") { run(ClaudeMod.uninstall) }.disabled(working)
                case .notInstalled?, .unknown?:
                    Button("安装") { run(ClaudeMod.install) }.disabled(working)
                case .noClaude?:
                    EmptyView()
                }
            } label: {
                Text("完成卡和出错卡")
                Text(error ?? caption)
            }
        } header: {
            Text("Claude Code")
        } footer: {
            Text("给 Claude Code 装上 Pip 自带的 mod：只记录每个回合怎么结束，不记录对话内容。安装会在 ~/.claude/settings.json 里加一项插件，卸载时去掉。已经开着的会话要重开或运行 /reload-plugins 才生效。")
        }
        .task { status = await ClaudeMod.status() }
    }

    private var caption: String {
        switch status {
        case nil: return String(localized: "正在检查…")
        case .installed?: return String(localized: "已安装：回合做完或出错时弹卡")
        case .disabled?: return String(localized: "已安装，但在 Claude Code 里关掉了（/plugin 里打开）")
        case .notInstalled?: return String(localized: "未安装：面板照常显示会话状态，但不弹完成卡和出错卡")
        case .noClaude?: return String(localized: "找不到 claude（找过 ~/.local/bin、/opt/homebrew/bin、/usr/local/bin）")
        case .unknown(let reason)?: return String(localized: "无法确认是否已安装：\(reason)")
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do {
                try await action()
            } catch {
                self.error = String(localized: "操作失败：\(error.localizedDescription)")
                Log.write("Claude Code mod：操作失败：\(error.localizedDescription)")
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
                    Text("跟随鼠标")
                    Text("眼睛跟着鼠标，身体也往那边转；鼠标移到刘海上时探头。关掉后一直看正前方")
                }
                Toggle(isOn: $store.config.showsEarMascot) {
                    Text("收起时显示 Pip")
                    Text("关掉后左耳不显示 Pip；右耳也没有内容时，刘海就是一块纯黑。展开和弹卡时照常显示")
                }
            }
            .disabled(store.fileUnreadable)
        }
    }
}

// MARK: - 状态测试（只在内存里，见 StateTest.swift）

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
                    // 说的是上面这只 Pip 此刻画的造型（上位插件的，叠上晕和睡着），不是出口状态
                    Text(overrides.look.map { "强制：\($0.title)" } ?? "真实状态：\(director.shown(state.look).title)")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            Section {
                Picker("Pip", selection: Binding(get: { overrides.look }, set: { notch.force($0) })) {
                    Text("真实状态").tag(Look?.none)
                    Divider()
                    ForEach(Look.allCases, id: \.self) { l in
                        Text(l.title).tag(Look?.some(l))
                    }
                }
                Picker("刘海", selection: Binding(get: { overrides.pin }, set: { notch.setPin($0) })) {
                    ForEach(NotchPin.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("强制显示")
            } footer: {
                Text("只改 Pip 和刘海的样子，不影响出口判定，也不弹红卡、不响；真的红卡照常弹出。不写入任何文件，重开 App 即恢复。")
            }
            MotionSection()
            Section {
                HStack {
                    Spacer()
                    Button("恢复真实状态") { notch.restoreRealState() }
                        .disabled(overrides.isReal)
                }
            }
        }
    }
}

/// 「播放动作」：看得见的 Pip（左耳、上面的预览）各播一次，不管当前造型。只在内存里
private struct MotionSection: View {
    var body: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), alignment: .leading)], alignment: .leading) {
                ForEach(Motion.allCases, id: \.self) { m in
                    Button(m.title) { MascotDirector.shared.play(.idle(m)) }
                }
                Button("眨眼") { MascotDirector.shared.play(.blink(double: false)) }
            }
        } header: {
            Text("播放动作")
        } footer: {
            Text("看得见的 Pip 各播放一次；开启「减弱动态效果」时只有眨眼。不写入任何文件。")
        }
    }
}

private extension Motion {
    var title: String {
        switch self {
        case .spinAround: return String(localized: "左右转圈")
        case .flip: return String(localized: "上下翻圈")
        case .lookAround: return String(localized: "东张西望")
        case .nod: return String(localized: "点头")
        case .tilt: return String(localized: "歪头")
        case .shake: return String(localized: "摇头")
        case .lookUp: return String(localized: "抬头看天")
        case .lookDown: return String(localized: "低头看脚")
        case .sideways: return String(localized: "侧身 90°")
        case .curious: return String(localized: "好奇歪看")
        case .finishJump: return String(localized: "完成跳转")
        }
    }
}

// MARK: - 关于

private struct AboutPane: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    MascotStage(look: .finished, size: 64)
                    Text("Pip").font(.title3.weight(.semibold))
                    Text("版本 \(version)（本机签名）").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            Section("文件") {
                LabeledContent {
                    HStack {
                        Button("打开") { store.openFile() }
                        Button("在访达中显示") { store.revealInFinder() }
                    }
                    .controlSize(.small)
                } label: {
                    Text("配置文件")
                    Text(tilde(store.url.path))
                }
                LabeledContent {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([Log.url]) }
                        .controlSize(.small)
                } label: {
                    Text("日志")
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
