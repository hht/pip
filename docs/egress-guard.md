# Egress Guard

**Monitors** only: checks whether traffic exclusively traverses the Clash tunnel, drawing results on the notch without blocking anything (for blocking see `docs/firewall.md`). Rule: all traffic except local network must go through the proxy (user decision).

## 1. Three Observations and Verdicts

| Observation | How Obtained | What It Proves |
|---|---|---|
| Clash core | `ClashProbe`: checks if `verge-mihomo` exists in process table (verified name; re-verify if core changes) | Whether traffic could possibly route through Clash |
| Routes | `RouteProbe`: `route -n get` queries several public addresses | Which network interface the kernel sends public traffic to |
| Egress IP | `EgressProbe`: queries several third-party echo services | Which node the echo connection exits from |

`EgressGuard` evaluates in order and takes the first matching condition: any route not using `utun` → `violated`; obtained egress IP not in allowed list → `egressMismatch`; Clash present, all routes use utun, and egress IPs all in allowed list → `healthy`; otherwise → `unknown`.

- **Local network exemption**: probe targets are public addresses only, never probing private subnets.
- **Egress IP is indirect evidence only**: routes prove traffic entered Clash, but cannot prove which node Clash assigned it to; echo services and other Apps might be routed to different nodes, so mismatches only prompt and do not count as violations.
- Excluded approaches (violating repository rules): reading Clash control API, inspecting process TCP peers (fake-ip under TUN mode), echoing IP via Anthropic domains.

## 2. When to Check

**Checked only while App is running** (user decision): checks run inside the App process (`GuardMonitor` in `GuardProbes`), stopping when App exits. Results can only be drawn on the notch, so checking when App is closed has no audience; the previously installed separate background daemon guardd was removed, and App startup uninstalls any legacy instance (`LegacyGuardd`).

- Every 5 seconds per round, 3 concurrent paths with an overall deadline. **Whichever path misses deadline is treated as "no result", never as "good"** (`GuardMonitor.merge`): local probes missing deadline fall back to unknown, never judging violated (no evidence that route was off tunnel).
- **Network path snapshot** (`NetworkPathProbe`, read-only, sends no packets) is used only to distinguish between two unknown reasons: offline (disconnected), probeFailed (no probe result).
- **Stickiness**: once entered violated, can only be cleared by a full round of healthy; network disconnects, timeouts, and egress mismatches never degrade it. Stickiness applies only within the current run: after App restarts, begins at unknown, and if route still bypasses utun, the first round becomes violated again.
- **Before first round finishes** (first few seconds after launch) displays "Checking egress": status dot is gray ring, Pip look unchanged, right ear empty, no cards popped.
- Guard is monitoring itself, not UI animation: checks run every 5 seconds even when collapsed, screen locked, or screen off (exempt from "never schedule when invisible").
- **Allowed list** is retrieved each round from config in App memory, discarding invalid entries; an empty list cannot evaluate egress and results in unknown.

## 3. What Each Round Provides to App

`GuardDisplay` in `GuardCore`: verdict, unknown reason (present only on unknown), `violatedSince` (present only on violated: round when this violation began, invariant while sticky), `egressIP` (egress IPv4 observed in this round; empty if not obtained, never carrying over previous round), and timestamp when check completed. IP appears only in `egressIP`; logs never include IP.

## 4. How It Is Rendered

Decided in `GuardPresentation` and `ViolationAlert` in `NotchCore`; text and colors in App's `GuardPresentation.swift`. Status = Color + Icon + Text:

| Display | Visual |
|---|---|
| healthy | Green |
| egressMismatch | Solid amber |
| unknown (offline, probe timeout, first round incomplete) | Gray hollow ring |
| violated | Red card, plays Basso |
| violated with firewall enabled, status fresh, check passed (Step 5, `docs/firewall.md`) | Red card, lock icon, silent: "Proxy disconnected, firewall blocked external network" |

What appears on the right ear when collapsed is determined by Pip look (`docs/mascot.md` §2).

- **Dismissing red card**: records current `violatedSince`; subsequent rounds of the same violation do not pop again, status dot continues to render (violation red dot); a different `violatedSince` represents a new violation and pops normally. Kept in memory only; App restart pops once again (prefers alerting over silence).
- **Sharing notch with temporary cards**: see `docs/ui.md` "Cards".
- **Recovery**: only violations that popped a red card emit a recovery card upon returning to healthy; intermediate disconnects, probe timeouts, and manual red card dismissals count as the same incident. Reaching healthy from any path dismisses the red card.
