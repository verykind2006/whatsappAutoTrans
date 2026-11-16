#!/bin/zsh
# 编译并打成安装用的 dmg：dist/autoTransWhatsapp-<版本>.dmg
# 里面有 autoTransWhatsapp.app、「应用程序」快捷方式、安装说明.html
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
APP="$HOME/Applications/autoTransWhatsapp.app"
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
ST="$(mktemp -d)/autoTransWhatsapp"
mkdir -p "$ST" dist
ditto "$APP" "$ST/autoTransWhatsapp.app"
ln -s /Applications "$ST/应用程序"
cp Resources/安装说明.html "$ST/"
codesign --verify --deep --strict "$ST/autoTransWhatsapp.app"
OUT="dist/autoTransWhatsapp-$VER.dmg"
rm -f "$OUT"
hdiutil create -volname "autoTransWhatsapp" -srcfolder "$ST" -format UDZO -ov "$OUT" >/dev/null
rm -rf "$(dirname "$ST")"
echo "✓ 已生成 $OUT"
