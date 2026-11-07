# CLAUDE.md — Notchkeeper（App 显示名 Pip）

> 本轮用户输入优先于任何文档。通用 MUST NOT 与收工分档见全局 Contract（`~/.agents/AGENTS.md`）。

面向普通用户的 macOS 刘海应用（SwiftPM，SwiftUI + AppKit，macOS 14+，简体中文和 English，没有菜单栏图标，开着设置窗口时才出现在 Dock）。四件事：**出口守卫**（用户级 LaunchAgent `guardd` 只监测流量是否全走 Clash，App 画在刘海上）、**防火墙**（一键开关）、**提醒卡片**（Claude Code 顶层回合结束、需要你介入）、**Pip**（原创吉祥物，用表情说状态）。

开工前读 `HANDOFF.md`（接下来做什么）；运行与安装见 `README.md`；每个 target 的职责见 `Package.swift` 的注释。

## 准则

1. **删除优先。** 每行代码都要答得出「删掉会坏什么」，答不出就删（可读性不降的前提下）。只转发、只换名字、只有一个调用方的函数和类型一律内联。不为没出现的需求写代码。
2. **一个模块一个问题。** 按会独立变化的设计决定划分 target 和文件，不按 View / Model / Manager 切；类型注释第一句写它回答哪个问题、不该知道什么。核心 target（`GuardCore`、`AgentCore`、`MascotCore`、`NotchCore`、`PluginCore`）是纯值类型，不 import SwiftUI / AppKit，依赖单向无环；文件监听、探针、pf、画界面放外层。
3. **本质对、分支少。** 先定数据结构、状态机与不变量；同一件事只有一个 owner；要调速先测量。
4. **测试先行。** 新行为、新规则、修 bug 先写会失败的测试，亲眼看它红。时间、随机数、文件系统、探针、进程表都从参数注入。测不了的（窗口、动效、权限弹窗、pf）在提交说明里写实机步骤和结果。
5. **信任边界。** 外部数据（sessions、回合文件、`config.json`、`guard-state.json`、防火墙状态、探针响应、`proc_pidpath`）在边界解析成精确类型；**「未知」是一个值**，不是 healthy 也不是 violated；解析不了的计数并降级，不崩溃、不覆盖原文件；内部不变量坏了就 `preconditionFailure`。
6. **从根源解决。** 先复现、拿出根因证据再改；特例 if、`asyncAfter` 延时、`try?` 吞错误、改文案都是症状补丁。找不到根因就停下报告。
7. **先查一手资料和成熟实现**（Apple 文档、WWDC、agent 的会话格式、开源同类产品），在此之上可以自己设计；界面效果凭感觉调参前先看别人怎么做。依赖外部行为的代码按实际版本核实，用 `// @see` 指向出处。
8. **照 Swift 社区惯例**：[API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)，缩写大小写一致（`IP`、`URL`、`ID`），优先值类型和 `enum` 状态机，错误用 `throws` 带具体类型，UI 状态只在 `@MainActor` 上改，外部数据不强制解包。注释只写最终解释：为什么这样做、依据哪份资料或哪个版本上的实测；日期、谁拍板、哪轮审查发现的写进提交说明。同一概念只有一个名字，以 `docs/ubiquitous-language.md` 为准。

**决策序：** 正确性 > 可验证性 > 极简 > 性能 > 复用 > 速度。

## 硬规则

- **守卫只监测，判定止于 `GuardCore`**：violated 只有一轮完整的 healthy 才能解除，断网、探针超时、守卫停了都不降级；unknown 不弹卡。红卡挂不挂由 `NotchCore` 的 `ViolationAlert` 定，从任何路径进入 healthy 都撤红卡。
- **防火墙安全第一。动防火墙、pf、LaunchDaemon 之前必须读完 `docs/firewall.md`。** 先写好并实测恢复脚本才能写 block 规则，恢复脚本不依赖网络、App 和已安装的防火墙脚本；每次开启先试运行，2 分钟没确认自动回滚；只用自己的 pf anchor，不改 `/etc/pf.conf`，不用 Network Extension；规则里不写 `user` / `group`（会让 pf 内核死锁、只能重启）；Clash 只在开启防火墙时读一次 Clash Verge 的运行时配置（节点和 DNS 上游的地址）和 GeoIP 库，不写任何 Clash 文件；不碰 sudoers；开启、保留、关闭都要管理员密码；App 不常驻特权代码；安装、卸载由用户点确认框、在系统密码框输管理员密码（开发时也可以在终端里 sudo），不覆盖已有文件；agent 改规则先给用户看 diff；agent 只在用户当轮明确要求时用 osascript 提权，密码由用户自己在系统密码框里输；不杀进程，不针对任何 App。
- **Claude Code 只读元数据，不读对话内容。** 会话文件只取判定需要的字段，不退回读会话 JSONL；日志和界面不出现会话里的消息正文、工具参数和输出（外部插件自己发来的卡片内容不在此列，用户 10-31）；mod 看得到正文，只写出元数据。唯一例外：跳转 Ghostty 时读到的终端标题只在内存里找标记、原样写回，不显示、不进日志。
- **Claude Code**：只提醒顶层回合的结束（做完、出错）和需要你介入，子 agent 的不算；状态只由 `AgentCore` 判定，来源是 sessions 文件和自带 mod 写的回合文件；不用 settings.json 的 hooks；改 Claude Code 配置只有设置页「安装 / 卸载」调 `claude plugin`；sessions 和 mod API 格式变了直接改代码，不做兼容。
- **插件**：出口守卫和 Claude Code 是内置插件，能在设置里关（关的是提醒，不是判定；违规中关守卫要确认）。外部插件可信但受限：卡上标明来源；不能用红色、绿色和 danger、不能撤或盖住红卡（`Card` 构造时把 violation、recovered 降级，`CardQueue` 让它们在红卡挂着时排着）；按插件限流；没登记的丢弃；点击只能打开 https 或白名单 scheme 的 URL、切换 App、跳回终端；不收要执行的命令、图片路径和原始色值。
- **除防火墙外不碰网络与 shell 环境**：不改 `~/.zshrc` 和系统网络设置；出口探测只请求第三方服务，不碰 Claude / Anthropic 域名；guardd 不要 sudo。
- **密钥不打印，日志不记 IP**（界面上完整显示出口 IP）。测试与文档里的 IP 用 `198.51.100.x`。
- **品牌**：Pip 是原创角色，不用 Grok、Codex、Coucou、Mochi 等别家的名字、形象和音效；代码里用 `Mascot` 前缀。会话行可以用 agent 厂商自己的标志标明是哪家的会话。
- **看不见就不调度**：收起、被遮挡、熄屏、锁屏时停掉动画和计时器。
- **配置与状态文件**：JSON 字段 lowerCamelCase，缺失字段用默认值，未知字段忽略，时间用 ISO 8601。

## 文档

**代码和测试说了算。** 文档只记用户拍板的决定和看代码看不出的原因，不记数字、实现细节和试错历史；小的设计取舍直接写代码，依据放注释。改用户定过的决定先问用户。按任务读：

| 要动什么 | 先读 |
|---|---|
| 任何界面（刘海、卡片、面板、设置页） | `docs/ui.md`「原则」，其余节按需 |
| Pip 的造型、动效、性能 | `docs/mascot.md` |
| 守卫、`guard-state.json`、红卡 | `docs/egress-guard.md` |
| Claude Code 会话、回合、mod、Ghostty 跳转 | `docs/agent-integration.md` |
| 外部插件的格式、`pipctl`、插件装卸（这份是给用户看的，改了行为一起改） | `docs/user-guide.md`「插件」 |
| 防火墙 | `docs/firewall.md`（必读全文） |
| 起名字 | `docs/ubiquitous-language.md` |
| 实机验证、截图、驱动 Claude Code | `docs/dev-notes.md` |

## 命令

- **验收**：`swift build` 零警告，并且 `swift test` 全绿；改了界面文案再加 `scripts/strings.sh --check` 通过。
- `./scripts/run.sh`：打包、装进 `/Applications` 并启动 App（先结束旧实例）；`./scripts/demo.sh done|failed|question|approval|alert|blocks|settings`：实机弹卡、打开设置。它靠分布式通知，本机任何进程都能发，所以只有 DEBUG 构建听（`CONFIG=debug ./scripts/run.sh`）。
- 新增 lint / format 工具或依赖要用户明示同意。

## 提交与汇报

- commit / push 要用户本轮明示；不 amend、不 force-push、不改 git 配置；只暂存本次改动涉及的文件。
- 提交前：对 diff 逐行问「删掉会坏什么」，答不出的删掉或内联，汇报时列出删了什么、改了什么、有争议但保留的行及理由；更新 `HANDOFF.md`（做完的删掉），随同一提交；派一个新的 [`reviewer`](.claude/agents/reviewer.md) 子 agent（不用 fork，只读），给它改动和相关文档审 diff，必须修的（结论错、丢数据、永远卡住、安全、违反硬规则、可能断网）修完再审，至多两轮；仍有问题就停下，交用户定。
- 一个提交装一类相关的改动：同一功能的代码、测试、文档、`HANDOFF.md` 进度一起提交；不相干的类别分开，重构与功能、修复分开。格式：`<type>: <一句话>` + 中文列表正文，type 用 `feat` `fix` `refactor` `test` `docs` `build` `chore`。
- 一律中文汇报（标识符和原文引用除外）：先说结论，再给下一步；结论带依据（`文件:行`、链接或实测），推断标「推断 / 未证实」；前提错了直接指出。动到防火墙、LaunchDaemon / LaunchAgent 按全局 Contract「高影响」档收工。
- skill：磨方案 `grilling`，查资料 `research`，原型 `prototype`，实现 `tdd`，界面 `ui-ux-pro-max`，难 bug `diagnosing-bugs`，起名 `domain-modeling`，改本文件 `writing-for-agents`，换会话 `handoff`（写进 `HANDOFF.md`）。
