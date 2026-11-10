#!/bin/bash
# Compile → package Pip.app → ad-hoc sign → install into /Applications (visible in Launchpad, Spotlight) → launch.
# Display name is Pip; bundle ID, executable name, config directory, and labels remain notchkeeper.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Notchkeeper"
APP="build/Pip.app"
INSTALLED="/Applications/Pip.app"
# Pre-rename bundle: identical bundle ID; if retained, login items may launch it, overwriting mod/CLI tools with stale files.
rm -rf build/Notchkeeper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notchkeeper"
cp Support/Info.plist "$APP/Contents/Info.plist"
# Claude Code mod (docs/agent-integration.md "Pip mod"): copied from here during Settings install. Excludes tests and types.
rsync -a --exclude tests --exclude types --exclude tsconfig.json ClaudeMod/ "$APP/Contents/Resources/ClaudeMod/"
# Terminal plugin (Resources/plugins/terminal): copied from here during Settings install.
rsync -a Resources/plugins/ "$APP/Contents/Resources/plugins/"
# String Catalog: swift build does not compile .xcstrings; compiled here into .lproj (docs/ui.md "Localization")
for catalog in Resources/*.xcstrings; do
  xcrun xcstringstool compile "$catalog" --output-directory "$APP/Contents/Resources"
done
# App icon: rendered from Pip look data (Sources/mascot-icon)
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$(dirname "$BIN")/mascot-icon" "$ICONSET"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
rm -rf "$(dirname "$ICONSET")"
# pipctl CLI: copied to <Notchkeeper>/bin/ on each App startup
cp "$(dirname "$BIN")/pipctl" "$APP/Contents/MacOS/pipctl"
# Firewall helper and scripts: copied to /private/tmp before running with admin privileges (docs/firewall.md §4)
cp "$(dirname "$BIN")/firewalld" "$APP/Contents/MacOS/firewalld"
mkdir -p "$APP/Contents/Resources/firewall"
cp scripts/install-firewall.sh scripts/firewall-rescue.sh "$APP/Contents/Resources/firewall/"
echo "==> codesign (ad-hoc)"
# Sign nested binaries before signing whole bundle
codesign --force --sign - "$APP/Contents/MacOS/pipctl"
codesign --force --sign - "$APP/Contents/MacOS/firewalld"
codesign --force --sign - --identifier local.hht.notchkeeper "$APP"
# Replace only our own installed copy: identically named bundle with differing bundle ID belongs to another app.
if [ -e "$INSTALLED" ]; then
  OWNER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$OWNER" != "local.hht.notchkeeper" ]; then
    echo "run.sh: $INSTALLED is not Pip (bundle ID: ${OWNER:-unreadable}); not overwriting" >&2
    exit 1
  fi
fi
pkill -x Notchkeeper 2>/dev/null || true
# Wait for old instance to terminate (poll every 0.1s, max 5s) to avoid single-instance collision
for _ in $(seq 50); do
  pgrep -x Notchkeeper >/dev/null || break
  sleep 0.1
done
if pgrep -x Notchkeeper >/dev/null; then
  echo "run.sh: warning: old Notchkeeper did not exit after 5s; launching new instance anyway" >&2
fi
rm -rf "$INSTALLED"
# Move instead of copy: keeps single bundle with this bundle ID so Spotlight and login items recognize /Applications copy
mv "$APP" "$INSTALLED"
open "$INSTALLED"
echo "==> launched $INSTALLED"
