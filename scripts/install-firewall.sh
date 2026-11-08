#!/bin/bash
# Install firewall (docs/firewall.md §4 "Privileged Components"): helper tool, LaunchDaemon, support directories. Installed as off, blocking nothing; enable via sudo … enable.
# Usage:
#   scripts/install-firewall.sh [--tunnel <interface>] --dry-run          No root: compiles, prints what would be installed
#   sudo scripts/install-firewall.sh [--tunnel <interface>]               Compiles, prints same content, prompts for yes
#   … --helper <helper> --expect-sha256 <hash> [--yes]                    Skips compilation, installs prebuilt helper; stops if hash mismatches.
#                                                                         --yes skips prompt: user already confirmed in App and entered password in system dialog
#   … --test-rules --test-address <IPv4>                                  Test rules: blocks traffic to test address only, avoiding disconnection during testing (§7)
# Compilation always runs as regular user: drops back to calling user under sudo; callers without sudo (App via osascript) must supply --helper and hash.
# Defaults to production rules (whole-machine block). Installed as off, loaded upon enable with 2-minute trial run.
# Test address written to test.table; pick an overseas address not in Clash nodes (domestic or <clash> addresses would pass without testing block).
# Rejects execution if any firewall files exist: no overwrites, no backups needed. Upgrade via sudo scripts/firewall-rescue.sh before installing.
# Untouched: /etc/pf.conf, third-party anchors and tokens, Clash, network settings, sudoers, arbitrary processes; pfctl uses -n syntax check only.
# Uninstall: sudo scripts/firewall-rescue.sh. Paths and names must match firewall-rescue.sh (RescueScriptTests compares line by line).
# Wrapped in curly braces so bash parses full file before execution: modifying script mid-execution under root has no effect.
{
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

LABEL="com.notchkeeper.firewall"
ANCHOR="com.apple/300.Notchkeeper"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
HELPER="/Library/PrivilegedHelperTools/notchkeeper-firewall"
SUPPORT="/Library/Application Support/Notchkeeper"
STATE="${SUPPORT}/firewall.state"
# Helper tool also writes lock file, allow tables, and fixed temp files; test table written by install script
FILES=("${PLIST}" "${HELPER}" "${STATE}" "${SUPPORT}/firewall-status.json" "${SUPPORT}/firewall.pf" "${SUPPORT}/firewall.lock"
  "${SUPPORT}/.firewall.state.tmp" "${SUPPORT}/.firewall-status.json.tmp" "${SUPPORT}/clash.table" "${SUPPORT}/cn.table"
  "${SUPPORT}/.clash.table.tmp" "${SUPPORT}/.cn.table.tmp" "${SUPPORT}/test.table")
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILT="${REPO}/.build/release/firewalld"
RESCUE_HINT="Settings › Firewall 'Uninstall', or in repo sudo scripts/firewall-rescue.sh"

usage() { echo "Usage: sudo $0 [--tunnel <interface>] [--helper <helper> --expect-sha256 <hash> [--yes]] [--test-rules --test-address <IPv4>]  or  add --dry-run to print only" >&2; exit 64; }
die() { echo "Installation aborted: $1" >&2; exit 1; }
ARGS="$*"
DRY_RUN=0
TEST_RULES=0
TEST_ADDRESS=""
TUNNEL="utun1024"
HELPER_SOURCE=""
EXPECT_SHA256=""
YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --test-rules) TEST_RULES=1 ;;
    --test-address) [ $# -ge 2 ] || usage; TEST_ADDRESS="$2"; shift ;;
    --tunnel) [ $# -ge 2 ] || usage; TUNNEL="$2"; shift ;;
    --helper) [ $# -ge 2 ] || usage; HELPER_SOURCE="$2"; shift ;;
    --expect-sha256) [ $# -ge 2 ] || usage; EXPECT_SHA256="$2"; shift ;;
    --yes) YES=1 ;;
    *) usage ;;
  esac
  shift
done
if [ "${TEST_RULES}" -eq 1 ]; then
  [[ "${TEST_ADDRESS}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "--test-rules requires an IPv4 test address via --test-address"
else
  [ -z "${TEST_ADDRESS}" ] || die "--test-address is used only with --test-rules"
fi
[ -z "${EXPECT_SHA256}" ] || [[ "${EXPECT_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "--expect-sha256 must be 64-character lowercase hex"
{ [ -z "${HELPER_SOURCE}" ] && [ -z "${EXPECT_SHA256}" ]; } || { [ -n "${HELPER_SOURCE}" ] && [ -n "${EXPECT_SHA256}" ]; } \
  || die "--helper and --expect-sha256 must be provided together"
[ "${YES}" -eq 0 ] || [ -n "${EXPECT_SHA256}" ] || die "--yes available only with --helper and --expect-sha256"
if [ "${DRY_RUN}" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root: sudo $0 ${ARGS}; inspect first: $0 ${ARGS} --dry-run" >&2
  exit 1
fi

# Repo and build dir writable by user: compilation, reading binaries, running rules drop to calling user.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  as_user() { sudo -u "${SUDO_USER}" -H "$@"; }
elif [ "$(id -u)" -eq 0 ]; then
  [ -n "${HELPER_SOURCE}" ] || die "Cannot compile without invoking sudo user: supply --helper and --expect-sha256"
  as_user() { "$@"; }
else
  as_user() { "$@"; }
fi

if [ -n "${HELPER_SOURCE}" ]; then
  BUILT="${HELPER_SOURCE}"
else
  echo "== Compiling firewalld (release)"
  cd "${REPO}"
  as_user swift build -c release --product firewalld --package-path "${REPO}" || die "Compilation failed"
fi

# Read snapshot into private temp directory: hash, rules, installed binary all derive from this snapshot.
SNAPSHOT_DIR="$(mktemp -d /private/tmp/notchkeeper-firewall-install.XXXXXX)"
trap 'rm -rf "${SNAPSHOT_DIR}"' EXIT
chmod 0711 "${SNAPSHOT_DIR}"
SNAPSHOT="${SNAPSHOT_DIR}/notchkeeper-firewall"
# Read regular file only, max 64 MB: avoids symlink following and FIFO hangs
{ [ -f "${BUILT}" ] && [ ! -L "${BUILT}" ]; } || die "${BUILT} is not a regular file"
( umask 077; as_user head -c 67108864 "${BUILT}" > "${SNAPSHOT}" ) || die "Cannot read ${BUILT}"
SHA256="$(shasum -a 256 "${SNAPSHOT}" | cut -d ' ' -f 1)"
[ -z "${EXPECT_SHA256}" ] || [ "${SHA256}" = "${EXPECT_SHA256}" ] || die "Helper hash does not match caller expected ${EXPECT_SHA256}: file modified after export"
chmod 0755 "${SNAPSHOT}"
rc=0
TEST_FLAG=()
[ "${TEST_RULES}" -eq 0 ] || TEST_FLAG=(--test-rules)
# Under bash 3.2 set -u on empty array expands as unbound: use ${a[@]+…} syntax
RULES="$(as_user "${SNAPSHOT}" rules --tunnel "${TUNNEL}" ${TEST_FLAG[@]+"${TEST_FLAG[@]}"})" || rc=$?
case "${rc}" in
  0) ;;
  64) die "Invalid interface name: ${TUNNEL}" ;;
  *) die "Helper failed to execute (exit code ${rc})" ;;
esac

# Interface name validated by helper (alphanumeric only), safe for XML interpolation.
TEST_PLIST_ARG=""
[ "${TEST_RULES}" -eq 0 ] || TEST_PLIST_ARG="
        <string>--test-rules</string>"
PLIST_CONTENT="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${HELPER}</string>
        <string>round</string>
        <string>--tunnel</string>
        <string>${TUNNEL}</string>${TEST_PLIST_ARG}
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>1</integer>
</dict>
</plist>"
printf '%s\n' "${PLIST_CONTENT}" | plutil -lint - >/dev/null || die "Invalid plist"

# check_syntax <rules> <temp_dir>: pfctl -n parses syntax without loading rules.
check_syntax() {
  local t
  for t in clash.table cn.table test.table; do : > "$2/${t}"; done
  printf '%s\n' "${1//"${SUPPORT}"/$2}" > "$2/rules.pf"
  pfctl -q -a "${ANCHOR}" -nf "$2/rules.pf"
}

show() { echo "----- $1 -----"; printf '%s\n' "$2"; echo "----- end -----"; }
[ "${DRY_RUN}" -eq 1 ] && echo "== dry-run: print only, no modifications"
echo "== Files to install (all new files; rejected if any already exist)"
echo "Helper ${HELPER} (root:wheel 0755), from ${BUILT}"
echo "  sha256 ${SHA256}"
echo "Directory ${SUPPORT} (root:wheel 0755): stores state, status summary, lock, allow tables"
[ "${TEST_RULES}" -eq 0 ] || echo "Test table ${SUPPORT}/test.table (root:wheel 0644): ${TEST_ADDRESS}"
echo "LaunchDaemon ${PLIST} (root:wheel 0644):"; show "${PLIST}" "${PLIST_CONTENT}"
if [ "${TEST_RULES}" -eq 1 ]; then
  echo "Test rules loaded into anchor ${ANCHOR} each round when enabled (trial / on) (installed as off):"; show "Rules" "${RULES}"
else
  echo "Production rules loaded into anchor ${ANCHOR} each round when enabled (trial / on) (installed as off):"; show "Rules" "${RULES}"
fi

echo "(pfctl -n checks syntax only; 'could result in flushing of rules' and 'No ALTQ support' are standard notices, not errors)"
check_syntax "${RULES}" "${SNAPSHOT_DIR}" || die "pfctl reported syntax error in rules"
echo "== Rules syntax valid"

if [ "${DRY_RUN}" -eq 1 ]; then
  echo "+ Checks: ${LABEL} unloaded, target files absent"
  [ "${YES}" -eq 1 ] && echo "+ Non-interactive (--yes)" || echo "+ Prompt 'Type yes to proceed'"
  echo "+ Write helper and plist, launchctl bootstrap system ${PLIST}, await first status summary"
  exit 0
fi

for f in "${FILES[@]}"; do
  if [ -e "${f}" ] || [ -L "${f}" ]; then die "File already exists: ${f}; uninstall first (${RESCUE_HINT})"; fi
done
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then die "${LABEL} already loaded; uninstall first (${RESCUE_HINT})"; fi
echo "== Checks passed: not previously installed"

if [ "${YES}" -eq 1 ]; then
  echo "== --yes: confirmed by caller, helper hash verified"
else
  read -r -p "Confirm installation? Type yes to proceed: " answer
  [ "${answer}" = "yes" ] || { echo "Not installed; nothing modified"; exit 1; }
fi

trap 'echo "!! Installation failed midway: uninstall (${RESCUE_HINT}) to clean partial installation" >&2' ERR
install -d -o root -g wheel -m 0755 "${SUPPORT}"
install -o root -g wheel -m 0755 "${SNAPSHOT}" "${HELPER}"
if [ "${TEST_RULES}" -eq 1 ]; then
  printf '%s\n' "${TEST_ADDRESS}" > "${SNAPSHOT_DIR}/test-address"
  install -o root -g wheel -m 0644 "${SNAPSHOT_DIR}/test-address" "${SUPPORT}/test.table"
fi
printf '%s\n' "${PLIST_CONTENT}" > "${SNAPSHOT_DIR}/plist"
install -o root -g wheel -m 0644 "${SNAPSHOT_DIR}/plist" "${PLIST}"
launchctl bootstrap system "${PLIST}"
trap - ERR
ls -l "${HELPER}" "${PLIST}"

STATUS="${SUPPORT}/firewall-status.json"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -e "${STATUS}" ] && break
  sleep 1
done
if [ -e "${STATUS}" ]; then
  echo "--- First status summary (mode should be off)"; cat "${STATUS}"; echo
else
  echo "!! No status summary within 10s; inspect logs: log show --last 5m --predicate 'subsystem == \"${LABEL}\"'" >&2
fi
launchctl print "system/${LABEL}" | grep -E '^[[:space:]]*(state|runs|last exit code) =' || true

echo "== Installed successfully; currently off, blocking nothing."
echo "Enable trial (automatically rolls back if unconfirmed after 2 minutes):"
echo "  sudo ${HELPER} enable --clash \"\$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev\""
echo "Keep / Disable: sudo ${HELPER} keep | disable"
echo "Check status: cat \"${STATUS}\"; view logs: log show --last 5m --predicate 'subsystem == \"${LABEL}\"'"
echo "Uninstall: ${RESCUE_HINT}"
exit
}
