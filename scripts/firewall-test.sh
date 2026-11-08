#!/bin/bash
# Firewall real-device acceptance test (docs/firewall.md §7 Steps 2-5), using test rules only: blocks test address only, normal traffic unaffected.
# Rules contain no user / group rules (§5).
# Usage: sudo scripts/firewall-test.sh <test_address> (run from non-root user via sudo).
# Test address must be an overseas IPv4 with ports 443 and 53 open (e.g. public DNS), absent from CN subnets and Clash nodes.
# Wrapped in curly braces so bash parses full file before execution.
{
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

LABEL="com.notchkeeper.firewall"
ANCHOR="com.apple/300.Notchkeeper"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
HELPER="/Library/PrivilegedHelperTools/notchkeeper-firewall"
SUPPORT="/Library/Application Support/Notchkeeper"
STATE="${SUPPORT}/firewall.state"
STATUS="${SUPPORT}/firewall-status.json"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WEB="https://www.apple.com/library/test/success.html"
ADDR="${1:-}"

[ "$(id -u)" -eq 0 ] || { echo "Must run as root: sudo $0 <test_address>" >&2; exit 1; }
{ [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; } || { echo "Must run via sudo from regular user" >&2; exit 1; }
[[ "${ADDR}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "Usage: sudo $0 <test_address (IPv4)>" >&2; exit 64; }
if scutil --dns | awk '/nameserver\[[0-9]+\]/ { print $3 }' | grep -qxF "${ADDR}"; then
  echo "Test address matches system DNS; testing would disrupt all system resolution. Choose another." >&2; exit 64
fi
USER_HOME="$(dscl . -read "/Users/${SUDO_USER}" NFSHomeDirectory | awk '{ print $2 }')"
CLASH="${USER_HOME}/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"

passed=0
failed=0
started=$(date +%s)
log() { printf '[%4ss] %s\n' "$(( $(date +%s) - started ))" "$*"; }
ok() { log "PASS $*"; passed=$((passed + 1)); }
bad() { log "FAIL $*"; failed=$((failed + 1)); }
expect() {
  if [ "$2" = "$3" ]; then ok "$1: $3"; else bad "$1: expected $2, got $3"; fi
}

status() { plutil -extract "$1" raw -o - "${STATUS}" 2>/dev/null || echo "-"; }
token() { plutil -extract token raw -o - "${STATE}" 2>/dev/null || echo ""; }
rule_count() { pfctl -a "${ANCHOR}" -sr 2>/dev/null | grep -c . ; }
evaluations() { pfctl -a "${ANCHOR}" -vsr 2>/dev/null | awk '/Evaluations:/ { s += $3 } END { print s + 0 }'; }
states() { pfctl -si 2>/dev/null | awk '/current entries/ { print $3 }'; }
listed() {
  if [ -n "$1" ] && pfctl -s References 2>/dev/null | awk 'NF >= 5 { print $(NF-3) }' | grep -qx "$1"; then echo yes; else echo no; fi
}
wait_mode() {
  local i
  for ((i = 0; i < $2; i++)); do
    [ "$(status mode)" = "$1" ] && { echo "${i}"; return 0; }
    sleep 1
  done
  echo "timeout"
  return 1
}

probe() {
  local t0 rc
  t0=$(date +%s)
  sudo -u "${SUDO_USER}" "$@" >/dev/null 2>&1
  rc=$?
  if [ "${rc}" -eq 0 ]; then echo "ok"; else echo "failed(${rc},$(( $(date +%s) - t0 ))s)"; fi
}
target() { probe nc -z -G 8 "${ADDR}" 443; }
target_dns() { probe dig +time=3 +tries=1 "@${ADDR}" www.apple.com; }
web() { probe curl -sS -m 8 -o /dev/null "${WEB}"; }
blocked() { case "$1" in ok) echo "unblocked" ;; *) echo "blocked" ;; esac; }
in_table() { pfctl -q -a "${ANCHOR}" -t "$1" -T test "${ADDR}" >/dev/null 2>&1 && echo yes || echo no; }

simulate_boot() {
  local t
  t="$(token)"
  launchctl bootout "system/${LABEL}" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do launchctl print "system/${LABEL}" >/dev/null 2>&1 || break; sleep 1; done
  pfctl -q -a "${ANCHOR}" -F rules 2>/dev/null
  [ -n "${t}" ] && [ "$(listed "${t}")" = yes ] && pfctl -q -X "${t}" 2>/dev/null
  sed -i '' 's/"bootSession":"[^"]*"/"bootSession":"SIMULATED-BOOT"/' "${STATE}"
  launchctl bootstrap system "${PLIST}"
  sleep 3
}

helper() { "${HELPER}" "$@" || bad "notchkeeper-firewall $1 exit code $?"; }
enable() { helper enable --clash "${CLASH}"; }

install_rules() {
  local out
  "${REPO}/scripts/firewall-rescue.sh" >/dev/null 2>&1
  if ! out="$(echo yes | "${REPO}/scripts/install-firewall.sh" --test-rules --test-address "${ADDR}" --tunnel "$1" 2>&1)"; then
    printf '%s\n' "${out}" | sed 's/^/    | /'
    bad "Installation --tunnel $1 failed (output above)"
    return 1
  fi
  wait_mode off 15 >/dev/null || { bad "No status summary within 15s of install"; return 1; }
  expect "After install --tunnel $1: mode" off "$(status mode)"
  expect "After install: anchor rule count" 0 "$(rule_count)"
}

log "== 0. Preparation: cleanup via rescue script, install test rules --tunnel utun9999"
log "Initial pf: $(pfctl -s info 2>/dev/null | sed -n 's/^Status: \([A-Za-z]*\).*/\1/p'), states $(states), limit $(pfctl -sm 2>/dev/null | awk '$1 == "states" { print $4 }')"
install_rules utun9999 || { log "Install failed, stopping"; exit 1; }
expect "Baseline: target reachable when off" ok "$(target)"
expect "Baseline: web reachable when off" ok "$(web)"

log "== 1. Trial: target blocked, web normal, auto-rollback at deadline"
enable
enabled_at=$(date +%s)
log "Waited $(wait_mode trial 15)s to enter trial"
expect "After enable: mode" trial "$(status mode)"
expect "After enable: rule scope" testTable "$(status scope)"
expect "Test address absent from cn table" no "$(in_table cn)"
expect "Test address absent from clash table" no "$(in_table clash)"
if [ "$(in_table cn)" = yes ] || [ "$(in_table clash)" = yes ]; then helper disable; log "Test address present in allow table, stopping"; exit 1; fi
expect "After enable: anchor has rules" yes "$([ "$(rule_count)" -gt 0 ] && echo yes || echo no)"
t="$(token)"
expect "After enable: token in state file" yes "$([ -n "${t}" ] && echo yes || echo no)"
expect "After enable: token in reference list" yes "$(listed "${t}")"
log "INFO Our line in reference list: $(pfctl -s References 2>/dev/null | awk -v t="${t}" 'NF >= 5 && $(NF-3) == t { $1 = ""; print }')"
r="$(target)"; expect "Target connection (tunnel missing, expected blocked)" blocked "$(blocked "${r}")"; log "INFO nc: ${r}"
r="$(target_dns)"; expect "Target port 53 (expected blocked)" blocked "$(blocked "${r}")"; log "INFO dig: ${r}"
expect "Web reachable (unaffected)" ok "$(web)"
expect "Check: pf enabled" true "$(status check.pfEnabled)"
expect "Check: anchor point present" true "$(status check.anchorPointPresent)"
expect "Check: tunnel present (utun9999 absent, expected false)" false "$(status check.tunnelPresent)"
e1="$(evaluations)"; s1="$(states)"; sleep 20; e2="$(evaluations)"
log "INFO Idle 20s Evaluations: ${e1} → ${e2}; status evaluationsGrowing=$(status check.evaluationsGrowing)"
log "INFO State table: ${s1} entries"
log "Awaiting trial expiration (120s from enable)..."
wait_mode off 150 >/dev/null
expect "Rollback: mode" off "$(status mode)"
log "INFO Enable to off took $(( $(date +%s) - enabled_at ))s (expected 120-135s)"
expect "After rollback: anchor rule count" 0 "$(rule_count)"
expect "After rollback: token released" no "$(listed "${t}")"
expect "After rollback: target reachable" ok "$(target)"

log "== 2. Simulated reboot during trial → off"
enable
wait_mode trial 15 >/dev/null
simulate_boot
wait_mode off 15 >/dev/null
expect "After simulated boot: mode" off "$(status mode)"
expect "After simulated boot: anchor rule count" 0 "$(rule_count)"
expect "After simulated boot: no reference re-acquired" "" "$(token)"
expect "After simulated boot: target reachable" ok "$(target)"

log "== 3. Enable and keep → on; simulated reboot under on; disable"
enable
wait_mode trial 15 >/dev/null
helper keep
expect "After keep: mode" on "$(wait_mode on 15 >/dev/null; status mode)"
r="$(target)"; expect "on: target connection" blocked "$(blocked "${r}")"
simulate_boot
sleep 8
expect "Simulated boot under on: mode" on "$(status mode)"
expect "Simulated boot under on: rules restored" yes "$([ "$(rule_count)" -gt 0 ] && echo yes || echo no)"
t="$(token)"
expect "Simulated boot under on: reference re-acquired" yes "$(listed "${t}")"
r="$(target)"; expect "Simulated boot under on: target connection" blocked "$(blocked "${r}")"
expect "Simulated boot under on: web reachable" ok "$(web)"
helper disable
wait_mode off 15 >/dev/null
expect "After disable: mode" off "$(status mode)"
expect "After disable: anchor rule count" 0 "$(rule_count)"
expect "After disable: token released" no "$(listed "${t}")"
expect "After disable: target reachable" ok "$(target)"
sleep 2; expect "After disable: daemon exited" no "$(launchctl print "system/${LABEL}" 2>/dev/null | grep -q 'state = running' && echo yes || echo no)"

log "== 4. Reinstall as utun1024: target reachable via tunnel"
install_rules utun1024
enable
wait_mode trial 15 >/dev/null
expect "utun1024: target reachable (allowed via tunnel)" ok "$(target)"
expect "utun1024: check tunnelPresent" true "$(status check.tunnelPresent)"
r="$(target_dns)"; expect "utun1024: target port 53 (allowed via tunnel)" ok "${r}"
helper disable
wait_mode off 15 >/dev/null
expect "After disable: mode" off "$(status mode)"
expect "After disable: anchor rule count" 0 "$(rule_count)"

log "== Finished: PASS ${passed}, FAIL ${failed}. Leaves utun1024 test rules installed, mode off. Uninstall: sudo ${REPO}/scripts/firewall-rescue.sh"
log "Reference list (verify no lingering references):"; pfctl -s References 2>/dev/null
[ "${failed}" -eq 0 ]
exit
}
