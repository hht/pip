# Pip

> **Lost connection after turning on Pip's firewall?** Run `sudo /Applications/Pip.app/Contents/Resources/firewall/firewall-rescue.sh` (or `sudo scripts/firewall-rescue.sh` in this repository). Details in [Firewall Emergency Rescue](#lost-connection-firewall-emergency-rescue).

A macOS notch app with an original mascot, Pip. It sits in the MacBook notch and does four things:

- **Egress guard**: while Pip is running, checks every 5 seconds that your traffic only leaves through the Clash tunnel. A red card stays on the notch while traffic bypasses Clash; once it is back (and your egress IP is in the allowed list), a green card replaces it. It only watches, it never blocks.
- **Firewall** (optional, needs an administrator password): one toggle that drops outbound traffic not going through the Clash tunnel, except the local network, the addresses Clash itself connects to (proxy nodes, DNS upstreams), and mainland China IP ranges. When Clash goes down you can still reach domestic sites, but nothing leaks abroad. Exact scope in the [user guide](docs/user-guide.md#firewall).
- **Alert cards**: a card drops from the notch when a Claude Code turn finishes, fails, or waits for your answer or approval. Your own scripts can pop cards too, through external plugins and the `pipctl` command.
- **Pip**: the mascot in the left ear of the notch, showing status through its expressions.

No menu bar icon; Pip appears in the Dock only while Settings is open. UI in English and Simplified Chinese, following the system language.

## Lost Connection? Firewall Emergency Rescue

Only relevant if you installed the firewall. Try in this order:

1. Do nothing: if "Keep" was not clicked within 2 minutes of turning the firewall on, it rolls back by itself.
2. Settings › Firewall: turn the toggle off, or click "Uninstall…". Both ask for the administrator password and need no network.
3. In Terminal run the rescue script. It removes the firewall daemon, rules, and files, needs neither network nor Pip, and is safe to run repeatedly:

   ```bash
   sudo /Applications/Pip.app/Contents/Resources/firewall/firewall-rescue.sh
   # or, from the cloned repository:
   sudo scripts/firewall-rescue.sh
   ```

4. Still offline: add `--disable-pf` to stop the whole pf subsystem (AirDrop, Internet Sharing, and other pf-based features must then be turned back on).

If "Keep" was already clicked, rebooting does not help (the rules load again at startup); run step 3.

## Requirements

- macOS 14 or later. Designed for MacBooks with a notch. On a display without one, nothing shows at rest (no Pip, no status); cards and the panel still drop from the top center.
- Xcode 16 or later, selected with `xcode-select`: the build calls `xcrun xcstringstool` and `iconutil`.
- Per feature:

| Feature | Needs |
|---|---|
| Egress guard, firewall | [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) with TUN mode on |
| Claude Code cards | Claude Code (tested with 2.1.316) run as `claude` in a terminal, installed in `~/.local/bin`, `/opt/homebrew/bin`, or `/usr/local/bin` |
| Click a card or session to jump back to the terminal | [Ghostty](https://ghostty.org) 1.3 or later (other terminals: Pip only brings Ghostty forward) |
| Cards for long-running shell commands | zsh |

**Not using Clash?** If Clash Verge Rev is not installed when Pip first starts, the Egress Guard plugin starts turned off, since without Clash all traffic bypasses the tunnel and the guard would only show a red card. Turn it on later in Settings › Plugins. Turning it off silences its alerts; the checks themselves keep running while Pip is open (see "Privacy").

## Install

There are no prebuilt releases; build from source. The app is signed ad hoc on your machine, so no developer account is needed.

```bash
git clone https://github.com/hht/pip.git
cd pip
./scripts/run.sh
```

`run.sh` builds a release, packages `Pip.app`, installs it into `/Applications`, and launches it. Run it again to update; it quits the old instance first. Updating does not touch an installed firewall: if you use it, click "Uninstall…" and "Install…" in Settings › Firewall after updating.

## First Steps

1. **Egress guard**: Settings › Egress Guard, add the egress IP of your proxy node(s) to the allowed list. Until you do, the guard can only say "Can't verify the egress" (gray), and a red card does not clear by itself once it appears.
2. **Claude Code**: Settings › Claude Code › "Install". This installs a small Claude Code plugin through `claude plugin`; restart sessions that were already running.
3. **Long shell commands** (optional): Settings › Terminal › "Install", then add the `source …` line it shows to `~/.zshrc`. Commands running longer than 10 seconds pop a card when they finish.
4. **Open at login** (optional): Settings › General › "Open at Login".
5. **Firewall** (optional): read "Firewall" in the [user guide](docs/user-guide.md#firewall) first: it explains exactly what gets blocked.

## Everyday Use

- Hover over or click the notch to open the panel: egress IP, running Claude Code sessions, plugin activities. Click a session to jump to its terminal.
- Cards collapse by themselves after a few seconds; several cards queue up. Click a card to go where it points (terminal, browser, app).
- Right-click the notch: Settings…, Copy Egress IP, Quit Pip. Opening Pip again while it is running also opens Settings.
- Pop cards from your own scripts:

  ```bash
  pipctl notify --plugin backup --title "Backup complete" --outcome done
  ```

  `pipctl` works by that name after Settings › Plugins › "Link to ~/.local/bin" (with `~/.local/bin` on your `PATH`). See "Plugins" in the [user guide](docs/user-guide.md#plugins) for creating a plugin, content blocks, buttons, and progress activities.

## Privacy

- **Network**: the guard asks public IP echo services (`api.ipify.org`, `ipinfo.io`, `ifconfig.me`) for your egress IP, about every 5 seconds while Pip is open, even when the guard's alerts are turned off. It never contacts Claude or Anthropic domains. There is no telemetry.
- **Claude Code**: Pip reads only session metadata (state, working directory, how a turn ended), never conversation contents, prompts, or tool output.
- **Logs** (`~/Library/Logs/Notchkeeper/`) never record IP addresses or conversation contents.
- Outside its own folders Pip changes only what you install from Settings: the Claude Code plugin (an entry in `~/.claude/settings.json`), the login item, the `pipctl` link, and the firewall (with your administrator password). It never edits your shell config or network settings.

## Uninstall

1. In Settings: Firewall › "Uninstall…" (if installed), Claude Code › "Uninstall", Terminal › "Uninstall" (then delete the `source …` line from `~/.zshrc`), General › turn off "Open at Login", Plugins › "Remove Symlink" (if you linked `pipctl`).
2. Quit Pip and delete `/Applications/Pip.app`, `~/Library/Application Support/Notchkeeper/`, `~/Library/Logs/Notchkeeper/`, and `~/Library/Preferences/local.hht.notchkeeper.plist`.
3. Optional: remove Pip from System Settings › Privacy & Security › Automation (Ghostty access).

## Documentation

- [User guide](docs/user-guide.md): colors and cards, firewall scope, writing plugins, file locations.
- Design notes: [egress guard](docs/egress-guard.md), [firewall](docs/firewall.md), [Claude Code integration](docs/agent-integration.md), [UI](docs/ui.md), [Pip](docs/mascot.md), [terms](docs/ubiquitous-language.md).

## Development

```bash
CONFIG=debug ./scripts/run.sh   # Debug build; only this build listens to demo.sh
./scripts/demo.sh done          # Demo cards: done, failed, question, approval, alert, blocks; settings opens Settings
swift build                     # Must have zero warnings
swift test                      # Must be all green
NOTCHKEEPER_LIVE_PROBES=1 swift test --filter LiveProbes   # Read-only probe smoke test on this machine, prints no IP
```

- Internal names: the package, executable, bundle ID, config directory, and log directory are still `Notchkeeper`; the app, mascot, repository, Claude Code plugin, and terminal script are `pip`.
- Each target's responsibility is described in `Package.swift`; project rules in `CLAUDE.md`; open work in `HANDOFF.md`.
- Only one instance runs at a time. If the UI hangs: `pkill -x Notchkeeper`.
- Config `~/Library/Application Support/Notchkeeper/config.json` hot-reloads; missing fields use defaults, and a file that cannot be decoded is left untouched while defaults apply until it is fixed.
