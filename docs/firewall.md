# Firewall (Network Disruption Protection)

Progress in `HANDOFF.md`.

## 1. Objectives

A single toggle: **all protections active when enabled, all protections inactive when disabled**. No granular sub-switches, no per-App filtering.

- **Enable**: all outbound traffic not traversing the Clash tunnel (utun) is dropped, including IPv4 and IPv6, except local network, addresses directly connected by Clash core (nodes, DNS upstreams), and domestic IP subnets. When Clash disconnects, the machine accesses only domestic networks, preventing foreign traffic leaks.
- **Disable**: completely inactive. Egress guard continues monitoring and alerting as usual (`docs/egress-guard.md`).
- **Every state-changing action requires administrator password**: enabling, keeping, disabling prompt system password dialog every time. Arbitrary local processes (including coding agents) cannot silently alter protections.
- **Never terminates processes**, targeting neither Claude nor any other App.

## 2. State Machine

Three states only, recorded in root-owned firewall state file, modifiable by root only. LaunchDaemon and scripts act strictly accordingly.

| State | Rules | How Entered | How Exited |
|---|---|---|---|
| `off` | Unloaded | Initial state after install; disabled (password required); trial expired; discovered as `trial` on boot | Enable (password required) → `trial` |
| `trial(deadline)` | Loaded | Enable (password required) | Keep (password required) → `on`; deadline reached → `off`; boot → `off`; disable (password required) → `off` |
| `on` | Loaded | Clicked "Keep" during trial | Disable (password required); rescue script (uninstalls everything directly) |

Invariants:

- **Rules loaded only in `trial` and `on`.** LaunchDaemon checks firewall state file every round; state `off` unloads rules, never reloading. Thus automatic rollback to `off` ensures rules are never reinstalled.
- **`trial` at boot treated as `off`.** Reboots during trial will not come online with unconfirmed rules.
- **Trial expiration executed by root LaunchDaemon**, independent of App or osascript child processes. Rollback occurs at deadline even after App exits. Daemon runs every 10 seconds during `trial` and `on` (each round idempotent, rollback delayed by ~10s at most), exiting after completing the round returning to `off`, and runs nothing when `off` (user decision, 10-31: no unnecessary polling).
- **Deadline computed via monotonic clock, not wall-clock time.** Backward system clock adjustments during trial (manual or NTP) cannot delay rollback.
- **App trusts fresh status summaries only.** Summary carries `checkedAt`. Summaries indicating `trial` / `on` unupdated for > 30 seconds (3 rounds) evaluate as "abnormal", preventing "protected" display. Triggered when LaunchDaemon is uninstalled, crashed, or rescue script just ran. Summaries indicating `off` ignore freshness: daemon does not run when `off`.
- **No passwordless channels for state changes.** If App as regular user could write a file triggering root action, coding agents could write the same file.

## 3. Safety Baseline: Recoverability Before Blocking

Faulty firewall rules disconnect the entire machine, so recovery mechanisms are mandatory prerequisites (user decision). None of the blocking rules may be written unless all three criteria below are met.

1. **Rescue script first.** `scripts/firewall-rescue.sh` was the very first deliverable, preceding any block rules. It executes in order:
   1. Deletes LaunchDaemon plist and helper tool. Touches files only, never pf: kernel deadlocks in pf (§5) can hang subsequent steps; completing this step guarantees recovery after reboot; with helper removed, daemon cannot start or reinstall rules.
   2. `launchctl bootout system/<label>`, stopping running daemon.
   3. `pfctl -a com.apple/300.Notchkeeper -F rules`, flushing firewall anchor (allow tables lack `persist` and disappear with rules).
   4. If firewall state file records pf enabled token for this boot session, executes `pfctl -X <token>` to release. Errors if pf already stopped are safely ignored.
   5. Deletes remaining files (firewall state file, status summary, lock, allow tables). Equivalent to uninstallation; re-install required to use again. Prints anchor rules (should be empty) and LaunchDaemon status for verification.

   Every `launchctl` / `pfctl` is bounded by timeout (output written to file, abandons wait on timeout): prevents terminal hang, skips subsequent pf steps, prompts reboot.

   Rescue script requirements:
   - Self-contained without dependencies on network, App, or installed firewall scripts. Uses system default `launchctl` and `pfctl` only. Executed by Settings › Firewall "Uninstall" (via admin dialog), or directly via `sudo` in terminal if App cannot launch.
   - Idempotent and repeatable; runs safely without errors or mutations if nothing is installed.
   - **Never executes `pfctl -d` by default.** Forcibly terminates entire pf, invalidating external enabled references (Internet Sharing, AirDrop, Application Firewall, OrbStack, see §6). Executed only when passed `--disable-pf`, as a last resort.

   **Verify before proceeding**: install test anchor and LaunchDaemon with pass-only rules, run rescue script, confirm both removed and absent on reboot. Recorded in §7. Block rules developed only after passing.
2. **Trial run with automatic rollback.** Enabling transitions to `trial` first, with App showing countdown and "Keep" button; returns to `off` if "Keep" not clicked within 2 minutes (analogous to network switch commit confirmed: faulty rules recover automatically without user action).
3. **Emergency rescue instructions in README**, placing rescue script path at the very beginning. Local visibility is essential when disconnected from web resources.

**Emergency rescue procedures** (try in order if rules break connectivity):

1. Do nothing: trial run automatically rolls back at deadline.
2. Toggle off or click "Uninstall" in App. Works locally without internet.
3. In terminal execute `sudo scripts/firewall-rescue.sh`.
4. Last resort: `sudo scripts/firewall-rescue.sh --disable-pf`.

After clicking "Keep" (state `on`), rebooting does not rescue: rules reload on boot; rescue script must be run first.

## 4. Design

Adopted from Mullvad VPN macOS pf firewall (talpid-core `firewall/macos.rs`, commit `33a63e2`), deviating only where necessitated by platform constraints:

| | Mullvad | Our Design | Rationale |
|---|---|---|---|
| Anchor attachment | Private ioctl `DIOCINSERTRULE`, inserting top-level anchor `mullvad` into main ruleset | `pfctl -a com.apple/300.Notchkeeper -f <file>`, attached under `/etc/pf.conf` declared `anchor "com.apple/*"` | Shell scripts cannot invoke private ioctls. `com.apple/*` evaluated alphabetically, `300` ordered after Apple's `200.AirDrop`, `250.ApplicationFirewall` |
| Enabling pf | `DIOCSTART`, recording prior enabled state | `pfctl -E` acquires token and persists to disk, released via `pfctl -X <token>` upon disabling | Reference counted, preserving third-party pf usage |
| Allowing tunnel | Allowed via interface group | Hardcoded interface name, default `utun1024`, configurable | XNU pf lacks interface groups; `on utun` matches nothing |
| Allowing relay | Allows `user root` to relay addresses | Destination allow table `<clash>`: nodes and mihomo DNS upstreams, without `user` | `user` / `group` causes pf kernel deadlock (§5); matched by destination IP only |
| Direct connections | None | Allow table `<cn>`: domestic IP subnets | mihomo DIRECT (`GEOIP,CN,DIRECT`) connects directly from physical interface; breaks without domestic allow rules; these addresses already route direct when Clash active (user decision, 10-31) |
| State table | Keep state on all pass rules | `no state` on loopback and tunnel rules, others keep state | pf state table limited to 10000 entries (local `pfctl -sm`), modifiable only in `/etc/pf.conf`; Clash connections traverse both utun and lo0, doubling state consumption. Both rules allow bidirectional traffic unconditionally, yielding identical outcomes with or without state |
| DNS | Blocks port 53 first | Same: blocks all port 53 outside tunnel not destined to `<clash>`, including local and domestic DNS | User decision: use proxy-configured DNS exclusively |

Rule draft (validated via `pfctl -nf <file>` prior to deployment):

```pf
tun  = "utun1024"
lan4 = "{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 }"
mc4  = "{ 255.255.255.255, 224.0.0.0/24, 239.0.0.0/8 }"
lan6 = "{ fe80::/10, fc00::/7 }"
mc6  = "{ ff01::/16, ff02::/16, ff03::/16, ff04::/16, ff05::/16 }"
table <clash> file "/Library/Application Support/Notchkeeper/clash.table"
table <cn> file "/Library/Application Support/Notchkeeper/cn.table"
pass quick on lo0 no state
pass quick on $tun no state
pass out quick inet6 proto icmp6 icmp6-type { 133, 135, 136 }
pass in  quick inet6 proto icmp6 icmp6-type { 134, 135, 136, 137 }
pass out quick inet proto udp from any port 68 to 255.255.255.255 port 67
pass in  quick inet proto udp from any port 67 to any port 68
pass out quick to <clash>
block return out quick proto { tcp, udp } to any port 53
pass out quick to <cn>
pass out quick to $lan4
pass in  quick from $lan4
pass out quick to $lan6
pass in  quick from $lan6
pass out quick to { $mc4, $mc6 }
block return out quick all
block drop   in  quick all
```

**Privileged Components**:
- Root-owned helper `/Library/PrivilegedHelperTools/notchkeeper-firewall`, compiled from Swift (user decision, 10-31): state machine in pure value target `FirewallCore` tested via `swift test`, `firewalld` handles I/O only. Deadline uses `clock_gettime(CLOCK_MONOTONIC_RAW)`: man page states it is "unaffected by frequency and time adjustments" and continues across sleep (`CLOCK_MONOTONIC` lacks this), resetting on boot where `trial` becomes `off`. Rejected shell `sysctl kern.monotonicclock_usecs`: XNU comments describe it as monotonic and immutable ([clock.c](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/clock.c)), but undocumented. Rescue script remains pure bash without dependencies;
- LaunchDaemon (`RunAtLoad`, `KeepAlive` restarts only on abnormal exit, `ThrottleInterval` 1), accepting tunnel interface in arguments, with `--test-rules` during testing (§7). No `StartInterval`: daemon runs internal loop, running every 10s in `trial` / `on`, exiting normally after completing round returning to `off`; crashes restarted by launchd (trial still rolls back at deadline). launchd defaults to starting same service at most once per 10s; without reducing interval, `kickstart` on enable waits up to 10s (measured 8–9s);
- Enable, keep, disable commands modify files only, restarting daemon via `launchctl kickstart -k` while holding lock (guaranteed not mid-round, killing avoids interrupting between `pfctl -E` and disk write), newly started daemon acquires lock and executes immediately: pf actions decided within round. Failure to flush rules or release references during round returning to `off` prevents daemon exit, retrying next round to prevent orphaned state;
- **Snapshot allow tables upon enabling** (user decision, 10-31): `clash-verge.yaml` and `Country.mmdb` reside in user home, modifiable by any user process; reading them directly in daemon rounds allows passwordless firewall circumvention via file edits. Only enable command (password required) reads Clash Verge runtime config (mihomo `-f` loaded `clash-verge.yaml`), computing tables written to root directory; daemon loads these files only, never reading user directory:
  - `<clash>`: node `server` (domains resolved via system `dig` against plaintext UDP upstreams in `proxy-server-nameserver`, matching mihomo's node resolution path; locally points to mihomo DNS port, `hosts` mapping performed by mihomo; resolution failure or fake-ip answers reject enable), plus mihomo direct DNS upstreams (`default-nameserver`, `nameserver`, `fallback`, `proxy-server-nameserver`, `direct-nameserver`) specified as IP; domain-specified DoH / DoT upstreams pass only if falling within domestic subnets;
  - `<cn>`: all subnets where `country.iso_code` is `CN` in mihomo GEOIP `Country.mmdb` (used by mihomo default `geodata-mode: false` for `GEOIP,CN`); empty subnets reject enable;
  - User directory files treated as external untrusted data: no symlink following, regular files only, bounded file size; mmdb decoding bounds work to file size, rejecting circular nodes or recursive pointers with errors rather than hanging; domain node counts capped, unresponsive DNS upstreams queried once and skipped;
  - Total table entry count capped: pf tables share system limits, preventing exhaustion and capping enable memory and duration;
  - Domestic subnets must resemble a real nation: total size bounded to ≤ 1/8 of IPv4 space, ≤ 2^-14 of IPv6 space, otherwise rejecting enable (prevents corrupted database treating whole internet as CN, rendering rules ineffective);
  - Node IP shifts or subscription updates cause Clash disconnects (fail-safe), recovered by toggling off and on to re-snapshot. No periodic re-resolution (user decision, 10-31: no unnecessary polling);
- Directory `/Library/Application Support/Notchkeeper/`, owner root, permissions 0755. User processes cannot write files inside, preventing status summary forgery.
  - Firewall state file `firewall.state`, root 0600, JSON. Rescue script reads `token` (digits) and `bootSession` (`kern.bootsessionuuid`, refreshed every boot; avoids `kern.boottime` which adjusts with system clock changes (inference), risking false reboot detection; omitted if unknown, skipping release in rescue script). Unparseable files treated as `off` without overwriting; enable/keep rejected until rescue script run;
  - Status summary `firewall-status.json`, root 0644, records mode, production vs test rules, deadline, check results, failed actions, `checkedAt`. Only production rules display "Protected";
  - Allow tables `clash.table`, `cn.table`, root 0644, one address/subnet per line, loaded into pf via `table <…> file` during rule insertion; tables lack `persist` and clear with rules;
  - Lock file `firewall.lock`, root 0600: serializes rounds and commands. Unopenable by regular users, preventing daemon lockups (locking directory itself fails: users can `flock` root 0755 directory, verified in review). Subcommands capped at 5s, ensuring round completion.

LaunchDaemon round sequence:
1. Reads `pfctl -s References`: if our token missing (external `pfctl -d` or reboot), treat reference as absent. On list read failure retain status without `-E` or release; boot session change is exception, see step 2.
2. Boot session differs from firewall state file (reboot occurred): change `trial` to `off`. References kept only if step 1 list readable and contains our token, preventing extra `-E` on boot session read errors; if list unreadable treat as absent: stale token must not pair with new boot session on disk, which rescue script would treat as current boot and attempt to release. Enable/keep commands do not read list; old tokens invalidated across reboot. On boot session read failure reboot state is indeterminate: change `trial` to `off`, retain reference and recorded boot session, reject enable/keep with error.
3. `mode` is not `off`:
   - Load rules only if rules changed (tunnel interface modified) or anchor cleared: reloads reset Evaluations counter to 0, breaking "counter increasing" check;
   - Acquire token via `pfctl -E` if reference absent, persisting immediately. Skip `-E` if firewall state file write fails, preventing duplicate acquisitions;
   - Check: pf enabled, main ruleset contains `anchor "com.apple/*"`, anchor has rules, Evaluations increasing, TUN interface exists.
4. `mode` is `trial` and deadline passed: treat as `off`.
5. `mode` is `off`: flush rules first, then release active pf token.
6. Writes status summary `firewall-status.json` with round `checkedAt` for App display.

**App**:
- Install and uninstall located in Settings › Firewall, installing production rules. Targets regular users who cannot interpret hashes, plists, or pf rules, omitting dry-run display: confirmation states outcome in one sentence, executing as root via admin dialog. App bundle carries helper and two scripts, copied to `/private/tmp` (escalated processes cannot read `~/Documents`); root copies scripts to private temp directory and verifies extraction hash, installer verifies helper hash: stops if replaced post-copy. Uninstall executes rescue script, identical to terminal rescue script. App bundle resides in user space modifiable by same user; hashes protect against "post-copy tampering", not modified bundles. Installer `--dry-run` retained for terminal inspection during development.
- Settings page features one toggle, one status line (`FirewallReading`); trial displays countdown and "Keep" button. "Keep" disabled if trial encounters issues (interface missing, check failed, rules unloaded): keeping in this state locks network disconnection across reboot, whereas waiting for rollback recovers connectivity. Settings window rereads status summary every 2s when visible, pausing when occluded, minimized, or closed.
- Enable, keep, disable invoke installed helper (`enable` / `keep` / `disable`) via `osascript … with administrator privileges`.
- App reads status summary only, never hosting resident privileged code.

**Why not SMAppService + XPC**: App uses ad-hoc signing, altering cdhash on every build. System background item approval breaks, and XPC cannot reliably validate callers. Migrate once developer account is available.

## 5. Known Limitations and Deferred Items

- **Fail-open**: replacing main ruleset via `pfctl -f` or executing `pfctl -d` bypasses our anchor, silently permitting traffic. LaunchDaemon verifies every round (§4); on verification failure, App reports abnormal, suppressing "Protected".
- **Misconfigured TUN name or changed Clash interface**: drops all traffic, failing safely. Status summary must expose "TUN interface missing". Interface name accepts `utun` plus digits only: setting physical interface like `en0` allows physical interface traffic unconditionally while passing checks (noted in review round 1). Setting utun used by external VPN allows that interface's traffic (inference, unhandled).
- **`user` / `group` rules cause pf kernel deadlock requiring reboot** (10-31 real-device incident, §7): rules matching `user` / `group` call `pf_socket_lookup` holding `pf_lock` to query PCB hash table via `in_pcblookup_hash_exists` ([pf.c L4136](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/pf.c#L4136), L5327); TCP timer holds PCB table lock when transmitting packets into pf (`tcp_timer.c:2988`, `tcp_output.c:3665`), creating inverted lock hierarchy. In deadlock, all packets and pf ioctls hang on `pf_lock`, unrecoverable from user space. Rules must never write `user` / `group` (`RulesTests` enforced); responsive pf guarantees rescue script ("Uninstall" in App) always recovers.
- **Allowed domestic subnets and Clash direct addresses**: after Clash disconnects, processes can still connect directly to domestic IPs and `<clash>` addresses. These route direct under active Clash; domain DIRECT connections resolving overseas fail while firewall is on. Snapshot reflects enable moment: subsequent edits to `Country.mmdb` require toggle off/on to apply; pre-modified mmdb loaded as-is (prints table sizes on enable for verification).
- **Virtual machines**: whether OrbStack or vmnet VM traffic is blocked or routes via utun is unverified.
- **State table**: pf state table limited to 10000 entries (local `pfctl -sm`), configurable only in `/etc/pf.conf`. Saturation drops new connections, presenting as network outage. Loopback and tunnel set to `no state` (§4 deviation table); test rule measurements (10-31): active firewall consumes 91 states.
- **Token reuse** (inference): tokens resemble kernel address transforms; after reference invalidated via `pfctl -d`, token value may reassign to third-party references, causing step 1 to release external references on disable. Low probability, unhandled.
- **Unparseable tokens cannot be released**: unparseable `pfctl -E` tokens or immediate reference list mismatches stop token recording, preventing duplicate acquisitions. Orphaned reference remains until reboot or external `pfctl -d`; invisible in status summary.
- **sudo credential cache**: for minutes following terminal sudo, processes in that terminal can execute `sudo pfctl -d` passwordlessly. Avoid using sudo in agent terminals; execute `sudo -k` when finished.
- **DNS** (user decision: proxy-configured DNS only):
  - Rule order: allows tunnel, allows `<clash>`, blocks all other port 53 traffic, allows domestic subnets and local network.
    - Tunnel DNS functions normally, resolved by Clash per proxy configuration.
    - mihomo connects directly to own DNS upstreams (IP upstreams in `<clash>`; DoH/DoT on 443/853 pass if in domestic subnets).
    - Port 53 to routers, LAN, and other domestic DNS blocked, preventing proxy bypass leaks to ISP or routers.
  - Local state (`scutil --dns`): system DNS is public IP, `route -n get` confirms route via `utun1024`, resolving normally on enable.
  - Risk: DHCP networks assigning router IP as system DNS fail resolution while firewall is on ("connected but no web pages"), failing safely. Status summary checks: if system DNS points to LAN address, prompt "System DNS points to LAN, unresolvable while firewall active, configure system DNS in Clash".
  - mDNS (port 5353) and DHCP unaffected.
- **Guard evaluated as violated while firewall enabled** (user decision):
  - Colors unchanged: violated remains red, introducing no new colors or amber borrowing.
  - Requires fresh firewall status summary and all three checks passed (§4). Under these conditions:
    - Red card icon switches from warning to lock;
    - Text reads "Proxy disconnected, firewall blocked external network - No leak";
    - Silent without Basso: no leak occurred, user intervention needed on Clash only.
  - Stale summary or failed checks fall back to standard violated: red card, warning icon, plays Basso.

## 6. References and Real-Device Tests

Verified (macOS 26.5):
- **Interface groups**: XNU `pfi_kif_match` compares pointers only, lacking interface groups. kif binds by name; deleting and recreating `utun1024` automatically rebinds rules ([pf_if.c L224](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/pf_if.c#L224)).
- **`user` / `group` deadlock** (lock dependencies verified in XNU source, complete deadlock cycle inferred; xnu-12377.1.9): matching `user` / `group` invokes `pf_socket_lookup`, querying PCB hash table via `in_pcblookup_hash_exists` on ingress and egress ([pf.c L4136](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/pf.c#L4136), L5327) holding `pf_lock`; TCP timer holds PCB table lock transmitting into pf (`tcp_timer.c:2988`, `tcp_output.c:3665`). External evidence: [PIA desktop PR #107](https://github.com/pia-foss/desktop/pull/107) (identical lock cycle on macOS requiring power cycle), [FreeBSD pf.conf(5) BUGS](https://man.freebsd.org/cgi/man.cgi?query=pf.conf&sektion=5&manpath=FreeBSD+6.0-RELEASE).
- **`block return` and table lookups avoid PCB lock**: `pf_send_tcp` returning RST executes `ip_output` holding `pf_lock`, re-entering pf where `pf_af_hook` skips locking via `NET_THREAD_HELD_PF` ([pf_ioctl.c L4628](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/pf_ioctl.c#L4628)); tables use internal radix trees.
- **mihomo** (Clash Verge bundled v1.19.21): GEOIP without `geodata-mode` queries `Country.mmdb`, GeoLite2 compares lowercased `country.iso_code` ([component/mmdb/reader.go](https://github.com/MetaCubeX/mihomo/blob/Meta/component/mmdb/reader.go)); `/proxies` API omits node addresses ([adapter/outbound/base.go](https://github.com/MetaCubeX/mihomo/blob/Meta/adapter/outbound/base.go)), reading config directly. Tested locally (10-31): subscriptions expanded in `clash-verge.yaml` `proxies` (no `proxy-providers`), nodes written as domains mapped via `hosts`; querying node domains against `dns.listen` returns real addresses, not fake-ip.
- **`com.apple/*`**: local `/etc/pf.conf` is system default, loaded by `com.apple.pfctl` at boot. Clash avoids pf. Local pf active by default: system `pfd` (`com.apple.pfd`) holds reference, remaining after process exit (verified 10-31).
- **token**: pf terminates only when reference count reaches zero; `pfctl -d` forces termination and invalidates all tokens; process exit does not release tokens (verified via `pfd`); tokens lost across reboot (inference) ([pf_ioctl.c L1615](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/pf_ioctl.c#L1615)).
- **osascript administrator privileges**: runs as root (TN2065). Child process survival post-return undocumented, avoiding delegating trial timer to it.
- Mullvad source: [talpid-core/src/firewall/macos.rs @ 33a63e2](https://github.com/mullvad/mullvadvpn-app/blob/33a63e2916adf294d3b4332c4274e2aa1cb1f811/talpid-core/src/firewall/macos.rs)

Root testing (`scripts/firewall-drill.sh`, 10-31):
- `pfctl -E`: empty stdout, token emitted on stderr `Token : <digits>`; `pfctl -X` release reports remaining references.
- `pfctl -s References`: lists PID, process name, token, duration per line.
- Child anchor Evaluations increment even when rules do not match packets.
- `pfctl -a … -sr` on non-existent anchor: exit code 0, empty stdout.
- `pfctl -sm`: `states hard limit 10000`; `pfctl -si` reports `current entries 0` prior to test rules.
- `pfctl -sr` (main ruleset): anchor point is `anchor "com.apple/*" all`; Internet Sharing appends `anchor "com.apple.internet-sharing" all`.
- pfctl commands emit "No ALTQ support in kernel" and "ALTQ related functions disabled" to stderr, non-fatal.

Test rules verification (`scripts/firewall-test.sh`, 10-31):
- `pfctl -s References` reports process name `pfctl` (command executing `-E`), not helper: process names cannot identify our reference.
- Anchor Evaluations increment during idle (20s grew from 17k to 76k): active utun packets prevent false alarms on "counter stagnant".
- `block return` intercepting utun TCP causes `curl` to wait full timeout (8s) before failing rather than failing immediately (inferred: returned RST enters Clash TUN). Direct DNS `dig` times out in 3s.

## 7. Real-Device Acceptance

Requires user manual installation, executed in order:

**Testing must never disrupt network connection (user decision, 10-31)**: whole-machine blocking rules are never loaded during testing. Traffic verification uses "test rules": differs from production by two points only, where all blocks target test table `<test>` (one overseas address), simulating Clash disconnect via non-existent interface name; `curl` and `dig` verify blocking while other traffic passes anchor tail normally. Never test via `nobody` blocks: `user` rules cause kernel deadlocks (§5). Never run `pfctl -d`: invalidates system `pfd` reference.

**Real-device tests touching pf require prior review and turn consent** (post-10-31 incident).

**Machine cannot reboot (user decision, 10-31)**: reboot tests replaced by "simulated reboot": kernel rules and tokens flushed, launchd reloads daemons per `/Library/LaunchDaemons` plists ([launchd(8)](https://keith.github.io/xcode-man-pages/launchd.8.html)). Simulation clears anchor, executes `pfctl -X` on token, alters firewall state file `bootSession`, followed by `launchctl bootout` + `bootstrap`. Real reboot loading daemons from `/Library/LaunchDaemons` relies on Apple docs, untested.

1. **Rescue script**: install test anchor and LaunchDaemon, run rescue script, confirm cleanup; verify boot paths clean (`/etc/pf.conf`, `/etc/pf.anchors/`, `/Library/LaunchDaemons`, launchd `disabled.plist`, `BackgroundItems-v*.btm`); run again on clean machine, verifying steps "skipped".
2. **Trial run**: enable without clicking "Keep", verify automatic shutdown and connectivity restored; simulate reboot during trial, verifying state returns to `off`.
3. **Simulate Clash disconnect under test rules**: test address unreachable (TCP waits timeout under `block return`, §6), `dig @<test_address>` blocked; other traffic unaffected. Switching interface back to `utun1024` restores test address via tunnel.
4. **After disable**: test address restored, anchor empty.
5. **Simulate reboot under `on`**: protection persists.
6. **Fail-open detection**: avoid stopping pf; verification feeds `pfctl` outputs to `swift test` simulating "anchor missing", "counter stagnant", "interface missing".

Record commands and outputs here. Steps 2–5 executed in single run via `sudo scripts/firewall-test.sh` (step 3 "switch to utun1024" reinstalls).

- Step 1 (10-31): `sudo scripts/firewall-drill.sh` installed dummy firewall, manual anchor flush restored by daemon in 11s; `sudo scripts/firewall-rescue.sh` executed bootout, cleared anchor, released reference via `pfctl -X` (`pfd` retained, pf active), deleted files, checks passed, directory removed. Boot paths clear: `/etc/pf.conf` and `/etc/pf.anchors/com.apple` contain Apple anchors only, absent from `/Library/LaunchDaemons` and `disabled.plist`, `BackgroundItems-v16.btm` updated with guardd only. Rerun on clean system: steps 1-3 "skipped", step 4 nothing to delete, all checks passed. **Step 1 passed.**
- Steps 2–5 (10-31, `scripts/firewall-test.sh`, test rules): 41 checks passed. Trial enable returned to off after 125s, rules cleared, reference released, `nobody` restored; non-existent `utun9999` blocked `nobody` external and direct DNS, user/LAN normal; simulated reboot during trial yielded off without acquiring reference; simulated reboot under `on` restored rules and reference; disable emptied anchor and released reference; reinstalling `utun1024` restored `nobody` via tunnel. Failed: `kickstart` in enable, keep, disable timed out at 5s (state written, daemon completed round within seconds), caused by launchd throttling, fixed by adding `ThrottleInterval` 1 to plist (see rerun below).
- Step 1 rerun (evening 10-31, revised rescue script: deletes boot files first, bounded commands): user instructed agent execution, agent escalated via osascript, user entered password, `firewall-drill.sh` followed immediately by `firewall-rescue.sh`. Drill: pf active (`pfd` reference), reference acquired via `-E`, anchor Evaluations grew from 295 to 5468 in 10s, manual flush restored in 11s. Rescue script deleted plist and helper, executed bootout, cleared anchor, released reference via `-X`, deleted files, all checks passed, exit 0, directory removed, network normal. Rerun on clean system: all steps "skipped", exit 0. **Revised Step 1 passed.**
- Steps 2–5 rerun (evening 10-31, revised test rules: blocks test table only, using foreign public DNS; user instructed agent execution, agent escalated via osascript, `SUDO_USER` pointing to user): **all 44 checks passed**. Enable read user Clash Verge directory successfully, snapshot succeeded, test address absent from `<cn>` / `<clash>`; missing interface blocked test address 443 (`nc` waited 8s under `block return`) and 53, other traffic normal; trial returned to off after 121s, rules cleared, reference released; simulated reboot during trial yielded off; simulated reboot under `on` restored rules and reference; disable exited daemon (no polling when off); reinstalling `utun1024` restored test address via tunnel. `kickstart` timeouts resolved (`ThrottleInterval` 1 effective). Idle 20s Evaluations grew from 65k to 138k; state table 39 entries. Cleaned via rescue script, network normal throughout. First run syntax check corrupted table paths under bash 3.2, stopping before installation (nothing modified), resolved with tests added. Untested: real reboot (simulated only), daemon crash recovery via `KeepAlive`, table removal on `-F rules` (`pfctl -s Tables`).
- App escalation path (evening 10-31, user instructed agent execution, osascript escalation, user entered password; command verbatim per `FirewallInstaller`): bundle helper and scripts copied to `/private/tmp`, run as root in clean environment with hash verification. Rescue script uninstalled user's 17:16 production rules (off), installed test rules (test address in documentation range, tunnel `utun1024`) → enable (trial, `<clash>` 6 entries, `<cn>` 8928 subnets, checks passed) → keep (on, Evaluations increasing) → disable (off, daemon exited) → rescue script cleaned (anchor empty, reference released in disable round) → reinstalled production rules per App path (off). Network normal throughout. `--helper` path without `SUDO_USER`, `--yes`, and `env -i` passed under real root. Untested: clicking Cancel in password dialog (`-128`), settings buttons directly, production rules enable.
- **10-31 Incident**: agent ran `firewall-test.sh` via osascript escalation (prior test rules used `user nobody`); ~3 minutes after "simulated reboot under `on`" machine disconnected completely: all `pfctl` (including read-only `-sr`) hung, Clash IPC timed out, rescue script hung at step 2, requiring reboot. After reboot `on` reloaded rules (network normal), cleaned via rescue script. Root cause: kernel deadlock in `user` rules (§5, §6). Remediation: rules omit `user` / `group`; rescue script deletes boot files first, bounding all `launchctl` / `pfctl` with timeouts, preventing terminal hang on pf deadlock and prompting reboot. Step 1 and steps 2–5 reruns passed with revised scripts and test rules, detailed above.
