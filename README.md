# Pip

Haitao's personal notch app for macOS (SwiftPM, macOS 14+), without a menu bar icon. App display name is Pip, sharing the same name as the mascot; the repository is `pip`; package, bundle ID, configuration directory, and labels remain notchkeeper. Developed locally with ad-hoc signing, requiring no paid developer account.

Currently undergoing a rewrite: the App layer and Pip animations will be completely redone, along with a new one-click firewall toggle. Progress and todos are in `HANDOFF.md`.

## Lost Connection? Firewall Emergency Rescue

Try in this order:

1. Do nothing: if "Keep" is not clicked within 2 minutes after enabling, it will automatically roll back.
2. Settings › Firewall: turn off the toggle, or click "Uninstall" (runs the rescue script from step 3 below). Both require administrator password, no network needed.
3. In terminal execute **`cd ~/Documents/Projects/pip && sudo scripts/firewall-rescue.sh`**: uninstalls firewall daemon, rules, and files; requires no network or App; repeated execution is safe and idempotent.
4. If still unresolved: `sudo scripts/firewall-rescue.sh --disable-pf`, stopping the entire pf subsystem (AirDrop, Internet Sharing, and other pf-dependent features will need to be re-enabled).

If "Keep" was already clicked, rebooting will not rescue you (rules will reload on startup); run step 3 first.

## Currently Working

- **Egress guard (monitoring only)**: while App is running, checks Clash, utun routes, and egress IP every 5 seconds: shows a red card on the notch when egress is violated, pops a green recovery card when recovered. Stopped when App exits (`docs/egress-guard.md` "When to check").
- **State change alerts**: pops a card under the notch with sound when a Claude Code turn ends or needs your intervention in terminal, auto-collapsing after a few seconds; multiple cards queue up; alert cards layer over resident red card and return to red card when done (`docs/ui.md` "Cards").
- **External plugins**: a plugin folder containing `manifest.json`, installed, created, or uninstalled in Settings › Plugins (or `pipctl plugin install|uninstall|list`); scripts pop cards and report activities via `pipctl notify`, `pipctl activity`, `pipctl send`. Instructions in `docs/user-guide.md` "Plugins". Includes a built-in terminal plugin: after Settings › Terminal "Install", add the provided `source …` line to `~/.zshrc` to pop cards when commands running over 10 seconds finish in zsh.
- **Plugin settings** (Settings › Plugins): toggle for each plugin (disables alerts, not verdicts), panel section order and max rows, resident plugin when collapsed, link whitelist.
- **Session list**: hovering over the notch expands the panel, showing egress IP and running Claude Code terminal sessions (scrollable when exceeding 5).
- **Pip**: mascot in notch, cards, and settings page, whose expression changes with guard state. Animations handled by Core Animation: breathing, blinking, small idle motions, and gaze tracking mouse (toggleable in settings).

## Not Yet Implemented

- **Firewall**: design in `docs/firewall.md`, usage in `docs/user-guide.md` "Firewall". Installed, uninstalled, toggled, and kept in Settings › Firewall (all require admin password; inspect full install content before installing). Terminal installation:
  - `scripts/install-firewall.sh [--tunnel <interface>] --dry-run`: compiles, prints hashes of helper, LaunchDaemon, and rules verbatim without modifying anything;
  - `sudo scripts/install-firewall.sh [--tunnel <interface>]`: prints same content, requires typing `yes` to proceed;
  - Add `--test-rules --test-address <IPv4>` to install test rules (only blocks traffic to this address, others routed as usual);
  - Uninstall before upgrade ("Uninstall" in settings, or `sudo scripts/firewall-rescue.sh`); `sudo scripts/firewall-drill.sh` installs a dummy firewall that blocks nothing to practice the rescue script.

## Running

```bash
./scripts/run.sh            # Release build, packages Pip.app with ad-hoc signing, terminates old instance, installs into /Applications and launches
CONFIG=debug ./scripts/run.sh   # Debug build: only this listens to demo.sh
./scripts/demo.sh done      # Demo: done card (also failed, question, approval) attached to latest Claude Code session, clicking jumps to Ghostty
./scripts/demo.sh alert     # Demo: red card (also blocks: 5 content blocks; settings: opens settings, steals focus)
```

- **Single instance**: only one instance runs at a time; second launch exits immediately. If UI hangs, terminate with `pkill -x Notchkeeper`.
- **Access points**:
  - Hover or click notch to expand panel;
  - Right-click on notch: "Settings… / Copy Egress IP / Quit";
  - Opening the App again while already running brings up Settings;
  - ⌘, opens Settings, ⌘Q quits.
- **Configuration**: `~/Library/Application Support/Notchkeeper/config.json`. Auto hot-reloads on change, missing fields fall back to defaults; if file cannot be decoded (syntax error, wrong type), falls back to defaults without overwriting file, automatically taking effect once repaired. **Allowed list defaults to empty**, where guard reports unknown until you add your egress IP in Settings.
- **Logs**: `~/Library/Logs/Notchkeeper/notchkeeper.log`, using local time; never logs IP or conversation contents.

## Modules

Which problem each target solves is described in comments in `Package.swift`.

## Testing

```bash
swift build                 # Must have zero warnings
swift test                  # Must be all green
NOTCHKEEPER_LIVE_PROBES=1 swift test --filter LiveProbes   # Real-device read-only smoke test, no IP printed
```

## Documentation

Usage (including plugin authoring, firewall blocking scope) in `docs/user-guide.md`; rules and when to read each document in `CLAUDE.md`; next tasks in `HANDOFF.md`.
