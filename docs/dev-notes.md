# Development Notes

Tips and machine-specific pitfalls during real-device verification, screenshots, and driving Claude Code.

- When the whole package fails to build, run core tests first: copy `Sources/<Core>` and `Tests/<Core>Tests` to a temporary package in `/tmp` and run `swift test`. When tests pass green on the first run, intentionally break a few places in a copy to confirm they turn red.
- Driving Claude Code sessions: `tmux -L <name> new-session -d -s x -c <trusted_dir> claude --permission-mode default`, use `send-keys` to send prompts, `Escape` to reject approvals; untrusted directories write only `.key` without `.json`. Use `kill-server` when done; for sessions terminated via `kill -9`, manually delete `<pid>.json` / `.key`. Stopping at "waiting for approval": have it run `touch /tmp/<file>` (`date` is whitelisted); "waiting for answer": have it ask a yes/no question using AskUserQuestion.
- Screenshots: cards and collapsed state `screencapture -x -R 556,0,400,110` (notch centered at top of main display); for looks set up a one-off exhibition in `/tmp` and burst-capture with `screencapture -l <windowID>`. Multiple Pips squinting simultaneously indicates blinking.
- Without cliclick: write a one-off Swift script in `/tmp` using `CGEvent` to move, click, and scroll, returning mouse cursor to original position when finished. Moving mouse (hover) and capturing screenshots are safe; **never simulate clicks or keyboard input**: user is active on this machine, settings window may not be focused, and simulated keys on 10-31 landed in Ghostty. Leave clicks and text inputs to the user.
- Crashes: inspect `~/Library/Logs/DiagnosticReports/Notchkeeper-*.ips`; logs at `~/Library/Logs/Notchkeeper/notchkeeper.log`.
- zsh: `for f in $files` does not split on spaces, use `xargs`; BSD `sed` does not recognize `\b`, use `perl -pi -e`.
- Splitting commits cannot use `git add -p`: use `git hash-object -w` + `git update-index --cacheinfo` to stage partial changes, and `git checkout-index -a --prefix=/tmp/x/` to export index for isolated builds.
- Handoff doc is `HANDOFF.md`, do not write `handoff.md` (macOS filesystem is case-insensitive, overwriting it).
