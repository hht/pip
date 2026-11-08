#!/bin/bash
# Rescue script drill: sets up a mock firewall in real paths that allows everything and blocks nothing, then uninstalls via scripts/firewall-rescue.sh. docs/firewall.md §3, §7 Step 1.
# Usage: sudo scripts/firewall-drill.sh; --dry-run requires no root, prints planned files and steps only.
# What is installed: LaunchDaemon checks anchor every 10s, reinstalling an unmatchable rule (TCP to 198.51.100.1:9) if empty,
#   simulating real daemon behavior where cleared rules are restored; executes pfctl -E for enabled reference, writing token to state file.
#   Rule blocks no real traffic. pfctl -E enables pf if inactive, activating system com.apple/* rules; rescue script restores pf upon release.
# Prints measurements from docs/firewall.md §6 requiring root testing: pfctl -E output, -s References, anchor Evaluations increment, initial pf state.
# Uninstall: sudo scripts/firewall-rescue.sh. Rejects execution if any firewall files exist.
# Paths and names must match firewall-rescue.sh.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

LABEL="com.notchkeeper.firewall"
ANCHOR="com.apple/300.Notchkeeper"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
HELPER="/Library/PrivilegedHelperTools/notchkeeper-firewall"
SUPPORT="/Library/Application Support/Notchkeeper"
STATE="${SUPPORT}/firewall.state"
RULES="${SUPPORT}/firewall.pf"
RESCUE="$(cd "$(dirname "$0")" && pwd)/firewall-rescue.sh"

usage() { echo "Usage: sudo $0  or  $0 --dry-run" >&2; exit 64; }
DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    *) usage ;;
  esac
done
if [ "${DRY_RUN}" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root: sudo $0" >&2
  exit 1
fi

RULES_CONTENT='# Notchkeeper rescue drill: unmatchable rule to populate anchor and verify Evaluations
pass out quick inet proto tcp from any to 198.51.100.1 port 9 no state'

HELPER_CONTENT="#!/bin/bash
# Notchkeeper rescue drill mock daemon: checks every 10s, restoring drill rules if anchor is empty. Uninstall: sudo scripts/firewall-rescue.sh
[ -n \"\$(/sbin/pfctl -a '${ANCHOR}' -sr 2>/dev/null)\" ] || exec /sbin/pfctl -q -a '${ANCHOR}' -f '${RULES}'"

PLIST_CONTENT="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${HELPER}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>10</integer>
</dict>
</plist>"

show() { echo "----- $1 -----"; printf '%s\n' "$2"; echo "----- end -----"; }

if [ "${DRY_RUN}" -eq 1 ]; then
  echo "== dry-run: print only, no modifications"
  echo "+ Checks: ${LABEL} unloaded, target files absent"
  echo "+ mkdir -p ${SUPPORT} (root:wheel 0755)"
  echo "+ Write ${RULES} (root:wheel 0644):"; show "${RULES}" "${RULES_CONTENT}"
  echo "+ Write ${HELPER} (root:wheel 0755):"; show "${HELPER}" "${HELPER_CONTENT}"
  echo "+ Write ${PLIST} (root:wheel 0644):"; show "${PLIST}" "${PLIST_CONTENT}"
  echo "+ pfctl -E, token and kern.bootsessionuuid written to ${STATE} (root:wheel 0600)"
  echo "+ launchctl bootstrap system ${PLIST}"
  echo "+ Print measurements: -sr exit code on nonexistent anchor, -s info, -s References, anchor -vsr, rule restoration after flush"
  exit 0
fi

for f in "${PLIST}" "${HELPER}" "${STATE}" "${SUPPORT}/firewall-status.json" "${RULES}" "${SUPPORT}/firewall.lock" \
  "${SUPPORT}/.firewall.state.tmp" "${SUPPORT}/.firewall-status.json.tmp"; do
  if [ -e "${f}" ] || [ -L "${f}" ]; then echo "File already exists: ${f}; run sudo ${RESCUE} first" >&2; exit 1; fi
done
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then echo "${LABEL} already loaded; run sudo ${RESCUE} first" >&2; exit 1; fi

echo "== Initial verification: before install"
pfctl -s info 2>/dev/null | sed -n '1p' || true
rules="$(pfctl -a "${ANCHOR}" -sr 2>/dev/null)" && rc=0 || rc=$?
echo "--- pfctl -a ${ANCHOR} -sr (nonexistent anchor): exit code ${rc}, stdout '${rules}'"
echo "--- pfctl -s References (stdout)"; pfctl -s References 2>/dev/null || true

echo "== Writing files"
install -d -o root -g wheel -m 0755 "${SUPPORT}"
tmp="$(mktemp)"
printf '%s\n' "${RULES_CONTENT}" > "${tmp}"; pfctl -qnf "${tmp}"; install -o root -g wheel -m 0644 "${tmp}" "${RULES}"
printf '%s\n' "${HELPER_CONTENT}" > "${tmp}"; install -o root -g wheel -m 0755 "${tmp}" "${HELPER}"
printf '%s\n' "${PLIST_CONTENT}" > "${tmp}"; plutil -lint "${tmp}" >/dev/null; install -o root -g wheel -m 0644 "${tmp}" "${PLIST}"
rm -f "${tmp}"
ls -l "${RULES}" "${HELPER}" "${PLIST}"

echo "== Verification: pfctl -E"
out="$(mktemp)"; err="$(mktemp)"
pfctl -E >"${out}" 2>"${err}" || echo "!! pfctl -E exit code $?" >&2
echo "--- stdout"; cat "${out}"
echo "--- stderr"; cat "${err}"
token="$(cat "${out}" "${err}" | sed -n 's/^Token : \([0-9][0-9]*\)$/\1/p')"
rm -f "${out}" "${err}"
if [ -n "${token}" ]; then
  ( umask 077; printf '{"mode":"drill","token":"%s","bootSession":"%s"}\n' "${token}" "$(sysctl -n kern.bootsessionuuid)" > "${STATE}" )
  echo "token written to ${STATE}"
else
  echo "!! Token unrecognized in output (expected 'Token : <digits>')" >&2
fi

echo "== Starting mock daemon"
launchctl bootstrap system "${PLIST}"
sleep 2
echo "--- pfctl -a ${ANCHOR} -vsr"; pfctl -a "${ANCHOR}" -vsr 2>/dev/null || true
echo "(Waiting 10s to observe Evaluations increment)"; sleep 10
echo "--- pfctl -a ${ANCHOR} -vsr"; pfctl -a "${ANCHOR}" -vsr 2>/dev/null || true
echo "--- pfctl -s info"; pfctl -s info 2>/dev/null | sed -n '1p' || true
echo "--- pfctl -s References"; pfctl -s References 2>/dev/null || true

echo "== Verification: manually flushing anchor, daemon should restore rules within 10s"
pfctl -q -a "${ANCHOR}" -F rules 2>/dev/null || true
echo "After flush: $(pfctl -a "${ANCHOR}" -sr 2>/dev/null | wc -l | tr -d ' ') rules"
sleep 11
echo "After 11s: $(pfctl -a "${ANCHOR}" -sr 2>/dev/null | wc -l | tr -d ' ') rules"
launchctl print "system/${LABEL}" | grep -E '^[[:space:]]*(state|runs|last exit code) =' || true

echo "== Installed successfully. Next step: sudo ${RESCUE}, confirm final line states completely uninstalled."
