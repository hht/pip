# 词表

同一个概念只有一个名字：代码用英文列，界面和文档用中文列。只收容易起歧义的词。

| 英文 | 中文 | 含义 |
|---|---|---|
| egress | 出口 | 本机访问公网时对方看到的 IPv4 |
| verdict | 结论 | 守卫一轮的判定：`healthy` / `egressMismatch` / `unknown` / `violated` |
| unknown reason | 未知原因 | 守卫一轮判成 unknown 的原因：offline 断网、probeFailed 探针没结果 |
| stale | 守卫没响应 | Pip 的一个造型（沙漏），暂不接线 |
| checking | 正在检查 | App 启动后守卫还没查完第一轮 |
| session | 会话 | 一个 Claude Code 进程，对应 `~/.claude/sessions/<pid>.json` |
| agent state | agent 状态 | working 工作中 / stopped 已停止 / needsYou 需要你介入 |
| need | 介入类型 | question 等你回答 / approval 等你批准 |
| turn | 回合 | Claude 回应一条消息的全过程，由 mod 的 `turn.start` / `turn.complete` 界定；子 agent 的不算 |
| turn end | 回合结束 | 一个回合结束了（做完、出错、取消）。不是 mod 事件名 `turn.complete` |
| needs-you end | 介入结束 | 会话不再需要你介入（回到工作中、变成已停止、进程没了）。不是「已停止」 |
| turn outcome | 结局 | done 做完 / failed 出错 / canceled 取消 |
| long turn | 干了很久 | 工作中满 10 分钟 |
| agent activity | agent 动态 | 所有会话合起来 agent 这一档该画什么 |
| mod | mod | Claude Code 官方插件里的 JS 模块，源码在 `ClaudeMod/`。不叫「hook」「插件脚本」 |
| mascot | Pip | 吉祥物（用户 10-31 定名，原名盾盾）。代码前缀统一 `Mascot`（用户定），「Pip」只用在界面和文档 |
| app | Pip | App 的显示名，和吉祥物同名（用户 10-31 定）。代码、bundle ID、路径和 label 里仍叫 `Notchkeeper` / `notchkeeper` |
| look | 造型 | Pip 此刻的样子：渐变、眼形、朝向、装饰、右耳指示 |
| motion | 动作 | 叠在造型上的一段关键帧，例如完成跳转 |
| mood / sign | 心情装饰 / 告示 | 心情装饰是角色的一部分，收起时留在左耳；告示表示出了什么事，收起时挪到右耳 |
| ear indicator | 右耳指示 | 收起时右耳的点、告示图标或灰色空心环 |
| plugin / built-in plugin | 插件 / 内置插件 | 往刘海上报状态、发卡片的一块功能。出口守卫、Claude Code 是内置插件，脚本经收件箱接进来的是外部插件 |
| inbox | 收件箱 | 外部插件写消息的目录，App 监听 |
| message | 消息 | 外部插件写进收件箱的一份 JSON，说要弹哪张卡（`PluginCore` 的 `Message`）。不叫「通知」 |
| manifest | 登记 | `plugins/<id>/manifest.json`：外部插件的 id、名字、图标。没登记的插件发来的消息丢掉 |
| plugin folder | 插件文件夹 | 一个外部插件的全部文件：含 `manifest.json`，装进 `plugins/<id>/`（`PluginStore`）；换下来的、卸掉的挪进 `backup/plugins/`。不叫「插件包」 |
| pipctl | 命令行工具 | 脚本发消息、装卸插件用的命令（`pipctl notify`、`pipctl plugin install`），原名 `nk` |
| activity | 活动 | 外部插件报的一件进行中的事（照 ActivityKit 的 start / update / end），在面板里插件那一段占一行。不叫「任务」「进度」 |
| urgency | 紧急程度 | 插件此刻多急：calm 平静 / active 进行中 / attention 要你看 / critical 严重（只有守卫）。代码里是 `PluginStatus.Urgency` |
| lead | 上位 | 收起时 Pip 和右耳显示的那个插件：最急的，都平静时是常驻插件 |
| resident plugin | 常驻插件 | 都平静时收起态显示谁（默认出口守卫，可选不常驻） |
| section | 段 | 面板里一个插件占的那一块；出口守卫的段是顶上的状态区 |
| group | 组 | 消息自带的分组：同一个插件里同组的卡排着时只留最新 |
| block | 内容块 | 卡片第一行下面的一块：正文、日志尾巴、键值、勾叉列表、进度 |
| card | 卡片 | 刘海下弹出的提示：完成卡、出错卡、介入卡、红卡、恢复卡 |
| meteor | 流星 | 卡片弹出时沿边扫一趟的两道光。不叫「流光」「进度条」 |
| firewall mode | 防火墙模式 | off 关闭 / trial 试运行 / on 开启。不叫「保护模式」 |
| trial / keep | 试运行 / 保留 | 开启后先试运行 2 分钟，点「保留」才转 on，没点到时回滚到 off |
| firewall state | 防火墙状态文件 | root 0600 的 `firewall.state`，守护进程照它办事。不是状态摘要 |
| firewall status | 状态摘要 | root 0644 的 `firewall-status.json`，守护进程每轮写给 App 看 |
| check | 核对 | 开着时每轮验证规则真的在拦（pf 开着、anchor 点在、有规则、计数在涨、隧道网卡在） |
| pf reference | 启用引用 | `pfctl -E` 拿到的那一份，凭 token 用 `pfctl -X` 释放。不叫「锁」「句柄」 |
| test rules | 测试规则 | block 只拦去测试表 `<test>` 的流量的规则，测试时用，不真的断网。正式规则叫 production rules |
| allow table | 放行表 | 开启时拍下的快照：`<clash>`（Clash 内核直连的节点和 DNS 上游）和 `<cn>`（国内段）。不叫「白名单」，那是插件链接的 |
| rescue script | 恢复脚本 | `scripts/firewall-rescue.sh`，卸掉防火墙的一切；演练脚本 `firewall-drill.sh` 装假防火墙来练它 |
