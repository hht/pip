#!/bin/bash
# Triggers notch cards from command line (local distributed notifications) to verify card UI on real devices.
# Listened only by DEBUG builds: run CONFIG=debug scripts/run.sh first.
# Usage: scripts/demo.sh done|failed|question|approval|alert|blocks|settings
# Agent cards attach to most recently updated Claude Code session, behaving like real cards; omitted if no session exists.
case "${1:-done}" in done|failed|question|approval|alert|blocks|settings) ;; *) echo "Usage: $0 done|failed|question|approval|alert|blocks|settings" >&2; exit 2;; esac
JS=$(cat <<'JSEOF'
ObjC.import('Foundation');
function run(argv) {
  $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('local.hht.notchkeeper.card', argv[0], $.NSDictionary.dictionary, true);
  return 'posted ' + argv[0];
}
JSEOF
)
osascript -l JavaScript -e "$JS" "${1:-done}"
