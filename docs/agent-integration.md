# Agent State: Where to Read, When to Alert

Only integrates with Claude Code (user decision; local Grok only provides `inflightCount` in `desktop-status.json`, unable to distinguish sessions): working, stopped, needs you, plus how the turn ended (done, failed, canceled). Verdicts belong to `AgentCore`; file reading, watching, and process queries belong to outer App layers.

## Two Sources

| Source | Written by | Concerns |
|---|---|---|
| `~/.claude/sessions/<pid>.json` | Claude Code | Active sessions, current state, process liveness, `sessionId` |
| `~/Library/Application Support/Notchkeeper/turns/<sessionId>.json` | Built-in mod ("Notchkeeper mod") | Most recently ended primary turn |

Matched by `sessionId`. **Turn completion is determined solely by mod**; session files only reflect current state: unable to distinguish API errors, Esc, and rejected approvals (all become `idle`), and briefly flashes `idle` when background agents complete or queued messages begin ("Real-Device Testing" 7).

- Uses mod, not settings.json hooks (user decision): hooks spawn a process per event, and `Stop` fails to fire when interrupted via Esc.
- Sessions without mod installed or loaded (untrusted, `--bare`, `--safe-mode`, enterprise policy): display busy/idle and intervention normally, **never pop done or error cards**, and do not guess based on `idle`.
- Do not use `claude agents --json`: coarse like session files, costs 0.4s per run.

### Session Files Read Only These Fields

| Field | Purpose |
|---|---|
| `pid`, `procStart` | Process identity, protects against pid reuse |
| `sessionId` | Matches turn file; concatenated into deletion paths, treated as undecodable if not a valid UUID |
| `kind`, `entrypoint` | Accepts only `interactive` + `cli`, i.e., terminal `claude` (user decision, "Real-Device Testing" 1) |
| `status` | State; newly started sessions without this field are ignored until populated |
| `waitingFor` | Waiting for answer vs. waiting for approval |
| `statusUpdatedAt` | Timestamp when current state began |
| `cwd` | Path shown in session row; used to locate Ghostty window on jump |

`name` is not read: may be inferred from conversation and diverges from Ghostty title.

## States

| `status` | State | Mascot Look (`docs/mascot.md` §2) |
|---|---|---|
| `busy` | working | working; becomes longTurn at 10 minutes |
| `idle`, `shell` | stopped (`shell` = idle with background shell, "Real-Device Testing" 6) | — |
| `waiting` | needsYou | Follows Claude Code's classification ("Real-Device Testing" 3): `permission prompt`, `sandbox request`, `worker request`, `goal proposal` → approval; others and unseen values → question |

- When main turn ends while background agents are running, `status` remains `busy`.
- **Turn**: entire process of Claude responding to a message (user prompt or background agent completion notice), bounded by mod's `turn.start` / `turn.complete`; events with `agentId` are subagents and do not count.
- **Long turn**: working for 10 consecutive minutes since entering working from stopped (including waiting time), resets upon returning to stopped.
- **Mid-turn takeover** (App starts or first observes a file already in working / needsYou): begins from `statusUpdatedAt`; suppresses intervention cards and sounds. Turns ending before App begins observing (compared against `at`) are suppressed; subsequent turn ends alert as normal.

### How Turns End

A turn end occurs when `turnId` changes in turn file:

| `reason` | Last Step `stopReason` | Outcome | Alert |
|---|---|---|---|
| `answer` | not `tool_use` | done | Background agent count 0: done card + `Glass`; > 0: alert after subsequent turn ends when they finish |
| `answer` | `tool_use` | canceled (rejected at prompt) | None |
| `aborted` | — | canceled (Esc) | None |
| `error`, `refusal` | — | failed | Error card + `Funk`, irrespective of background agents |

- Values for `reason` come from Claude Code type definitions `TurnCompleteReason`. Normal responses end with `end_turn` / `max_tokens` / `stop_sequence`; stopping at `tool_use` indicates no further model query followed tool result.
- Queued messages: previous turn alerts normally; mod does not touch turn file when next turn begins, visible even if App reads slightly later.
- If two turns complete between reads on the same session, only the latter is observed (inference).
- Turn file arrives before session file (`/clear` leaves old `sessionId` in sessions): defer recording until session catches up.
- Seen records of old `sessionId` replaced by `/clear` are retained: `--resume <old id>` does not trigger duplicate alerts.
- Two terminals `--resume` same session: alerting process attribution is non-deterministic (rare, unhandled).

### Process Termination

- Query launch time using `proc_pidinfo(PROC_PIDTBSDINFO)`: if query fails or mismatches `procStart`, session is considered dead, removed from list, and suppressed from alerting.
- After `kill -9`, file remains and directory mtime unchanged ("Real-Device Testing" 4), so attach process exit notification (`DispatchSource.makeProcessSource(.exit)`) per pid without polling.

## Notchkeeper Mod

Official Claude Code plugin JS module (enabled by default since 2.1.287), invoked on events (<https://code.claude.com/docs/en/plugins/mods/overview>). Source in `ClaudeMod/` (local marketplace), tested offline via `claude plugin test`. mod API evolves with versions without backward compatibility (user decision): re-run tests and "Real-Device Testing" 8 after upgrading Claude Code.

- **Reports facts only**: `turnId`, `reason`, last step `stopReason`, background agent count at termination, timestamp. Verdict belongs to AgentCore.
- **Writes only at main turn completion, only in interactive sessions** (`isInteractive` from `session.start`); **writes metadata only**, never prompts, answers, or tool parameters.
- **Counting background agents**: on `agent.spawn` with `background: true`, record `agentId` returned by `next(e)`; scratch off when `turn.complete` arrives with matching `agentId` (TaskStop also triggers it).
- **`/clear`** changes `sessionId` without firing `session.start`: clean active turn and background agents on `session.end`, naming files via `$.session.id()`.
- `/reload-plugins` triggers `session.start` again (<https://code.claude.com/docs/en/plugins/mods/create>).
- Built-in guard `cc-plugin-sec-default` on enterprise-managed machines skips some events, excluding `turn.*`, `agent.spawn`, `session.*` (<https://code.claude.com/docs/en/plugins/mods/admin>).

### Turn File

Overwritten completely on every main turn completion. `$.fs.write` is non-atomic: partial reads treated as decode failure and deferred.

```json
{
  "sessionId": "1f324308-f720-447d-ac63-0c87bf340888",
  "ended": { "turnId": "7b7f23e6-5bb8-453f-be40-ed55b22236df", "reason": "answer", "lastStop": "end_turn", "backgroundAgents": 0, "at": 1793349294486 }
}
```

`lastStop` is `null` if no step completed; `at` is epoch milliseconds. App deletes turn file on process exit; cleans unwritten files older than 7 days on launch.

### Install and Uninstall (User Decision)

Single toggle in Settings; App executes `claude` commands without manual config edits:

1. **Install**: copies App's `ClaudeMod/` to `~/Library/Application Support/Notchkeeper/ClaudeMod/`, running `claude plugin install notchkeeper --marketplace <dir> --json`. Claude Code updates `extraKnownMarketplaces` and `enabledPlugins`; plugins in local marketplace load in place (<https://code.claude.com/docs/en/plugins/loading#in-place-and-copied-plugins>).
2. **Uninstall**: `claude plugin marketplace remove notchkeeper` (removes `enabledPlugins`), deletes directory. Leaves empty `"extraKnownMarketplaces": {}`, harmless.
3. **Update**: App replaces directory on launch if present; loads in place, taking effect next session without bumping version. Open sessions require `/reload-plugins` or restart.
4. `claude` searched only in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, ignoring shell config; runs with `DISABLE_AUTOUPDATER=1` (prevents child process holding output pipe), SIGKILL on 60s timeout.

## Jump to Ghostty (User Decision)

Clicking session row or card (outside ×) switches to corresponding Ghostty window, tab, and split. Session is either terminal claude or shell forwarded by terminal plugin (`focusTerminal`).

- Ghostty AppleScript (1.3+): `terminal` exposes `id`, `working directory`, `name` (title), `focus` brings forward; **lacks tty and pid**. Requests permission on first use (`NSAppleEventsUsageDescription`).
- **Terminal identification via tty marker** (modeled after [kovoor/claude-code-notifier](https://github.com/kovoor/claude-code-notifier), adapted to query title via AppleScript):
  1. `sysctl(KERN_PROC_PID)` checks session controlling terminal and parent process chain. Avoid `proc_pidinfo`: direct child of Ghostty is setuid root `login`, returning EPERM.
  2. Non-blocking OSC 2 write to tty sets title to `notchkeeper-<UUID>`.
  3. AppleScript searches for terminal matching title, waiting at most 1 second.
  4. Restores original title (read prior to step 3, stripping control characters). Mandatory writeback: Claude Code rewrites title only on change.
  - Written only when session runs directly in Ghostty terminal (parent chain reaches Ghostty, `login` and session process share tty). tmux and nvim `:terminal` consume OSC 2, which would overwrite their titles.
  - Verifies process identity before write (card holds snapshot): claude verified by launch time; shell lacks launch time, verified by "pid tty matches message tty".
  - Title might be inferred from conversation: marker searched in memory and restored verbatim, never displayed or logged.
  - Known minor risks (inference): OSC insertion mid-frame may glitch one frame; Claude changing status between read and restore overwrites new status; Ghostty hanging > 1s leaves marker until next Claude update.
- **Fallback**: if marker unwritten or timed out, match `working directory` against `cwd`, requiring unique match; otherwise simply bring Ghostty forward. Sessions outside Ghostty also simply activate Ghostty without error.
- **Suppress when focused** (decided 10-31, modeled after Ghostty `notify-on-command-finish = unfocused`): when terminal plugin card arrives, suppresses alert only if Ghostty is frontmost and focus rests on the exact terminal running the command; other tabs, splits, and windows alert as usual. User clicked nothing here, so avoids reading title or writing marker: checks process first (shell tty matches, parent chain reaches Ghostty, excluding VS Code, Terminal.app, tmux), reads only `id` and `working directory`, matching focused terminal directory uniquely; multiple instances in same directory or terminals withholding directory fall back to alerting.
- Apple Events sent only on click and previous check, routed to dedicated queue with 3s `with timeout`, non-blocking to main thread. Terminal id validated as UUID before interpolation.

## Alerts

| Event | Card | Sound |
|---|---|---|
| Turn completed (all background agents finished) | Done card | `Glass` |
| Turn failed | Error card | `Funk` |
| Turn canceled, returns to working | None | None |
| Enters needs you | Needs-you card (auto-collapses, user decision) | `Ping` |
| Exits needs you | Dismisses needs-you card for this session (`docs/ui.md` "Cards" 2) | None |

Queueing and red card interaction detailed in `docs/ui.md` "Cards". Uses system sound effects exclusively (`NSSound(named:)`), with global switch `soundEnabled`. Egress violated plays `Basso`, silent when firewall active (`docs/firewall.md`).

## Real-Device Testing (Claude Code 2.1.296)

Methodology: launch interactive `claude` in tmux, run `claude -p`, spawn subagents, recording metadata fields every 0.1s; use `strings` to inspect file-writing logic in binary. Re-test after upgrading Claude Code.

1. **`kind` does not distinguish `-p`**: derived from `CLAUDE_CODE_SESSION_KIND`, defaulting to `interactive`. `claude -p` also writes files with `entrypoint: sdk-cli`, deleting on exit. Observed entrypoints: `cli`, `sdk-cli`, `sdk-ts`, `sdk-py`, `claude-vscode`, `claude-desktop`, `claude-in-teams`, `local-agent`, `remote`, `ssh-remote`, `bench`.
2. **Subagents do not write separate files.**
3. **Six values for `waitingFor`**: `permission prompt` (unconfigured dialogs default here), `sandbox request`, `worker request`, `goal proposal`, `input needed` (AskUserQuestion, MCP input), `dialog open` (model fallback, settings confirmation). Claude Code categories: first four → permission, `input needed` → question, `dialog open` unclassified. Esc at approval prompt transitions directly to `idle`.
4. **Files persist after `kill -9`**, frozen in pre-crash state; Claude Code cleans up on next session listing. Normal exit removes `.json` and `.key`.
5. Miscellaneous:
   - Time fields are epoch milliseconds; new session writes `idle`; first write lacks `status` and `statusUpdatedAt`, populated subsequently in place.
   - `procStart` is output of `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>`, e.g. `Thu Oct 29 17:54:44 2026` (space-padded single-digit days).
   - Untrusted workspaces produce `.key` without `.json`.
   - State changes **overwritten in place** (inode and directory mtime unchanged): each file requires individual monitoring.
   - `<pid>.<hex>.key` (600) is peer communication token, unread.
6. **`shell`**: binary implements `status === "idle" && hasBackgroundShell ? "shell" : status`, representing an idle variant.
7. **Session files cannot determine turn outcome**: API errors, Esc, rejected approvals all become `idle`; remains `busy` while background agents run, flashing `idle` briefly on agent completion and notice delivery; queued messages also flash `idle`.
8. **mod events** (`claude --plugin-dir <temp_mod>`):
   - Normal answer: `reason: "answer"`, final step `end_turn`.
   - Esc during generation: `reason: "aborted"`.
   - Esc at approval: `reason: "answer"`, final step `tool_use`, tool result `isError: true`.
   - `ANTHROPIC_BASE_URL` pointing to closed port: `reason: "error"`.
   - Background subagent: `agent.spawn` with `background: true`; main turn `turn.complete` arrives first, subagents arrive with `agentId`, followed by notice main turn start and complete. `turn.start` fires only on main turns. TaskStop termination also delivers `turn.complete` with `agentId`.
9. **End-to-end with mod**: normal answer → done; Esc → none; reject approval → intervention card and intervention end only; background agents → single alert at completion; bad `ANTHROPIC_BASE_URL` → error card.
