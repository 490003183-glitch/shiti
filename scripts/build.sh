#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
STAGE="$(mktemp -d /private/tmp/topshelf-build.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/拾屉.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TopShelf "$APP/Contents/MacOS/TopShelf"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>拾屉</string>
<key>CFBundleDisplayName</key><string>拾屉</string>
<key>CFBundleExecutable</key><string>TopShelf</string>
<key>CFBundleIdentifier</key><string>local.topshelf.mac</string>
<key>CFBundleVersion</key><string>9</string>
<key>CFBundleShortVersionString</key><string>0.3.5</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
swift scripts/make-icon.swift "$APP/Contents/Resources"
# Cloud-backed Documents folders may attach Finder metadata to new bundles.
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p dist
ditto -c -k --keepParent --norsrc "$APP" "$PWD/dist/拾屉.zip"
echo "签名校验通过的安装包：$PWD/dist/拾屉.zip"
