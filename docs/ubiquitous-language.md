# Ubiquitous Language

Each concept has exactly one name: code, UI, and documentation follow the English terms below. Only ambiguous terms are listed.

| English | Meaning |
|---|---|
| egress | IPv4 observed by external parties when this Mac accesses the public network |
| verdict | Guard's single-round decision: `healthy` / `egressMismatch` / `unknown` / `violated` |
| unknown reason | Reason why guard judged a round as unknown: offline (disconnected), probeFailed (probes returned no result) |
| stale | Guard is not responding; a mascot look (hourglass), not yet wired up |
| checking | App just launched and guard hasn't completed its first round yet |
| session | A Claude Code process, corresponding to `~/.claude/sessions/<pid>.json` |
| agent state | working / stopped / needsYou |
| need | Intervention type: question (waiting for your answer) / approval (waiting for your approval) |
| turn | The entire process of Claude responding to a message, bounded by mod's `turn.start` / `turn.complete`; subagent turns do not count |
| turn end | A turn ended (done, failed, canceled). Not the mod event name `turn.complete` |
| needs-you end | Session no longer needs your intervention (returned to working, became stopped, process terminated). Not "stopped" |
| turn outcome | done / failed / canceled |
| long turn | Working for 10 consecutive minutes |
| agent activity | What should be drawn for the agent tier across all aggregated sessions |
| mod | JS module inside official Claude Code plugin, source in `ClaudeMod/`. Not called "hook" or "plugin script" |
| mascot | Pip: the mascot (named by user on 10-31, formerly Shieldy/Dundun). Code prefix unified as `Mascot` (user decision); "Pip" only used in UI and docs |
| app | Pip: the display name of the App, same as the mascot (user decision on 10-31). Code, bundle ID, paths, and labels still use `Notchkeeper` / `notchkeeper` |
| look | Mascot appearance at this moment: gradient, eye shape, gaze, decoration, ear indicator |
| motion | Keyframe sequence layered over a look, e.g. jump completion |
| mood / sign | Mood decoration / sign: mood decoration is part of character, stays on left ear when collapsed; sign indicates an event, moves to right ear when collapsed |
| ear indicator | Collapsed state right-ear dot, sign icon, or gray hollow ring |
| plugin / built-in plugin | Feature tier reporting status to the notch and sending cards. Egress guard and Claude Code are built-in plugins; external plugins connect via inbox from scripts |
| inbox | Directory where external plugins write messages, monitored by App |
| message | JSON written by an external plugin into the inbox requesting a card (`Message` in `PluginCore`). Not called "notification" |
| manifest | Registration: `plugins/<id>/manifest.json` containing external plugin id, name, icon. Messages from unregistered plugins are dropped |
| plugin folder | All files of an external plugin: includes `manifest.json`, installed into `plugins/<id>/` (`PluginStore`); replaced or uninstalled plugins move to `backup/plugins/`. Not called "plugin bundle" |
| pipctl | Command-line tool used by scripts to send messages and install/uninstall plugins (`pipctl notify`, `pipctl plugin install`), formerly `nk` |
| activity | An ongoing task reported by an external plugin (following ActivityKit's start / update / end), occupying one row in the plugin section of the panel. Not called "task" or "progress" |
| urgency | How urgent a plugin is right now: calm / active / attention / critical (guard only). Represented as `PluginStatus.Urgency` in code |
| lead | The plugin displayed by Pip and the right ear when collapsed: the most urgent one, or the resident plugin when all are calm |
| resident plugin | Who is displayed in collapsed state when all are calm (defaults to egress guard, can be configured as none) |
| section | Block occupied by a plugin in the panel; the egress guard's section is the top status area |
| group | Message grouping: within the same plugin, queuing cards with the same group keep only the latest |
| block | Content block below the card's first line: body, log tail, key-value facts, checklist, progress |
| card | Prompt popped under the notch: done card, failed card, needs-you card, red alert card, recovery card |
| meteor | Two beams of light sweeping along edges when a card pops up. Not called "glow" or "progress bar" |
| firewall mode | Firewall mode: off / trial / on. Not called "protection mode" |
| trial / keep | Trial run / keep: enters 2-minute trial after turning on, switches to on only when clicking "Keep", rolls back to off if not clicked in time |
| firewall state | Root 0600 `firewall.state` file followed by the daemon. Not status summary |
| firewall status | Root 0644 `firewall-status.json` summary written by daemon every round for App to read |
| check | Verification every round while enabled that rules are actually blocking (pf is on, anchor exists, rules present, packet counters increasing, tunnel interface up) |
| pf reference | Enabled reference obtained via `pfctl -E`, released with `pfctl -X` using token. Not called "lock" or "handle" |
| test rules | Rules where block only intercepts traffic to test table `<test>`, used during testing without actually cutting off the network. Production rules are called production rules |
| allow table | Snapshot taken when turning on: `<clash>` (nodes and DNS upstreams directly connected by Clash core) and `<cn>` (domestic IP ranges). Not called "whitelist", which is used for plugin URLs |
| rescue script | `scripts/firewall-rescue.sh`, uninstalls everything related to firewall; drill script `firewall-drill.sh` installs a dummy firewall to practice it |
