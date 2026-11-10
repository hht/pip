#!/bin/bash
# Synchronizes UI text from code into String Catalog (Resources/Localizable.xcstrings): adds new strings, marks deleted strings stale.
# Extracts strings via compiler (-emit-localized-strings) using a separate scratch path without disturbing normal builds.
# After running, supply translations and remove stale keys; verified by LocalizationCoverage in swift test.
# --check: checks if sync is required without modifying files.
# @see https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# String extraction occurs during full compilation: clean previous scratch build artifacts
rm -rf .build/strings
swift build --product Notchkeeper --scratch-path .build/strings \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT"
CATALOG=Resources/Localizable.xcstrings
if [[ "${1:-}" == --check ]]; then
  # Duplicate must keep same name for sync table matching. Compare JSON structure rather than byte layout.
  mkdir "$OUT/check" && cp "$CATALOG" "$OUT/check/"
  xcrun xcstringstool sync "$OUT/check/Localizable.xcstrings" --stringsdata "$OUT"/*.stringsdata
  if ! python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1])) != json.load(open(sys.argv[2])))' \
       "$CATALOG" "$OUT/check/Localizable.xcstrings"; then
    echo "==> $CATALOG out of sync with code: run scripts/strings.sh to sync, then add translations and remove stale keys" >&2
    exit 1
  fi
  echo "==> $CATALOG matches code"
  exit 0
fi
xcrun xcstringstool sync "$CATALOG" --stringsdata "$OUT"/*.stringsdata
echo "==> Synced $CATALOG"
