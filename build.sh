#!/bin/zsh
# 编译 autoTrans 并打包成 ~/Applications/autoTrans.app
set -euo pipefail
cd "$(dirname "$0")"

# 用完整 Xcode 工具链（命令行工具包缺 SwiftUI 宏插件）
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
# 中间文件放缓存目录，不放 OneDrive，免得同步一大堆临时文件
DERIVED="$HOME/Library/Caches/autoTrans-xcbuild"
APP="$HOME/Applications/autoTrans.app"

# 必须用 xcodebuild，不能用 swift build：
# 本机翻译用的 MLX 需要编译 Metal 着色器（default.metallib），swift build 不编译、也不报错，
# 程序一用本机模型就崩（vInput 项目踩过，见其 scripts/build-app.sh）。
print "编译中（xcodebuild）…"
xcodebuild -scheme AutoTrans \
    -destination "platform=OS X" \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -quiet \
    build

PRODUCTS="$DERIVED/Build/Products/Release"
[[ -x "$PRODUCTS/AutoTrans" ]] || { print -u2 "构建产物缺失：$PRODUCTS/AutoTrans"; exit 1 }

# 只清理预期路径
case "$APP" in "$HOME/Applications/autoTrans.app") ;; *) print -u2 "拒绝清理非预期路径：$APP"; exit 1 ;; esac
rm -rf -- "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto --norsrc --noextattr "$PRODUCTS/AutoTrans" "$APP/Contents/MacOS/autoTrans"

# 资源包（含 MLX 的 default.metallib）必须一起打进去
for bundle in "$PRODUCTS"/*.bundle; do
  [[ -e "$bundle" ]] || continue
  ditto --norsrc --noextattr "$bundle" "$APP/Contents/Resources/${bundle:t}"
done
if [[ ! -e "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]]; then
  print -u2 "⚠ 缺少 default.metallib——本机模型翻译会崩溃"
  exit 1
fi

# 图标（Resources/AppIcon.icns 由 codex 生成的图转换而来）
ditto --norsrc --noextattr "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Whisper large-v3 的分词表（2.6 MB），随 App 带上，第一次转写不用联网下载
rm -rf "$APP/Contents/Resources/whisper-tokenizer"
ditto --norsrc --noextattr "Resources/whisper-tokenizer" "$APP/Contents/Resources/whisper-tokenizer"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.autotrans.mac</string>
  <key>CFBundleName</key><string>autoTrans</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDisplayName</key><string>autoTrans</string>
  <key>CFBundleExecutable</key><string>autoTrans</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
</dict>
</plist>
PLIST

# 用固定的签名身份签名：这样每次重新编译后，系统给的「完全磁盘访问权限」不会失效。
# 签名前清掉所有扩展属性（OneDrive / Finder 会给文件加，codesign 不接受）
xattr -cr "$APP"
IDENTITY="${SIGN_IDENTITY:-vInput Dev}"   # 没有这个证书就用临时签名
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  print "⚠ 没找到签名证书 $IDENTITY，使用临时签名（每次重编译都要重新授权）"
  codesign --force --deep --sign - "$APP"
fi

print "✓ 已生成 $APP"
