# CLAUDE.md — Notchkeeper (App Display Name Pip)

> Current user turn takes priority over any documentation. General MUST NOT and completion criteria are in the global contract (`~/.agents/AGENTS.md`).

A macOS notch app for regular users (SwiftPM, SwiftUI + AppKit, macOS 14+, Simplified Chinese and English, no menu bar icon, appears in Dock only when settings window is open). Four things: **egress guard** (when App is running, monitors whether traffic only goes through Clash, drawn on the notch), **firewall** (one-click toggle), **card alerts** (Claude Code top-level turn completed or needs your intervention), **Pip** (original mascot, conveys status through expressions).

Before starting work read `HANDOFF.md` (what to do next); running and installation in `README.md`; responsibilities of each target in comments of `Package.swift`.

## Principles

1. **Deletion first.** For every line of code, be able to answer "what breaks if this is deleted"; if you cannot answer, delete it (provided readability is not diminished). Functions and types that only forward, only rename, or have only a single caller must be inlined. Do not write code for unencountered requirements.
2. **One module, one problem.** Divide targets and files by independently evolving design decisions, not by View / Model / Manager. The first sentence of a type comment must state which question it answers and what it must not know. Core targets (`GuardCore`, `AgentCore`, `MascotCore`, `NotchCore`, `PluginCore`) are pure value types, do not import SwiftUI / AppKit, and have unidirectional acyclic dependencies; file watching, probes, pf, and UI rendering belong to outer layers.
3. **Right essence, few branches.** Decide data structures, state machines, and invariants first; each concern has exactly one owner; measure before optimizing.
4. **Test-first.** Write a failing test and watch it fail before introducing new behavior, new rules, or fixing bugs. Time, random numbers, filesystem, probes, and process tables must be injected via parameters. For things that cannot be tested automatically (windows, animations, permission alerts, pf), record real-device verification steps and results in the commit message.
5. **Trust boundaries.** Parse external data (sessions, turn files, `config.json`, firewall state, probe responses, `proc_pidpath`) into precise types at boundaries; **"unknown" is a value**, neither healthy nor violated; external data that cannot be parsed is counted and degraded without crashing or overwriting the original file; broken internal invariants trigger `preconditionFailure`.
6. **Solve at the root.** Reproduce and produce root-cause evidence before changing code; special-case ifs, `asyncAfter` delays, `try?` swallowing errors, and text changes are symptom patches. Stop and report if root cause cannot be found.
7. **Consult primary sources and mature implementations first** (Apple documentation, WWDC, agent session formats, open-source peers); design custom solutions on top of them; inspect existing practice before adjusting UI parameters by feel. Verify code relying on external behavior against real versions and cite sources with `// @see`.
8. **Follow Swift community conventions**: [API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/), consistent acronym casing (`IP`, `URL`, `ID`), prefer value types and `enum` state machines, errors use `throws` with concrete types, UI state is mutated only on `@MainActor`, no force-unwrapping of external data. Comments only state the final rationale: why it is done this way, which reference or real-device test version it is based on; dates, who decided, and which review iteration found it belong in commit messages. Each concept has exactly one name, governed by `docs/ubiquitous-language.md`.

**Decision order:** Correctness > Verifiability > Minimalism > Performance > Reusability > Speed.

## Hard Rules

- **Guard monitors only, verdict stops at `GuardCore`**: violated can only be cleared by a full round of healthy; network disconnection and probe timeouts never degrade it; unknown never pops a card. Whether the red card stays up is decided by `NotchCore`'s `ViolationAlert`; reaching healthy from any path dismisses the red card.
- **Firewall security first. Must read `docs/firewall.md` before touching firewall, pf, or LaunchDaemon.** Must write and verify the rescue script on real devices before writing block rules; rescue script must not depend on network, App, or installed firewall scripts; every activation begins with a trial run and automatically rolls back if unconfirmed within 2 minutes; use only own pf anchor, do not modify `/etc/pf.conf`, do not use Network Extension; never write `user` / `group` in rules (causes pf kernel deadlock requiring reboot); Clash runtime config (nodes and DNS upstream addresses) and GeoIP database from Clash Verge are read only once when enabling firewall, never write any Clash files; never touch sudoers; administrator password required for enabling, keeping, and disabling; App never hosts resident privileged code; install/uninstall prompted via user confirmation dialog and admin password in system dialog (can also sudo in terminal during dev), never overwrite existing files; agent modifying rules must show diff to user first; agent only escalates privileges via osascript when explicitly instructed by user in current turn, user enters password in system dialog; never kill processes, do not target any App.
- **Claude Code reads metadata only, never conversation contents.** Session files only take fields required for verdict, never read conversation JSONL; logs and UI never display conversation message bodies, tool parameters, or outputs (external plugin card contents are excluded from this rule, user 10-31); mod can observe body but only writes metadata. Only exception: terminal title read during Ghostty jump is checked in memory for marker and written back verbatim, never displayed or logged.
- **Claude Code**: only alert on top-level turn end (done, failed) and needs your intervention; subagent turns do not count; state decided only by `AgentCore`, sources are session files and turn files written by built-in mod; do not use settings.json hooks; changing Claude Code configuration only via Settings "Install / Uninstall" invoking `claude plugin`; if session or mod API format changes, modify code directly without backward compatibility.
- **Plugins**: egress guard and Claude Code are built-in plugins, toggleable in Settings (toggling turns off alerts, not verdicts; disabling guard during violation requires confirmation). External plugins are trusted but constrained: cards display origin; cannot use red, green, or danger; cannot dismiss or cover red card (`Card` initializer degrades violation/recovered, `CardQueue` keeps them queued while red card is active); rate limited per plugin; unregistered messages discarded; clicks only open https or whitelisted scheme URLs, switch App, jump to terminal; never accept commands to execute, image paths, or raw color values.
- **Never touch network or shell environment except firewall**: do not modify `~/.zshrc` or system network settings; egress probing only queries third-party services, never touches Claude / Anthropic domains; guard requires no sudo.
- **Keys never printed, logs never record IP** (UI displays full egress IP). IPs in tests and docs must use `198.51.100.x`.
- **Brand**: Pip is an original character; do not use names, appearances, or sound effects from Grok, Codex, Coucou, Mochi, etc.; code uses `Mascot` prefix. Session rows may use agent vendor's own logo to indicate vendor.
- **Never schedule when invisible**: stop animations and timers when collapsed, occluded, screen off, or screen locked.
- **Config and state files**: JSON fields lowerCamelCase, missing fields use defaults, unknown fields ignored, timestamps use ISO 8601.

## Documentation

**Code and tests are the authority.** Documentation only records user-confirmed decisions and reasons not obvious from code, not numbers, implementation details, or trial history; small design trade-offs go directly into code with rationale in comments. Consult user before changing user-decided items. Reading guide by task:

| What to touch | Read first |
|---|---|
| Any UI (notch, cards, panel, settings) | `docs/ui.md` "Principles", other sections as needed |
| Pip look, motion, performance | `docs/mascot.md` |
| Guard, red card | `docs/egress-guard.md` |
| Claude Code sessions, turns, mod, Ghostty jump | `docs/agent-integration.md` |
| External plugin format, `pipctl`, plugin install/uninstall (user-facing; update together if behavior changes) | `docs/user-guide.md` "Plugins" |
| Firewall | `docs/firewall.md` (mandatory full read) |
| Naming | `docs/ubiquitous-language.md` |
| Real-device verification, screenshots, driving Claude Code | `docs/dev-notes.md` |

## Commands

- **Acceptance**: `swift build` zero warnings, and `swift test` all green; if UI strings changed, also require `scripts/strings.sh --check` passed; and `scripts/check-chinese.sh` passed (no Chinese characters outside `.xcstrings`).
- `./scripts/run.sh`: bundle, install into `/Applications`, and launch App (terminates old instance first); `./scripts/demo.sh done|failed|question|approval|alert|blocks|settings`: trigger real-device cards, open settings. Uses distributed notifications listened only by DEBUG builds (`CONFIG=debug ./scripts/run.sh`).
- Adding lint / format tools or dependencies requires explicit user consent.

## Commits and Reporting

- commit / push requires explicit confirmation from user in current turn; no amend, no force-push, do not change git config; stage only files involved in current change.
- Before commit: line-by-line ask "what breaks if deleted", delete or inline if unanswered, report what was deleted, what was changed, and controversial lines kept with rationale; update `HANDOFF.md` (delete completed items), include in same commit; dispatch a new [`reviewer`](.claude/agents/reviewer.md) subagent (read-only, no fork), provide changes and relevant docs for diff review, fix must-fix items (wrong conclusion, data loss, permanent hang, security, hard rule violation, potential network disruption) before re-review, maximum two rounds; if issues remain, stop and let user decide.
- One commit per category of related changes: code, tests, docs, and `HANDOFF.md` progress for the same feature committed together; unrelated categories separated, refactoring separated from features/fixes. Format: `<type>: <summary>` + bullet list body in commit message (English). Types: `feat` `fix` `refactor` `test` `docs` `build` `chore`.
- English for repository content, Chinese for chatting with me: state conclusions first, then next steps; conclusions backed by evidence (`file:line`, link, or test run), tag inferences as "inference / unverified"; directly point out false premises. Changes to firewall, LaunchDaemon / LaunchAgent follow global Contract "high-impact" completion criteria.
- Skills: refining plan `grilling`, researching docs `research`, prototyping `prototype`, implementation `tdd`, UI `ui-ux-pro-max`, difficult bugs `diagnosing-bugs`, naming `domain-modeling`, editing this file `writing-for-agents`, session handover `handoff` (written into `HANDOFF.md`).
