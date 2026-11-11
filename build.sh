#!/bin/bash
# 构建 NASMonitor.app（原生 SwiftUI 菜单栏应用，无需 Xcode 工程）
#
# 版本由仓库根目录 VERSION 单一来源驱动：
#   sync  → 生成 Version.swift + 回填 Resources/Info.plist
#   stamp → 把版本写进组装后的 .app/Contents/Info.plist
#   check → 构建完跑一致性门禁，不一致直接失败（避免又发出一个 1.0 的包）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
VER="$ROOT/scripts/version.sh"

echo "▸ 版本同步（VERSION → Version.swift / Info.plist）..."
"$VER" sync
NM_VERSION="$("$VER" print | /usr/bin/awk '/^MARKETING/ {print $2}')"

echo "▸ 编译 Swift (release, $NM_VERSION)..."
swift build -c release --disable-sandbox

BIN="$(swift build -c release --disable-sandbox --show-bin-path)/NASMonitor"
if [[ ! -x "$BIN" ]]; then
  echo "✗ 找不到可执行文件: $BIN" >&2
  exit 1
fi

APP="$ROOT/NASMonitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NASMonitor"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
"$VER" stamp "$APP/Contents/Info.plist" >/dev/null
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
for PNG in MenuBar-Light.png MenuBar-Dark.png; do
  if [[ -f "$ROOT/Resources/$PNG" ]]; then
    cp "$ROOT/Resources/$PNG" "$APP/Contents/Resources/$PNG"
  fi
done

echo "▸ ad-hoc 签名..."
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (签名跳过，应用仍可直接运行)"

echo "▸ 版本一致性门禁..."
"$VER" check --skip-dist

echo "✓ 已生成: $APP  ($NM_VERSION)"
echo "  运行: open \"$APP\""
echo "  版本: \"$APP/Contents/MacOS/NASMonitor\" --version"
