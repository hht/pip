#!/bin/bash
# 编译 → 打包 Pip.app → 本机临时签名 (ad-hoc) → 装进 /Applications（启动台、聚焦搜索里看得到）→ 启动。
# App 显示名叫 Pip；bundle ID、可执行文件名、配置目录和各种 label 仍叫 notchkeeper，不用迁移
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Notchkeeper"
APP="build/Pip.app"
INSTALLED="/Applications/Pip.app"
# 改名前的包：bundle ID 相同，留着的话开机启动可能拉起它，用旧文件覆盖已装的 mod 和命令行工具、占住单实例锁
rm -rf build/Notchkeeper.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notchkeeper"
cp Support/Info.plist "$APP/Contents/Info.plist"
# Claude Code mod（docs/agent-integration.md「Notchkeeper mod」）：设置页安装时从这里拷出去。测试和 Claude Code 生成的类型声明不带
rsync -a --exclude tests --exclude types --exclude tsconfig.json ClaudeMod/ "$APP/Contents/Resources/ClaudeMod/"
# 终端插件（Resources/plugins/terminal）：设置页安装时从这里拷出去
rsync -a Resources/plugins/ "$APP/Contents/Resources/plugins/"
# String Catalog：swift build 不编译 .xcstrings，在这里编进各语言的 .lproj（docs/ui.md「多语言」）
for catalog in Resources/*.xcstrings; do
  xcrun xcstringstool compile "$catalog" --output-directory "$APP/Contents/Resources"
done
# App 图标：按 Pip 的造型数据画（Sources/mascot-icon）
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$(dirname "$BIN")/mascot-icon" "$ICONSET"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
rm -rf "$(dirname "$ICONSET")"
# 命令行工具 pipctl：App 每次启动拷到 <Notchkeeper>/bin/
cp "$(dirname "$BIN")/pipctl" "$APP/Contents/MacOS/pipctl"
# 防火墙的辅助程序和两份脚本：设置 › 防火墙「安装」「卸载」时拷到 /private/tmp 再提权跑（docs/firewall.md §4）
cp "$(dirname "$BIN")/firewalld" "$APP/Contents/MacOS/firewalld"
mkdir -p "$APP/Contents/Resources/firewall"
cp scripts/install-firewall.sh scripts/firewall-rescue.sh "$APP/Contents/Resources/firewall/"
echo "==> codesign (ad-hoc)"
# 包里另一个可执行文件要先签，再签整个包
codesign --force --sign - "$APP/Contents/MacOS/pipctl"
codesign --force --sign - "$APP/Contents/MacOS/firewalld"
codesign --force --sign - --identifier local.hht.notchkeeper "$APP"
# 只替换自己装的那一份：同名但 bundle ID 不同的是别人的 App，不动。在结束旧实例之前查，查不过时旧的 Pip 还开着
if [ -e "$INSTALLED" ]; then
  OWNER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$OWNER" != "local.hht.notchkeeper" ]; then
    echo "run.sh: $INSTALLED 不是 Pip（bundle ID：${OWNER:-读不出}），不覆盖" >&2
    exit 1
  fi
fi
pkill -x Notchkeeper 2>/dev/null || true
# 等旧实例真正退出（每 0.1s 查一次，最多 5s），新实例的单实例检查才不会因为它还在而退出
for _ in $(seq 50); do
  pgrep -x Notchkeeper >/dev/null || break
  sleep 0.1
done
if pgrep -x Notchkeeper >/dev/null; then
  echo "run.sh: 警告：旧的 Notchkeeper 5 秒后仍未退出，照常启动新实例" >&2
fi
rm -rf "$INSTALLED"
# 挪走而不是拷贝：仓库里不留第二份同 bundle ID 的包，聚焦搜索和开机启动只认得 /Applications 里这一份
mv "$APP" "$INSTALLED"
open "$INSTALLED"
echo "==> launched $INSTALLED"
