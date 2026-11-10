#!/bin/bash
# Firewall rescue script: completely uninstalls Notchkeeper firewall from system during network disconnection. Design in docs/firewall.md §3.
# Usage: sudo scripts/firewall-rescue.sh [--disable-pf]; --dry-run requires no root, prints planned steps only.
# No dependencies on network, App, or installed firewall scripts; uses launchctl, pfctl, plutil. Safe and idempotent.
# Never hangs terminal: kernel deadlocks in pf (docs/firewall.md §5) cause all pfctl calls to hang,
# and launchctl bootout will also wait on hung daemons. Therefore:
#   1. Delete boot plist and helper first: file operations only, avoids pf; reboot restores network cleanly;
#   2. Subsequent launchctl / pfctl calls are bounded by timeout, abandoning wait on timeout.
# Never executes pfctl -d by default: stops entire pf and invalidates external references; only executed with --disable-pf.
# Untouched: /etc/pf.conf, third-party anchors/tokens, Clash, network settings, arbitrary processes.
# Paths and names must match install-firewall.sh.
set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

LABEL="com.notchkeeper.firewall"
ANCHOR="com.apple/300.Notchkeeper"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
HELPER="/Library/PrivilegedHelperTools/notchkeeper-firewall"
SUPPORT="/Library/Application Support/Notchkeeper"
STATE="${SUPPORT}/firewall.state"
FILES=("${PLIST}" "${HELPER}" "${STATE}" "${SUPPORT}/firewall-status.json" "${SUPPORT}/firewall.pf" "${SUPPORT}/firewall.lock"
  "${SUPPORT}/.firewall.state.tmp" "${SUPPORT}/.firewall-status.json.tmp" "${SUPPORT}/clash.table" "${SUPPORT}/cn.table"
  "${SUPPORT}/.clash.table.tmp" "${SUPPORT}/.cn.table.tmp" "${SUPPORT}/test.table")

usage() { echo "Usage: sudo $0 [--disable-pf]  or  $0 --dry-run [--disable-pf]" >&2; exit 64; }
DRY_RUN=0
DISABLE_PF=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    --disable-pf) DISABLE_PF=1 ;;
    *) usage ;;
  esac
done
if [ "${DRY_RUN}" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root: sudo $0" >&2
  exit 1
fi

limited() {
  local seconds="$1" out="$2" pid i
  shift 2
  "$@" </dev/null >"${out}" 2>&1 &
  pid=$!
  for ((i = 0; i < seconds * 10; i++)); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      wait "${pid}"
      return $?
    fi
    sleep 0.1
  done
  disown "${pid}" 2>/dev/null
  kill -9 "${pid}" 2>/dev/null
  return 124
}

hung=0
OUT=""
if [ "${DRY_RUN}" -eq 0 ]; then
  OUT="$(mktemp -d /private/tmp/notchkeeper-rescue.XXXXXX)/out"
  trap 'rm -rf "$(dirname "${OUT}")"' EXIT
fi

run() {
  local rc=0
  printf '+'; printf ' %q' "$@"; printf '\n'
  [ "${DRY_RUN}" -eq 1 ] && return 0
  limited 10 "${OUT}" "$@" || rc=$?
  sed 's/^/   /' "${OUT}"
  if [ "${rc}" -eq 124 ]; then
    hung=1
    echo "!! Did not return within 10s, abandoning wait" >&2
  fi
  return "${rc}"
}

loaded() { limited 5 /dev/null launchctl print "system/${LABEL}"; }

check_anchor() {
  local rc=0
  limited 5 "${OUT}" pfctl -a "${ANCHOR}" -sr || rc=$?
  [ "${rc}" -eq 124 ] && hung=1
  if [ "${rc}" -ne 0 ]; then ANCHOR_RULES=unknown
  elif grep -qv -e '^No ALTQ' -e '^ALTQ' "${OUT}"; then ANCHOR_RULES=yes
  else ANCHOR_RULES=no; fi
}

[ "${DRY_RUN}" -eq 1 ] && echo "== dry-run: print only, no modifications"
echo "(pfctl notices 'No ALTQ support in kernel' and 'ALTQ related functions disabled' are normal notices, not errors)"

token=""
session="$(sysctl -n kern.bootsessionuuid 2>/dev/null)"
if [ -n "${session}" ] && [ -r "${STATE}" ] && [ "$(plutil -extract bootSession raw -o - "${STATE}" 2>/dev/null)" = "${session}" ]; then
  token="$(plutil -extract token raw -o - "${STATE}" 2>/dev/null)"
  case "${token}" in ''|*[!0-9]*) token="" ;; esac
fi

echo "== 1/5 Delete boot-loaded files (touches files only, avoids pf: reboot restores network after this step)"
for f in "${PLIST}" "${HELPER}"; do
  if [ "${DRY_RUN}" -eq 1 ]; then echo "+ (if exists) rm -f ${f}"
  elif [ -e "${f}" ] || [ -L "${f}" ]; then run rm -f "${f}"
  else echo "   ${f} not found, skipped"; fi
done

echo "== 2/5 Stop daemon"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "+ (if loaded) launchctl bootout system/${LABEL} (max wait 10s)"
elif loaded; then
  run launchctl bootout "system/${LABEL}" || true
else
  echo "   Not loaded, skipped"
fi

echo "== 3/5 Flush anchor ${ANCHOR}"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "+ (if rules present) pfctl -a ${ANCHOR} -F rules (max wait 10s)"
elif [ "${hung}" -eq 1 ]; then
  echo "   pf is hung, skipped"
else
  check_anchor
  if [ "${ANCHOR_RULES}" = no ]; then echo "   No rules, skipped"
  elif [ "${hung}" -eq 1 ]; then echo "   Rule read timed out after 5s; pf is hung, skipped"
  else run pfctl -a "${ANCHOR}" -F rules || true; fi
fi

echo "== 4/5 Release firewall pf enabled reference"
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "+ (if token present in state file) pfctl -X <token> (max wait 10s)"
elif [ "${hung}" -eq 1 ]; then
  echo "   pf is hung, skipped"
elif [ -n "${token}" ]; then
  run pfctl -X "${token}" || true
else
  echo "   No token for current boot session found in state file, skipped"
fi

echo "== 5/5 Delete remaining files (uninstallation complete)"
for f in "${FILES[@]}"; do
  if [ "${DRY_RUN}" -eq 1 ]; then echo "+ (if exists) rm -f ${f}"
  elif [ -e "${f}" ] || [ -L "${f}" ]; then run rm -f "${f}"; fi
done
if [ -d "${SUPPORT}" ]; then
  if [ "${DRY_RUN}" -eq 1 ]; then echo "+ (if empty) rmdir ${SUPPORT}"; else rmdir "${SUPPORT}" 2>/dev/null || true; fi
fi

if [ "${DISABLE_PF}" -eq 1 ]; then
  echo "== Last resort: disable entire pf (external references invalidated)"
  if [ "${DRY_RUN}" -eq 0 ] && [ "${hung}" -eq 1 ]; then echo "   pf is hung, pfctl -d would also hang, skipped"; else run pfctl -d || true; fi
fi

[ "${DRY_RUN}" -eq 1 ] && exit 0

echo "== Verification"
ok=1
for f in "${FILES[@]}"; do
  if [ -e "${f}" ] || [ -L "${f}" ]; then ok=0; echo "!! Still present: ${f}" >&2; fi
done
if loaded; then ok=0; echo "!! ${LABEL} still loaded in launchd" >&2; else echo "   ${LABEL}: not loaded"; fi
if [ "${hung}" -eq 0 ]; then
  check_anchor
  case "${ANCHOR_RULES}" in
    no) echo "   anchor ${ANCHOR}: empty" ;;
    yes) ok=0; echo "!! anchor ${ANCHOR} still has rules:" >&2; sed 's/^/   /' "${OUT}" >&2 ;;
    *) ok=0; echo "!! Cannot read anchor ${ANCHOR}" >&2 ;;
  esac
fi
if [ "${hung}" -eq 0 ] && limited 5 "${OUT}" pfctl -s info; then
  echo "   pf: $(sed -n 's/^Status: \([A-Za-z]*\).*/\1/p' "${OUT}") (Enabled does not indicate issues: system and other apps enable pf)"
fi

if [ "${hung}" -eq 1 ]; then
  echo "== pf is deadlocked in kernel, requiring reboot (pfctl -d also hangs). Boot files deleted: reboot computer to restore network." >&2
  exit 2
elif [ "${ok}" -eq 1 ]; then
  echo "== Complete: Notchkeeper firewall completely uninstalled"
else
  echo "== Incomplete cleanup, see !! above; rerun or use sudo $0 --disable-pf" >&2
  exit 1
fi
