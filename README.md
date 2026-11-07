# Pip

Haitao 本机自用的刘海应用（SwiftPM，macOS 14+），没有菜单栏图标。App 显示名叫 Pip，和吉祥物同名；仓库、bundle ID、配置目录和各种 label 仍叫 notchkeeper。在本机开发，用 ad-hoc 临时签名，不需要付费开发者账号。

正在重写：App 层和 Pip 动画会全部重做，另外新增一个一键开关的防火墙。阶段与待办见 `HANDOFF.md`。

## 断网了？防火墙逃生

按顺序试：

1. 什么都不做：开启后 2 分钟内没点「保留」，会自动回滚。
2. 设置 › 防火墙：关掉开关，或「卸载」（跑的就是下面第 3 步的恢复脚本）。都要管理员密码，不需要网络。
3. 终端里执行 **`cd ~/Documents/Projects/notchkeeper && sudo scripts/firewall-rescue.sh`**：卸掉防火墙的守护进程、规则和文件，不需要网络和 App，重复执行没有副作用。
4. 还不行：`sudo scripts/firewall-rescue.sh --disable-pf`，连整个 pf 一起停掉（AirDrop、互联网共享等用到 pf 的功能要重开）。

已经点过「保留」的，重启不能逃生（开机会重新装上规则），先跑第 3 步。

## 现在能用的

- **出口守卫（只监测）**：后台进程 `guardd` 每 5 秒检查一次 Clash、utun 路由和出口 IP，结果写进 `guard-state.json`。App 读这个文件：出口违规时刘海亮红卡，恢复后弹出绿色恢复卡。
- **状态变化提醒**：终端里的 Claude Code 回合结束、需要你介入时，刘海展开弹卡并响提示音，停几秒自动收回；几张卡排队放，红卡挂着时提醒卡盖在上面、放完回到红卡（`docs/ui.md`「卡片」）。
- **外部插件**：一个含 `manifest.json` 的插件文件夹，在设置 › 插件里安装、新建、卸载（或 `pipctl plugin install|uninstall|list`）；脚本用 `pipctl notify`、`pipctl activity`、`pipctl send` 弹卡、报活动。写法见 `docs/user-guide.md`「插件」。自带一个终端插件：设置 › 终端「安装」后，把给出的 `source …` 一行加进 `~/.zshrc`，zsh 里跑了 10 秒以上的命令结束时弹卡。
- **插件设置**（设置 › 插件）：每个插件的开关（关的是提醒，不是判定）、面板里各段的顺序和最多露几行、收起时的常驻插件、链接白名单。
- **会话列表**：鼠标悬停在刘海上会展开面板，显示出口 IP 和正在运行的终端 Claude Code 会话（超过 5 个可滚动）。
- **Pip**：刘海、卡片和设置页里的吉祥物，表情随守卫状态变化。动画交给 Core Animation，空闲时呼吸、眨眼、做小动作，眼睛跟随鼠标（设置里可关）。

## 还没做

- **防火墙**：设计见 `docs/firewall.md`，用法见 `docs/user-guide.md`「防火墙」。设置 › 防火墙里安装、卸载、开关、保留（都要管理员密码；装之前先看会装的全部内容）。终端里装：
  - `scripts/install-firewall.sh [--tunnel <网卡名>] --dry-run`：编译，打印会装的辅助程序哈希、LaunchDaemon 和规则原文，什么都不改；
  - `sudo scripts/install-firewall.sh [--tunnel <网卡名>]`：打印同样的内容，输入 `yes` 才装；
  - 加 `--test-rules --test-address <IPv4>` 装测试规则（只拦去这个地址的流量，去别处的照常）；
  - 升级前先卸载（设置里的「卸载」，或 `sudo scripts/firewall-rescue.sh`）；`sudo scripts/firewall-drill.sh` 装一套什么都不拦的假防火墙来演练恢复脚本。

## 运行

```bash
./scripts/run.sh            # release 编译，打包 Pip.app 并 ad-hoc 签名，结束旧实例，装进 /Applications 后启动
CONFIG=debug ./scripts/run.sh   # debug 构建：只有它听 demo.sh
./scripts/demo.sh done      # 演示：完成卡（还有 failed、question、approval），挂在最近的 Claude Code 会话上，点了跳 Ghostty
./scripts/demo.sh alert     # 演示：红卡（还有 blocks：五种内容块；settings：打开设置，会抢焦点）
```

- **单实例**：同时只会有一个实例在跑，第二个启动后直接退出。界面卡住时用 `pkill -x Notchkeeper` 结束。
- **入口**：
  - 悬停或点击刘海展开面板；
  - 在刘海上右键，有「设置… / 拷贝出口 IP / 退出」；
  - App 已经在运行时，再打开一次会弹出设置；
  - ⌘, 打开设置，⌘Q 退出。
- **配置**：`~/Library/Application Support/Notchkeeper/config.json`。改了会自动热加载，缺的字段用默认值；文件解不开（语法错、字段类型不对）时先用默认设置、不改文件，改好后自动生效。**允许列表默认是空的**，这时守卫只能判 unknown，要先在设置里加上你的出口 IP。
- **日志**：`~/Library/Logs/Notchkeeper/notchkeeper.log`，用本地时间；不记 IP，也不记对话内容。

## 出口守卫 guardd

guardd 是**当前用户的 LaunchAgent**（`com.notchkeeper.guardd`，挂在 `gui/<uid>` 域下），登录后自动启动。它和 App 是两个独立的进程，App 没开时照样检查。

- 不需要 sudo，以 root 身份运行脚本会被拒绝。
- 除了下表列出的文件，什么都不改：不碰 Clash、网络设置、pf、`~/.zshrc`。
- 为什么用 LaunchAgent，不用 SMAppService：后者的审批绑定代码签名，而 ad-hoc 签名每次构建都会变。

```bash
bash scripts/install-guardd.sh --dry-run      # 只打印每一步和要写入的 plist，什么都不改
bash scripts/install-guardd.sh                # 编译 release、安装并加载；可以重复跑，要覆盖的旧文件先带时间戳备份
bash scripts/uninstall-guardd.sh --dry-run    # 只打印
bash scripts/uninstall-guardd.sh              # 卸载：删除 plist 和 bin/guardd，保留日志和状态文件
bash scripts/uninstall-guardd.sh --purge      # 同上，并删除 guardd.log 和 guard-state.json
launchctl print gui/$(id -u)/com.notchkeeper.guardd   # 装完检查
swift run guardd --once                       # 调试：只跑一轮，打印一行结果（不含 IP）
```

| 文件 | 说明 |
|---|---|
| `~/Library/Application Support/Notchkeeper/bin/guardd` | release 二进制 |
| `~/Library/LaunchAgents/com.notchkeeper.guardd.plist` | LaunchAgent，模板在 `Resources/guardd/` |
| `~/Library/Application Support/Notchkeeper/guard-state.json` | 每轮写一次，权限 0600 |
| `~/Library/Logs/Notchkeeper/guardd.log` | stdout / stderr，不含 IP |
| `~/Library/Application Support/Notchkeeper/backup/` | 重装时旧文件的备份；卸载时也保留，不会自动还原 |

- 安装要在已登录的图形会话里跑（ssh 不行），这时 `gui/<uid>` 域才存在。
- 重装时会先 `bootout`，等 guardd 退出（最多 10 秒）后再换文件。
- guardd 收到 SIGTERM 后 exit 0，launchd 不会再拉起它，要等到下次登录。
- 判定规则、状态文件字段、App 怎么显示，见 `docs/egress-guard.md`。

## 模块

每个 target 回答什么问题，见 `Package.swift` 的注释。

## 测试

```bash
swift build                 # 必须零警告
swift test                  # 必须全绿
NOTCHKEEPER_LIVE_PROBES=1 swift test --filter LiveProbes   # 真机只读冒烟，不打印 IP
```

## 文档

用法（含怎么写插件、防火墙拦什么）见 `docs/user-guide.md`；规则和各份文档什么时候读，见 `CLAUDE.md`；接下来要做的见 `HANDOFF.md`。
