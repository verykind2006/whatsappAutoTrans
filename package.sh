#!/bin/zsh
# 编译并打成安装用的 dmg：dist/autoTrans-<版本>.dmg
# 里面有 autoTrans.app、「应用程序」快捷方式、安装说明.html
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
APP="$HOME/Applications/autoTrans.app"
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
ST="$(mktemp -d)/autoTrans"
mkdir -p "$ST" dist
ditto "$APP" "$ST/autoTrans.app"
ln -s /Applications "$ST/应用程序"
cp Resources/安装说明.html "$ST/"
codesign --verify --deep --strict "$ST/autoTrans.app"
OUT="dist/autoTrans-$VER.dmg"
rm -f "$OUT"
hdiutil create -volname "autoTrans" -srcfolder "$ST" -format UDZO -ov "$OUT" >/dev/null
rm -rf "$(dirname "$ST")"
echo "✓ 已生成 $OUT"
