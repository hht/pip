# Pip User Guide

Pip lives on the MacBook notch, performing four functions:

- **Egress guard**: monitors whether traffic strictly traverses Clash, popping a red card if leaked. Watches only, does not block.
- **Firewall**: blocks non-Clash traffic when enabled. Requires separate installation.
- **Alert cards**: pops cards when Claude Code finishes, hits an error, or waits for your answer. Your own scripts can also pop cards (see "Plugins").
- **Pip**: the small mascot on the left of the notch, conveying status through facial expressions.

If you lose internet connection, check "Firewall Emergency Rescue" at the very top of README.

## Daily Use

- Hover or click the notch to expand the panel: egress IP, Claude Code sessions, active plugin activities.
- Right-click on the notch: Settings, Copy Egress IP, Quit. ⌘, opens Settings.
- Cards auto-collapse after a few seconds. Clicking a card jumps to where it points (terminal, browser, App).
- Logs are located at `~/Library/Logs/Notchkeeper/notchkeeper.log`, never logging IP or conversation contents.

## Egress Guard

Add your egress IP in Settings › Egress Guard first (allowed list defaults to empty). Without adding it, the guard cannot evaluate green or amber: when Clash is healthy, it displays gray "Unknown"; however, if any route bypasses Clash, it evaluates red and pops a red card regardless of the allowed list.

| Color | Meaning |
|---|---|
| Green | Traffic strictly routes through Clash, egress IP in allowed list |
| Amber | Routes through Clash, but egress IP not in allowed list |
| Gray | Unknown: offline, probe timeout; also gray during first few seconds after launch while checking |
| Red | Traffic bypasses Clash |

The red card remains resident until a complete round passes normally (green), followed by a green recovery card. When the allowed list is empty, green cannot be achieved, so the red card will not auto-dismiss: add an egress IP first. Toggling off egress guard in Settings › Plugins disables alerts only; checks continue as usual. The guard checks only while Pip is running and stops upon quitting Pip.

If `config.json` is corrupted by manual editing (banner shows at top of Settings), freshly opened Pip uses defaults with an empty allowed list and cannot evaluate green; auto-recovers once corrected.

## Firewall

**What is blocked when enabled.** All outbound traffic not traversing the Clash tunnel (TUN interface) is dropped, including IPv4 and IPv6. The following categories are allowed:

- Local network and multicast;
- Addresses directly connected by Clash core: proxy nodes, and IP-specified DNS upstreams;
- Domestic IP subnets: calculated from CN subnets in Clash Verge's GeoIP database (`Country.mmdb`).

Thus, when Clash disconnects, the machine can only access domestic and local networks, preventing foreign traffic leaks.

**Common points of confusion:**

- Domestic allow rules match by IP ranges, not by Clash routing rules. Connections routing DIRECT by domain but resolving to overseas IPs (e.g., domestic service using overseas CDN) will fail while firewall is enabled.
- DNS must route through Clash: port 53 to routers, ISPs, and other domestic DNS is blocked; only DNS upstreams specified as IP in Clash config are allowed. Switching to a network where system DNS is set to a router address results in "connected but cannot open web pages"; set system DNS in Clash in this scenario.
- Allowed nodes and domestic subnets are snapshots captured at the moment of enabling. If subscriptions change or node IPs shift, disable and re-enable the firewall.

**Install and Uninstall**: Settings › Firewall.

- Click "Install", confirm, and enter administrator password.
- "Tunnel Interface" specifies Clash's TUN interface name, accepting only `utun` plus numbers (Clash Verge defaults to `utun1024`). Filling in a non-existent interface blocks all external network traffic upon enabling.
- Installed in off state, blocking nothing.
- Uninstalling cleans daemon, rules, and files. If firewall is on, uninstalling releases blocking immediately, usable during network disconnects.

**Enable and Disable**: toggle in Settings › Firewall; enabling, keeping, and disabling require administrator password, preventing silent changes by other processes.

- Turning on starts a 2-minute trial run with a countdown below the toggle. If network breaks, do nothing and wait for automatic rollback; if normal, click "Keep" to stay permanently on across reboots (escaping requires disabling or uninstalling). If issues arise during trial (e.g., tunnel interface missing), "Keep" is disabled; wait for auto-rollback.
- Enabling captures a snapshot of nodes and domestic IP ranges from Clash Verge directory (`~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev`).
- Status line below toggle describes current condition. Rules actively block during trial; "Protected" after "Keep" signifies verified active blocking. "Abnormal" indicates daemon stopped updating status or checks failed (pf disabled, rules swapped), where blocking may be inactive—disable or uninstall. "Tunnel interface missing" indicates rules are active but interface is gone, blocking all external traffic: turn on Clash TUN or disable firewall.
- Terminal control available: `sudo /Library/PrivilegedHelperTools/notchkeeper-firewall enable --clash "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"`, `… keep`, `… disable`, followed by `sudo -k`.

## Claude Code

Settings › Claude Code "Install": installs Pip's built-in mod into Claude Code, popping cards on turn completion or errors. Records how turns end, never conversation contents. Running sessions must be restarted or run `/reload-plugins`.

## Plugins

Egress guard and Claude Code are built-in plugins. Your own scripts connect as **external plugins**: pop cards, or report an ongoing item in the panel ("activity").

A plugin is a **plugin folder** containing at least a `manifest.json` describing its name and icon. Pip only reads this file and executes nothing inside. Cards are emitted by your own scripts calling the `pipctl` CLI tool.

### 30-Second Quickstart

1. Settings › Plugins › "New Plugin…": enter name (source label on card), id, icon, click "Create".
2. In "Command Line" section on the same page, click "Link to ~/.local/bin", allowing direct `pipctl` invocation in terminal (`~/.local/bin` must be in PATH).
3. Run in terminal:

   ```bash
   pipctl notify --plugin backup --title "Backup complete" --outcome done --fact Size=3.2G
   ```

   A card pops under the notch showing your plugin name and icon at top-left.

### Install and Uninstall

| Action | Settings › Plugins | Command Line |
|---|---|---|
| Install a plugin folder | "Install Plugin…" select folder, or drag folder onto page | `pipctl plugin install <folder>` |
| Create empty plugin | "New Plugin…" | Manually create `plugins/<id>/manifest.json` |
| Uninstall | "Uninstall…" next to plugin | `pipctl plugin uninstall <id>` |
| List installed | "Installed" section | `pipctl plugin list` |

- `manifest.json` is validated prior to installation, rejecting invalid files with explanations.
- Plugin folder is copied to `~/Library/Application Support/Notchkeeper/plugins/<id>/`, leaving source untouched. Folder names are arbitrary; installed folder is named after id; symlinks copy target folder contents.
- Installing with an existing id performs an upgrade: old version moves to backup.
- Uninstalling also moves to backup (`~/Library/Application Support/Notchkeeper/backup/plugins/`) without deleting; queued cards and panel activities are dismissed. Built-in terminal plugin is an exception: owned by Pip, uninstalling deletes it.
- Installing and uninstalling require no App restart.
- Toggles, panel order, and row limits configured in Settings › Plugins. Disabling a plugin drops its emitted cards and activities.

### manifest.json

```json
{ "id": "backup", "name": "Backup", "symbol": "externaldrive.badge.checkmark" }
```

| Field | Rules |
|---|---|
| `id` | Starts with lowercase letter or digit, containing only lowercase letters, digits, and hyphens, up to 32 characters. `guard` and `claude` reserved for built-in plugins; `terminal` reserved for bundled terminal plugin |
| `name` | Source displayed on card, up to 24 characters |
| `symbol` | SF Symbol name (look up in Apple "SF Symbols" app), must exist in system |

Other fields are ignored. If an icon is corrupted after install, Pip falls back to a puzzle piece icon and continues accepting cards.

### Popping a Card: `pipctl notify`

```bash
pipctl notify --plugin <id> --title <title> [options]
```

| Option | Purpose |
|---|---|
| `--title` | Title, required |
| `--subtitle` | Subtitle, trailing plugin name |
| `--value` | Short value on right, e.g. "12 s" |
| `--outcome done\|failed\|attention\|info` | Outcome determining color and Pip look, defaults to `info`. Red and green reserved for egress guard, unavailable to plugins |
| `--group <group>` | Queued cards in same group keep only latest before display (e.g. latest result per terminal) |
| `--stale <seconds>` | Drops card if unshown within specified seconds |

**Content Blocks**, at most one per card:

| Option | Displays as |
|---|---|
| `--fact key=value` (repeatable) | Column of facts, up to 4 rows |
| `--check ok\|failed\|pending=text` (repeatable) | Checklist |
| `--text <text>` | Text block supporting newlines, `**bold**`, `_italic_`, `` `code` ``, links/images stripped |
| `--log <text>` | Monospaced log lines |
| `--progress <0…1> [--label <label>]` | Progress bar |

**Click Actions**, at most one:

| Option | When Card Clicked |
|---|---|
| `--open <URL>` | Open link |
| `--activate <bundle ID>` | Switch to App (e.g. `com.apple.Safari`) |
| `--tty <tty> --pid <pid> --cwd <dir>` | Jump to terminal (Ghostty); in zsh use `--tty $TTY --pid $$ --cwd $PWD` |

**Buttons**: `--button Title=URL`, up to two, clicking opens link.

Links default to `https://`. To open external schemes (e.g. `raycast://`), add scheme to Settings › Plugins link whitelist first.

### Reporting Ongoing Tasks: `pipctl activity`

Suitable for downloads, builds, backups that run for a duration. Occupies one row in plugin panel section, removed on completion.

```bash
pipctl activity start  --plugin backup --id nightly --title "Backing up" --progress 0 --alert
pipctl activity update --plugin backup --id nightly --title "Backing up" --progress 0.6 --label "6 / 10 GB"
pipctl activity end    --plugin backup --id nightly --title "Backup complete" --outcome done
```

- `--id` identifies task within the plugin.
- Every step requires `--title`, `end` specifies outcome.
- Adding `--alert` pops a card, subsequent `update` refreshes that card in place without re-alerting.
- Other parameters match `notify`, except `--group` is disallowed.
- At most 5 activities per plugin; activities disappear after 8 hours without `end`.

### Direct JSON Input: `pipctl send`

For parameters that cannot be assembled easily or when writing plugins in other languages, feed complete message JSON via standard input. Missing `v`, `id`, `at` are auto-populated:

```bash
pipctl send <<'EOF'
{
  "plugin": "ci",
  "title": "main build failed",
  "outcome": "failed",
  "block": { "type": "checklist", "items": [
    { "text": "compile", "state": "ok" },
    { "text": "test", "state": "failed" }
  ] },
  "action": { "type": "Action.OpenUrl", "url": "https://example.com/build/42" },
  "buttons": [ { "type": "Action.OpenUrl", "title": "Retry", "url": "https://example.com/build/42/retry" } ]
}
EOF
```

| Field | Description |
|---|---|
| `v` | Format version, currently `1` |
| `plugin`, `title` | Required |
| `id` | UUID, unique per message |
| `at` | Emission timestamp, ISO 8601 (e.g. `date -u +%FT%TZ`) |
| `subtitle`, `value`, `group`, `staleAt` | Same as `notify`; `staleAt` is timestamp |
| `outcome` | `done`, `failed`, `attention`, `info` |
| `block` | `{"type":"TextBlock","text":…,"fontType":"default"\|"monospace"}`, `{"type":"FactSet","facts":[{"title","value"}]}`, `{"type":"checklist","items":[{"text","state"}]}`, `{"type":"progress","value":0.5,"label":…}` |
| `action` | `{"type":"Action.OpenUrl","url":…}`, `{"type":"activate","bundleID":…}`, `{"type":"focusTerminal","tty":…,"pid":…,"cwd":…}` |
| `buttons` | Actions with `title`, up to two |
| `activity` | `{"id":…,"event":"start"\|"update"\|"end","alert":true}`: marks activity event |

Names follow Microsoft Adaptive Cards (`TextBlock`, `FactSet`, `Action.OpenUrl`), with `checklist`, `progress`, `activate`, `focusTerminal` added by Pip. If bypassing `pipctl`: write to `~/Library/Application Support/Notchkeeper/inbox/tmp/`, then `mv` to sibling `new/`; Pip reads only `new/`, preventing partial reads.

### Limits

- At most 6 cards per minute per plugin, dropping extras.
- Messages unshown after 10 minutes are dropped: accumulated while Pip was closed or queued behind red card become obsolete.
- While red card is active, plugin cards queue without covering red card; upon recovery each plugin plays back at most 3 newest cards.
- Max message size 64 KB. Text exceeding length limits is truncated.
- Malformed messages are dropped immediately without crashing Pip.

### Troubleshooting Missing Cards

Check lines starting with "plugin:" in `~/Library/Logs/Notchkeeper/notchkeeper.log`:

| Log | Cause |
|---|---|
| plugin xxx not registered | Not installed, or `manifest.json` id mismatches folder name (`pipctl plugin list` to check) |
| decode failed (…) | Message format error; verify fields if handcrafting JSON |
| rateLimited | Exceeded 6 cards in a minute |
| stale | Expired: `--stale` too short or timestamp inaccurate |

`pipctl` errors explain causes directly. Exit codes: argument error (including `send` payload > 64 KB) is 64; malformed message or plugin folder is 65; file write error (e.g. Pip never launched, inbox missing) is 73.

### Bundled Terminal Plugin

Settings › Terminal "Install", adding the provided `source …` line to `~/.zshrc`. Commands running > 10 seconds in zsh pop cards upon completion, clicking jumps back to terminal; suppressed if focused on that terminal. Exposes command name only, never parameters. Implemented as an external plugin: `pip.zsh` in `plugins/terminal/` invoking `pipctl notify`.

## File Locations

| Path | Purpose |
|---|---|
| `~/Library/Application Support/Notchkeeper/config.json` | Settings; hot-reloads, falls back to defaults on parse error without overwriting file |
| `~/Library/Application Support/Notchkeeper/plugins/` | Installed external plugins |
| `~/Library/Application Support/Notchkeeper/backup/plugins/` | Replaced or uninstalled plugins |
| `~/Library/Application Support/Notchkeeper/inbox/` | Plugin messages, deleted upon reading |
| `~/Library/Application Support/Notchkeeper/bin/pipctl` | CLI tool, updated on each Pip launch |
| `~/Library/Logs/Notchkeeper/` | Pip and egress guard logs |
| `/Library/PrivilegedHelperTools/notchkeeper-firewall`, `/Library/LaunchDaemons/com.notchkeeper.firewall.plist` | Firewall, present only when installed |
