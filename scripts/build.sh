#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--universal" ) ]]; then
    echo "Usage: bash scripts/build.sh [--universal]" >&2
    exit 2
fi
STAGE="$(mktemp -d /private/tmp/topshelf-build.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/拾屉.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "${1:-}" == "--universal" ]]; then
    for ARCH in arm64 x86_64; do
        swift build -c release --triple "$ARCH-apple-macosx13.0"
        BIN_DIR="$(swift build -c release --triple "$ARCH-apple-macosx13.0" --show-bin-path)"
        cp "$BIN_DIR/TopShelf" "$STAGE/TopShelf-$ARCH"
    done
    lipo -create "$STAGE/TopShelf-arm64" "$STAGE/TopShelf-x86_64" -output "$APP/Contents/MacOS/TopShelf"
    lipo "$APP/Contents/MacOS/TopShelf" -verify_arch arm64 x86_64
else
    swift build -c release
    BIN_DIR="$(swift build -c release --show-bin-path)"
    cp "$BIN_DIR/TopShelf" "$APP/Contents/MacOS/TopShelf"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>拾屉</string>
<key>CFBundleDisplayName</key><string>拾屉</string>
<key>CFBundleExecutable</key><string>TopShelf</string>
<key>CFBundleIdentifier</key><string>local.topshelf.mac</string>
<key>CFBundleVersion</key><string>15</string>
<key>CFBundleShortVersionString</key><string>0.3.11</string>
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
