#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/build.sh --universal
DMG_STAGE="$(mktemp -d /private/tmp/topshelf-dmg.XXXXXX)"
trap 'rm -rf "$DMG_STAGE"' EXIT
mkdir "$DMG_STAGE/content"
ditto -x -k dist/拾屉.zip "$DMG_STAGE/content"
APP="$DMG_STAGE/content/拾屉.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG_NAME="Shiti-$VERSION-universal.dmg"
ln -s /Applications "$DMG_STAGE/content/Applications"
cp LICENSE "$DMG_STAGE/content/LICENSE.txt"
cat > "$DMG_STAGE/content/安装说明.txt" <<'TEXT'
拾屉 · Shiti

1. 若已运行拾屉，请先退出。
2. 把「拾屉.app」拖进旁边的 Applications（应用程序）文件夹。
3. 从「应用程序」打开拾屉，然后推出此磁盘映像。
4. 鼠标移到屏幕顶部向下滚动，或按 Control + Option + 空格呼出。

需要 macOS 13 或更新版本。包含 Apple Silicon 和 Intel 两种架构；Intel 尚未实机验证。

本版本使用临时签名，尚无 Apple Developer ID 签名和公证。
首次打开时 macOS 可能提示无法验证开发者。只有确认来自本项目且信任该版本时，
才按 Apple 官方说明，在尝试打开后前往「系统设置 → 隐私与安全性 → 仍要打开」。
系统可能要求管理员批准。不要关闭系统整体安全保护。
Apple 官方说明：https://support.apple.com/zh-cn/102445

便签和文件入口保存在本机，不包含任何开发者的个人便签。
项目与反馈：https://github.com/490003183-glitch/shiti

Installation: Quit any running copy, drag Shiti (拾屉.app) into Applications,
then open it from Applications and eject this disk image.
Requires macOS 13+. Universal binary (Apple Silicon and Intel; Intel not tested on hardware).
This build is ad-hoc signed and NOT notarized by Apple.
TEXT
codesign --verify --deep --strict "$APP"
hdiutil create -volname "拾屉 $VERSION" -srcfolder "$DMG_STAGE/content" -fs HFS+ -format UDZO "$DMG_STAGE/$DMG_NAME"
hdiutil verify "$DMG_STAGE/$DMG_NAME"
mv "$DMG_STAGE/$DMG_NAME" "dist/$DMG_NAME"
(cd dist && shasum -a 256 "$DMG_NAME" > SHA256SUMS)
echo "DMG: $PWD/dist/$DMG_NAME"
