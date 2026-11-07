# HANDOFF

最后更新：2026-11-07（守卫并进 App、去掉 guardd；App 图标；`run.sh` 装进 /Applications；开着设置时出现在 Dock）。只放接下来要做的和没解决的；做完的看 `git log`，规则看 `CLAUDE.md` 和 `docs/*`。开工前 `git log --oneline -5` 核对。实机验证的技巧见 `docs/dev-notes.md`。

## 接下来

**新会话从这里开始**：先读下面「第 5 步」和「等用户定」，再读 `docs/firewall.md` 全文（硬规则；§4 规则、§5 `user` 死锁、§7 事故和实测记录）。插件化和第 4 步都做完了（见 `git log`），第 4 步的实机验收用户 10-31 全过。

**和用户协作的规矩（10-31）**：
- 测试时**不能真的断网**、**不能重启这台 Mac**（`docs/firewall.md` §7 开头）。
- 要 root 的命令都由用户在没跑 agent 的终端里自己 `sudo` 执行，执行完 `sudo -k`；agent 不跑 sudo，用户当轮明确让 agent 执行时用 osascript 提权（CLAUDE.md 硬规则，10-31 定）。请用户跑的命令单独放进代码块、写明只读与否：夹在长段落里用户会看不到。
- 不在用户机器上模拟键盘和点击；`demo.sh settings` 会抢焦点，用户在用机器时别用。
- 用户偏好：文档尽量少、先做代码。
- **产品面向普通用户**（10-31）：流程不要求用户读 dry-run、哈希、plist 这类技术输出，确认框一句话说清会发生什么。注释只写最终解释，日期、谁定的、哪轮审查发现写进提交说明（CLAUDE.md 准则 8）。
- **10-31 事故后的约束**：会动 pf 的实机测试不在这台 Mac 上跑，除非用户在当轮明确同意；同意了也先把要做的事给用户看。10-31 晚用户当轮让 agent 跑了演练、恢复脚本和 `firewall-test.sh`（已用掉，下次重新问）。
- agent 提权只能用 `osascript -e 'do shell script "…" with administrator privileges'`（用户在系统密码框输密码；agent 的 shell 没有 tty，sudo 弹不出提示）。提权进程读不了 `~/Documents`（TCC，报 Operation not permitted），读得了 `~/Library/Application Support`（10-31 实测）：要跑的脚本连同仓库 `rsync -a --exclude .build --exclude build --exclude .git ./ /private/tmp/<目录>/` 再跑，命令前加 `cd /private/tmp`；要降回用户身份的脚本（安装、`firewall-test.sh`）在命令前加 `SUDO_USER=ava`，提权进程里没有它。脚本跑在 macOS 自带的 bash 3.2 上，别在 zsh 里验 bash 语法。

**插件化**：App 是「刘海 + Pip + 卡片队列 + 面板」外壳，插件产出同一种 `Card`，各报一个 `PluginStatus`（紧急程度），面板里各占一段（`PanelRow`）。内置插件是出口守卫、Claude Code（id 见 `NotchCore/PluginID.swift`，外部插件不能用）。外部插件写收件箱（`pipctl notify`、`pipctl activity`），`InboxWatcher` 读，`InboxGate` 收，活动归 `ActivityBoard`；插件开没开只在 App 主线程的收件箱回调里判。

**快捷指令（App Intents）：用户 10-31 定先不做**。当时的调研：纯 `swift build` 产不出 `Metadata.appintents`；给 swiftc 加 `-emit-const-values` 和 `-Xfrontend -const-gather-protocols-file <协议清单>`（协议清单抄自 swift-build `SWBCore`），再在 `run.sh` 里手工跑 `xcrun appintentsmetadataprocessor`，/tmp 实测能生成含 intent 和 AppShortcut 的元数据。代价：参数和协议清单都没有文档、Xcode 升级可能坏；要装完整 Xcode；注册进快捷指令要用户在快捷指令 App 里看。出处：swift-build `Sources/SWBCore/SpecImplementations/Tools/SwiftCompiler.swift`、`Sources/SWBApplePlatform/Specs/AppIntentsMetadata.xcspec`。

插件化 10-31 实机验证过：设置 › 插件页（开关、面板顺序和行数、常驻插件、链接白名单的显示）；活动卡原地刷新；红卡挂着时外部卡排着、每个插件只补放最新 3 张、排着的活动卡被刷新；红卡挂着时关守卫红卡立刻撤；插件全关时面板的占位和纯黑刘海。还没试的：
- 面板「打开插件设置」按钮跳到插件页；设置页上移、下移、行数步进、白名单添加和报错（10-31 模拟的键盘输入落到了 Ghostty，之后不再在用户机器上模拟键盘和点击，要用户自己点）。
- 违规中关守卫的确认框：要真违规（`demo.sh alert` 不算违规，不弹确认）。
- 终端插件在 Ghostty 里的两件事：点卡片跳回 shell 所在的终端（按 tty 认）；焦点正停在跑命令的那个终端上时不弹（用户 10-31 定：只按那一个终端算，同窗口别的标签、分屏、别的窗口都照常弹；日志「正看着要跳回的终端」；同目录只开一个终端时才认得出）。10-31 用 AppleScript 在 Ghostty 里开新窗口试时，窗口在命令跑完前没了、原因没查；`script` 伪终端里跑的端到端已通。
- demo 卡上「看 Swift 文档」（https）按钮。

**第 5 步：防火墙**：恢复脚本 → 状态机和辅助程序 → 安装脚本 → 规则重新设计（测试规则下实机通过）→ App 里装卸（卸载就是恢复网络）→ App 开关，代码都做完了；还没做：shielded 造型接线、守卫 violated 时按 §5 换锁图标、不响 Basso，刘海上不显示防火墙状态。按全局 Contract「高影响」档收工。

*10-31 事故*（`docs/firewall.md` §5、§7，记忆 `firewall-pf-freeze-incident`）：`user` 规则让 pf 内核死锁，整机断网、只能重启。本机现在装着正式规则的防火墙、关着（10-31 晚实测后装回的），anchor 是空的。

*10-31 用户定的*（都已写进 `docs/firewall.md` 和 CLAUDE.md 硬规则）：任何规则不写 `user` / `group`；放行改成按目的地址：`<clash>`（节点 + mihomo 的 IP 上游）和 `<cn>`（`Country.mmdb` 里 CN 的网段，让 DIRECT 照常）；**开启时拍快照**（用户目录里的配置和 mmdb 谁都能改，守护进程不读它们），不定时重新解析；守护进程 off 时不跑、trial / on 时每 10 秒一轮（用户要求不做没必要的轮询，on 时仍每 10 秒核对）；测试规则只拦去测试表 `<test>` 的流量；`on` 跨重启保留；设置里能卸载（就是恢复网络，跑恢复脚本）。

*下一步*：
1. 实机还没测：真开机、守护进程崩溃后被 `KeepAlive` 拉起、`-F rules` 后 `pfctl -a … -s Tables` 是否为空。正式规则（整机拦截）一次都没加载过，加载前先问用户。
2. 设置 › 防火墙的装、卸、开关：要用户自己点，见「等实机验证 › 防火墙」。
3. 没做、按需再定（第四轮 reviewer 的建议修里没做的也在这）：订阅换了要关掉再开；`nameserver-policy` 里的上游不读；写成域名的境外 DoH 上游开着防火墙时不通（开启时可以提示）；IPv6 fake-ip 段不查；DNS 上游回得慢但回应时，拍快照没有总时限；`firewall-test.sh` 里的 pfctl 没限时。
4. 复审建议里没做的：提权命令没有超时，同用户进程在检查和 `head` 之间把 /private/tmp 里的脚本换成 FIFO 会让 root 一直等、App 一直转圈（可改成把脚本内容直接放进提权命令）；装、卸、开启成功后弹的脚本输出页对普通用户也没意义，要不要换成一句话（等用户定）；插件安装第二次 rename 失败时旧版留在备份、不自动挪回；`InstalledPluginsSection` 判「替换」用 `fileExists`（跟链接），和 `PluginStore` 的 `lstat` 不一致；安装、卸载的错误文案在设置页和 `pipctl` 各写一份。「保留」只在 App 里按最近的摘要判 `canKeep`，辅助程序的 `keep` 不再核对：摘要说正常之后 10 秒内 Clash 关了 TUN 又点了保留，断网会被锁住（可让 `keep` 拿锁后看一眼最近的摘要）。提权失败时界面显示的是 osascript 的错误文本（带 `execution error:` 前缀；按 TN2065 只含 stderr，没实测）。

*等用户定*（10-31 问过、没回答）：
- 安装脚本把测试地址打到 stdout（两轮审查都认为可保留）。

## 等实机验证

- **插件和 pipctl**（10-31 晚 agent 实测过命令行这边：装、坏图标被拒、升级进备份、自己换自己被拒、`terminal` 被拒、卸载进备份、卸后的卡被丢、`notify` / `send` / `activity` 都收下、参数错和超大退出 64；往收件箱塞随机字节、超长消息、FIFO、符号链接，往插件目录塞乱码 manifest，App 都没崩、逐条记日志）。还要用户自己点、自己看：设置 › 插件的「新建插件…」「安装插件…」、拖文件夹（虚线框）、「卸载…」、「命令行」一段的链接按钮；刘海上卡片和活动长什么样（这个会话没有录屏权限，截不了图）。sheet 和确认框挂在 Form 里的 Section 上，弹不出来就挪到 Form 上（推断）。卸掉一个还有卡排着的插件（红卡挂着时发几张再卸），红卡撤后那些卡不该再弹。旧的 `bin/nk` 10-31 晚已删：删之前开着的终端要重开，终端插件才调得到 `bin/pipctl`。
- **防火墙**（10-31 晚 agent 用 App 的提权路径实测过装、开、保留、关、卸，记在 `docs/firewall.md` §7；现在装着正式规则、关着）。还要用户自己点：设置 › 防火墙的开关、确认框、倒计时、「保留」（试运行出问题时应当灰着）、「卸载…」、「安装…」的确认框；密码框点取消应当什么都不报（取消靠 osascript 报 -128 认，没测过）。正式规则（整机拦截）一次都没开过：第一次开在 Clash 正常时由用户点，网断了什么都别做，等 2 分钟回滚。
- **改名 Pip**：`./scripts/run.sh` 后看设置页标题、关于页、「退出 Pip」、Ghostty 权限弹窗里的名字；Claude Code 里已装的 mod 说明要重装或下次刷新才变成 Pip。
- **装进 /Applications、图标、Dock**（11-07 agent 实测过：`run.sh` 装进 `/Applications/Pip.app`、仓库里不留包、聚焦搜索只找到这一份；App 启动后自动卸掉了本机的 guardd，进程、plist、二进制、状态文件都没了）。还要用户自己看：启动台和访达里的图标（finished 造型）；打开设置时 Dock 出现图标、⌘Tab 切得到、菜单栏有 Pip / 编辑 / 窗口，关掉设置后 Dock 图标消失；之前设置窗口「忽然跑到别的窗口后面」还会不会出现（推断是 accessory App 在密码框、文件选择框这类别的进程的窗口关掉后拿不回焦点，没复现过；再遇到时记下刚点了什么）。**在设置里把「开机启动」关掉再打开一次**：登记的还是 `build/` 下的旧路径。
- **Ghostty 跳转**：同目录开两个 Claude；Claude 套在 tmux 里（应退回按目录认）；工作中的会话多点几次，看转圈字符会不会盖掉标记（推断）。有一次脚本连点两行第二下没切过去、没复现：用户再遇到时记下哪一行、面板开着没有。
- **mod**：开着的会话装上后 `/reload-plugins` 应该开始写（没实测）；后台 agent 崩溃时会不会发带 `agentId` 的 `turn.complete`（不发的话该会话的完成卡被压住到 `/clear`）；后台 agent 在跑时 `/reload-plugins` 可能提前弹完成卡（推断）。`Funk` 出错音没人耳听过。
- **Claude Code 升级后**：重跑 `ClaudeMod/plugins/notchkeeper` 的 `claude plugin test`，在 tmux 里按 `docs/agent-integration.md`「实测」8 重测。
- **卡片流星**：介入卡、出错卡、恢复卡、红卡的颜色（`demo.sh question|approval|failed|alert`）；常驻红卡和减弱动态效果时的淡细边；悬停时流星停住、移开接着走；队列里下一张卡接上时流星从头扫一趟；流星每次 `layout` 重挂动画的 CPU。
- **面板**：减弱动态效果时 Pip 和徽章原地淡入淡出（要切系统设置，先问用户）；finished 的星、sleeping 的 Z 可能顶出面板上沿被裁（推断）；已停止的会话行；左耳 Pip 可能总低着头（推断）；设置页预览可能不跟鼠标（推断）。
- **灵动岛规范**（`docs/ui.md`）：IP 换值时数字滚动、徽章图标替换、VoiceOver 弹卡播报。
- **设置页**：`config.json` 解不开时的横幅（要临时改坏真实配置，先备份）。
- **空闲 CPU**：App 这边 10-31 测过、达标（数在那次提交说明里）。还没做的：WindowServer 那边算不出多少是我们的（disc 栅格化的代价算在哪边没核实），最坏的 working 造型没单独测；Instruments 的 Core Animation 工具看 disc 有没有命中缓存。方法：`run.sh` 后取 pid；循环读 `ioreg -c IOHIDSystem` 的 `HIDIdleTime`，≥ 30s 无人操作才用 `top -l 2 -s 1 -pid <pid> -stats pid,cpu` 取样，采样后仍无人操作才留，攒 60 个求平均，App 和 WindowServer 都量。验收数字见 `docs/mascot.md`「性能验收」。

## 已知问题

- `Look.stale`（守卫没响应，沙漏）守卫并进 App 后没有来源，暂不接线，留着等用户定删不删。
- 违规时 App 重启：红卡在第一轮（几秒）查完后重新弹出、重新响 Basso；以前靠 guardd 的状态文件接续，现在不接续（用户 11-07 接受）。
- **用户定：先不管**：关掉「自动弹红卡」后恢复卡可能在违规期间放出；从等你回答换成等你批准不换卡；Mac 系统灵动岛会和我们抢位置（等 HIG 和 ActivityKit 在 macOS 上开放再定，当时的调研见 `git show f4792ab:docs/research/dynamic-island.md`）。
- 看不见时换了 A→B→A 回到原造型，也会重播进场。
- 滚出可视区的会话行，三蓝点循环照跑（量小）。
- 守卫只查 IPv4，IPv6 直连泄漏看不见；任何 utun 都算在隧道上，开着别的 VPN 时可能看漏；每 5 秒请求 3 个回显服务可能被限流（都是推断）。
- `TerminalPluginTests` 在机器很忙时（紧跟一次全新编译）失败过一次，重跑都绿；推断是真 zsh 子进程的时序，没查。
- mod 写完盘才 `next(e)`，本地写盘挂住会拖住回合（认为不现实，没改）。
- 测试里当普通地址用的 `1.2.3.4`（`GuardCoreTests/EgressGuardTests`、`GuardProbesTests/ProbeTests`，后者还有 `1.1.1.1`）不合 CLAUDE.md「测试里的 IP 用 198.51.100.x」；测解析边界的非法地址、特殊地址不算。

## 建议用的 skill

- `tdd`：每一刀先写会失败的测试、亲眼看红，再在临时副本里改坏实现确认测试会红（本会话每条新行为都这么做过）。
- `research`：动 pf / launchd 行为前先查一手资料（XNU 源码、man page、Mullvad `talpid-core/src/firewall/macos.rs`），**连锁行为一起查**（10-31 只查了 `user root` 能匹配、没查它的内核锁，酿成事故）；结论写进 `docs/firewall.md` §6。Clash Verge 运行时配置的事实（路径、节点格式、mihomo 的 GEOIP）已记在 §4、§6。
- `diagnosing-bugs`：实机测试规则时行为和预期不符就用它，先复现再改。
- `ui-ux-pro-max`：改设置 › 防火墙、做 shielded 造型时用。
- `domain-modeling`：防火墙的新词已进 `docs/ubiquitous-language.md`，再起名先查它。
- `run`：打包启动、`demo.sh` 弹卡、截图。
- `writing-for-agents`：改 CLAUDE.md 时用。
- `handoff`：换会话时更新本文件（就是 `HANDOFF.md`，不另写 `handoff.md`）。
