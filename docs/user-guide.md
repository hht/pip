# Pip 使用说明

Pip 住在 MacBook 的刘海上，做四件事：

- **出口守卫**：盯着流量是不是全走 Clash，漏了就亮红卡。只看，不拦。
- **防火墙**：开着时把不走 Clash 的流量拦下。要单独安装。
- **提醒卡片**：Claude Code 做完、出错、等你回答时弹卡。你自己的脚本也能弹（见「插件」）。
- **Pip**：刘海左边的小家伙，用表情说现在怎么样。

断网了先看 README 最前面的「防火墙逃生」。

## 日常

- 鼠标悬停或点击刘海，展开面板：出口 IP、Claude Code 会话、各插件正在做的事。
- 在刘海上右键：设置、拷贝出口 IP、退出。⌘, 打开设置。
- 卡片停几秒自动收回。点卡片会跳到它指的地方（终端、网页、App）。
- 日志在 `~/Library/Logs/Notchkeeper/notchkeeper.log`，不记 IP，也不记对话内容。

## 出口守卫

先在设置 › 出口守卫里加上你的出口 IP（允许列表默认是空的）。没加之前守卫判不出绿色和琥珀：Clash 正常时只显示灰色「不知道」；但只要有路由不走 Clash，照样判红、弹红卡，和允许列表无关。

| 颜色 | 意思 |
|---|---|
| 绿 | 流量全走 Clash，出口 IP 在允许列表里 |
| 琥珀 | 走了 Clash，但出口 IP 不在允许列表里 |
| 灰 | 不知道：断网、探测超时；刚打开 Pip 的头几秒还没查完也是灰的 |
| 红 | 有流量没走 Clash |

红卡会一直挂着，直到一整轮检查都正常（绿色）才撤，之后弹一张绿色的恢复卡。允许列表是空的时候判不出绿色，红卡就不会自己撤：先加上出口 IP。设置 › 插件里关掉出口守卫，关的只是提醒，照常检查。守卫只在 Pip 开着时检查，退出 Pip 就不查了。

`config.json` 手改坏了（设置页顶上有横幅）时，刚打开的 Pip 用默认设置，允许列表是空的，同样判不出绿色；改好后自动生效。

## 防火墙

**开着时拦什么。** 没走 Clash 隧道（TUN 网卡）的出站流量一律拦下，IPv4 和 IPv6 都算。下面几类放行：

- 局域网和组播；
- Clash 自己直连的地址：节点，以及它的 DNS 上游里写成 IP 的那些；
- 国内 IP 段：按 Clash Verge 带的 GeoIP 库（`Country.mmdb`）里标成 CN 的网段算。

所以 Clash 一断，这台机器就只能连国内和局域网，流量漏不到境外。

**容易误会的地方：**

- 国内放行是按 IP 段认的，不是按 Clash 的分流规则。一个按域名走 DIRECT、但解析到境外 IP 的连接（比如国内服务用了境外 CDN），开着防火墙时不通。
- DNS 只能走 Clash：去路由器、运营商和其余国内 DNS 的 53 端口都拦，只有 Clash 配置里写成 IP 的 DNS 上游放行。换到一个系统 DNS 被设成路由器地址的网络，会「有网但打不开网页」，这时在 Clash 里设好系统 DNS。
- 放行的节点和国内段，是开启那一刻从 Clash Verge 读出来的快照。换了订阅、节点 IP 变了，关掉再开一次。

**安装和卸载**：设置 › 防火墙。

- 点「安装」确认后输入管理员密码。
- 「隧道网卡」填 Clash 的 TUN 网卡名，只收 `utun` 加数字，Clash Verge 默认是 `utun1024`。填成不存在的网卡，开启后外网会被全部拦掉。
- 装完是关着的，什么都不拦。
- 卸载会清掉守护进程、规则和文件。防火墙开着的话，卸载后立即放开，断网时也用它。

**开、关**：设置 › 防火墙的开关，开启、保留、关闭每次都要管理员密码，别的程序没法悄悄改。

- 打开开关先试运行 2 分钟，开关下面倒计时。网断了什么都不用做，到时自动关掉；没问题就点「保留」，之后一直开着，重启也开着（这时要逃生得先关掉或卸载）。试运行出了问题（比如隧道网卡不在）时「保留」点不了，等它到时自动关掉。
- 开启时从 Clash Verge 的目录（`~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev`）读一次节点和国内 IP 段。
- 开关下面那一行说现在怎么样。试运行时规则已经在拦；「保留」之后写着「已保护」，就是核对过、真的在拦。写着「异常」时，守护进程没在更新状态，或者核对没通过（pf 被停、规则被换掉），这时可能没在拦，关掉或卸载。写着「隧道网卡不在」时，规则都在生效、只差隧道网卡，外网全被拦下：去开 Clash 的 TUN，或者关掉防火墙。
- 终端里也能开关：`sudo /Library/PrivilegedHelperTools/notchkeeper-firewall enable --clash "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"`、`… keep`、`… disable`，用完 `sudo -k`。

## Claude Code

设置 › Claude Code「安装」：给 Claude Code 装上 Pip 自带的 mod，回合做完或出错时弹卡。它只记回合怎么结束，不记对话内容。已经开着的会话要重开，或者运行 `/reload-plugins`。

## 插件

出口守卫和 Claude Code 是内置插件。你自己的脚本可以作为**外部插件**接进来：弹卡片，或者在面板里报一件进行中的事（「活动」）。

一个插件就是一个**插件文件夹**，里面至少有一个 `manifest.json`，说明它叫什么、用什么图标。Pip 只读这个文件，不运行文件夹里的任何东西。发卡片的是你自己的脚本，它调命令行工具 `pipctl`。

### 30 秒上手

1. 设置 › 插件 ›「新建插件…」：填名字（卡上标明来源用）、id、图标，点「新建」。
2. 同一页的「命令行」一段，点「链接到 ~/.local/bin」，终端里就能直接敲 `pipctl`（`~/.local/bin` 要在 PATH 里）。
3. 终端里跑：

   ```bash
   pipctl notify --plugin backup --title "备份完成" --outcome done --fact 大小=3.2G
   ```

   刘海会弹一张卡，左上角标着你的插件名和图标。

### 安装、卸载

| 怎么做 | 设置 › 插件 | 命令行 |
|---|---|---|
| 装一个插件文件夹 | 「安装插件…」选文件夹，或把文件夹拖到这一页上 | `pipctl plugin install <文件夹>` |
| 新建一个空插件 | 「新建插件…」 | 自己建 `plugins/<id>/manifest.json` |
| 卸载 | 插件旁边的「卸载…」 | `pipctl plugin uninstall <id>` |
| 看装了哪些 | 「已安装」一段 | `pipctl plugin list` |

- 装之前会校验 `manifest.json`，不合规的直接拒绝，并告诉你哪里不对。
- 插件文件夹拷进 `~/Library/Application Support/Notchkeeper/plugins/<id>/`，原文件夹不动。文件夹叫什么都行，装进去后按 id 起名；选的是指向文件夹的替身（符号链接）时，拷的是它指向的那个文件夹。
- 已经装着同 id 的插件，再装就是升级：旧版挪进备份。
- 卸载也是挪进备份（`~/Library/Application Support/Notchkeeper/backup/plugins/`），不会删除；它还排着没弹的卡和面板上的活动一起撤掉。自带的终端插件例外：它的目录归 Pip，卸载就是删掉。
- 装好、卸掉都不用重启 Pip。
- 开关、面板里的顺序和行数都在设置 › 插件。插件关掉时，它发来的卡片和活动都会丢掉。

### manifest.json

```json
{ "id": "backup", "name": "备份", "symbol": "externaldrive.badge.checkmark" }
```

| 字段 | 规则 |
|---|---|
| `id` | 小写字母或数字开头，只能有小写字母、数字和连字符，至多 32 个字符。`guard`、`claude` 留给内置插件，`terminal` 是自带的终端插件 |
| `name` | 卡上显示的来源，至多 24 个字 |
| `symbol` | SF Symbol 的名字（在 Apple 的「SF Symbols」App 里查），系统里得有这个图标 |

别的字段会被忽略。装好之后再改坏图标名，Pip 会换成拼图块图标，照样收卡。

### 发一张卡：`pipctl notify`

```bash
pipctl notify --plugin <id> --title <标题> [其余参数]
```

| 参数 | 作用 |
|---|---|
| `--title` | 标题，必填 |
| `--subtitle` | 副标题，跟在插件名后面 |
| `--value` | 右侧的短值，比如「12 秒」 |
| `--outcome done\|failed\|attention\|info` | 结果，决定颜色和 Pip 的表情，默认 `info`。红色和绿色属于出口守卫，插件用不了 |
| `--group <组>` | 同组的卡还没放出来时只留最新一张（比如同一个终端只留最后一次的结果） |
| `--stale <秒>` | 这么多秒内没放出来就不放了 |

**内容块**，一张卡至多一种：

| 参数 | 显示成 |
|---|---|
| `--fact 名=值`（可以写多个） | 一列键值，至多 4 行 |
| `--check ok\|failed\|pending=文字`（可以写多个） | 勾叉列表 |
| `--text <文字>` | 一段文字，可以有换行和 `**粗体**`、`_斜体_`、`` `代码` ``，链接和图片不生效 |
| `--log <文字>` | 等宽的几行日志 |
| `--progress <0…1> [--label <说明>]` | 进度条 |

**点了去哪**，至多一种：

| 参数 | 点卡片时 |
|---|---|
| `--open <URL>` | 打开链接 |
| `--activate <bundle ID>` | 切到那个 App（比如 `com.apple.Safari`） |
| `--tty <tty> --pid <pid> --cwd <目录>` | 跳回那个终端（Ghostty）；zsh 里写 `--tty $TTY --pid $$ --cwd $PWD` |

**按钮**：`--button 标题=URL`，至多两个，点了打开链接。

链接默认只能是 `https://`。要打开别的 App 的链接（比如 `raycast://`），先在设置 › 插件 › 链接白名单里加上这个 scheme。

### 报一件进行中的事：`pipctl activity`

适合下载、构建、备份这类要跑一阵的事。活动在面板里插件那一段占一行，跑完撤掉。

```bash
pipctl activity start  --plugin backup --id nightly --title "备份中" --progress 0 --alert
pipctl activity update --plugin backup --id nightly --title "备份中" --progress 0.6 --label "6 / 10 GB"
pipctl activity end    --plugin backup --id nightly --title "备份完成" --outcome done
```

- `--id` 是你给这件事起的名字，同一个插件里认同一件事。
- 每一步都要 `--title`，`end` 写结局。
- 加了 `--alert` 会弹卡，之后的 `update` 原地刷新这张卡，不再重弹。
- 其余参数和 `notify` 一样，只是不能用 `--group`。
- 一个插件同时至多显示 5 件；一件事 8 小时没有 `end` 就自己消失。

### 直接写 JSON：`pipctl send`

参数拼不出来的，或者用别的语言写插件时，把一整份消息从标准输入交给它。缺 `v`、`id`、`at` 会自动补上：

```bash
pipctl send <<'EOF'
{
  "plugin": "ci",
  "title": "main 构建失败",
  "outcome": "failed",
  "block": { "type": "checklist", "items": [
    { "text": "编译", "state": "ok" },
    { "text": "测试", "state": "failed" }
  ] },
  "action": { "type": "Action.OpenUrl", "url": "https://example.com/build/42" },
  "buttons": [ { "type": "Action.OpenUrl", "title": "重跑", "url": "https://example.com/build/42/retry" } ]
}
EOF
```

| 字段 | 说明 |
|---|---|
| `v` | 格式版本，现在是 `1` |
| `plugin`、`title` | 必填 |
| `id` | UUID，同一个 id 只放一次 |
| `at` | 发出时刻，ISO 8601（比如 `date -u +%FT%TZ`） |
| `subtitle`、`value`、`group`、`staleAt` | 同 `notify` 的参数；`staleAt` 是时刻 |
| `outcome` | `done`、`failed`、`attention`、`info` |
| `block` | `{"type":"TextBlock","text":…,"fontType":"default"\|"monospace"}`、`{"type":"FactSet","facts":[{"title","value"}]}`、`{"type":"checklist","items":[{"text","state"}]}`、`{"type":"progress","value":0.5,"label":…}` |
| `action` | `{"type":"Action.OpenUrl","url":…}`、`{"type":"activate","bundleID":…}`、`{"type":"focusTerminal","tty":…,"pid":…,"cwd":…}` |
| `buttons` | 动作加上 `title`，至多两个 |
| `activity` | `{"id":…,"event":"start"\|"update"\|"end","alert":true}`：有它就是一步活动 |

名字照微软的 Adaptive Cards 起（`TextBlock`、`FactSet`、`Action.OpenUrl`），`checklist`、`progress`、`activate`、`focusTerminal` 是 Pip 自己加的。不想经过 `pipctl` 也行：在 `~/Library/Application Support/Notchkeeper/inbox/tmp/` 写好文件，再 `mv` 到同级的 `new/`，Pip 只读 `new/`，读不到写了一半的文件。

### 限制

- 每个插件每分钟至多弹 6 张卡，多出来的丢掉。
- 消息发出后 10 分钟还没放出来就不放了：Pip 没开时攒下的、红卡挂着时排着的，回来再弹已经没用。
- 红卡挂着时，插件的卡排着，不会盖住红卡；恢复后每个插件只补放最新的 3 张。
- 一条消息至多 64 KB。卡上的字有长度上限，超出部分截断。
- 不合规的消息直接丢掉，Pip 不会因为插件发错东西崩溃。

### 收不到卡时

先看 `~/Library/Logs/Notchkeeper/notchkeeper.log` 里「插件：」开头的行：

| 日志 | 原因 |
|---|---|
| 插件 xxx 没登记 | 没装，或 `manifest.json` 的 `id` 和文件夹名对不上（`pipctl plugin list` 看） |
| 解不开（…） | 消息格式不对；`pipctl` 发的不会这样，手写 JSON 时检查字段 |
| rateLimited | 一分钟里发了 6 张以上 |
| stale | 过期了：`--stale` 太短，或消息里的时刻不对 |

`pipctl` 自己报错时会直接说明原因。退出码：参数不对（包括 `send` 的消息超过 64 KB）是 64；消息或插件文件夹不合规是 65；文件写不进去是 73，比如 Pip 从没启动过、收件箱还不存在。

### 自带的终端插件

设置 › 终端「安装」，把给出的那行 `source …` 加进 `~/.zshrc`。之后 zsh 里跑了 10 秒以上的命令结束时弹卡，点卡片跳回那个终端；你正看着那个终端时不弹。只交出命令名，不带参数。它本身就是一个外部插件的例子：`plugins/terminal/` 里的 `notchkeeper.zsh` 调 `pipctl notify`。

## 文件都在哪

| 位置 | 是什么 |
|---|---|
| `~/Library/Application Support/Notchkeeper/config.json` | 设置；改了自动生效，解不开时先用默认设置、不改文件 |
| `~/Library/Application Support/Notchkeeper/plugins/` | 装好的外部插件 |
| `~/Library/Application Support/Notchkeeper/backup/plugins/` | 换下来的、卸掉的插件 |
| `~/Library/Application Support/Notchkeeper/inbox/` | 插件发来的消息，读完即删 |
| `~/Library/Application Support/Notchkeeper/bin/pipctl` | 命令行工具，Pip 每次启动更新 |
| `~/Library/Logs/Notchkeeper/` | Pip 和出口守卫的日志 |
| `/Library/PrivilegedHelperTools/notchkeeper-firewall`、`/Library/LaunchDaemons/com.notchkeeper.firewall.plist` | 防火墙，装了才有 |
