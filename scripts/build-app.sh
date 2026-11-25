#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/QuotaCard.app"
CONTENTS="$APP_BUNDLE/Contents"

echo "==> Building release binaries..."
mkdir -p /tmp/swift-module-cache
TMPDIR=/tmp CLANG_MODULE_CACHE_PATH=/tmp/swift-module-cache \
  swift build --disable-sandbox -c release --package-path "$ROOT_DIR" --product quota-card-ingest
TMPDIR=/tmp CLANG_MODULE_CACHE_PATH=/tmp/swift-module-cache \
  swift build --disable-sandbox -c release --package-path "$ROOT_DIR" --product QuotaCardApp

BIN_DIR="$ROOT_DIR/.build/release"

echo "==> Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources/scripts"

cp "$BIN_DIR/QuotaCardApp" "$CONTENTS/MacOS/QuotaCardApp"
cp "$BIN_DIR/quota-card-ingest" "$CONTENTS/Helpers/quota-card-ingest"
cp "$ROOT_DIR/scripts/agy-statusline.sh" "$CONTENTS/Resources/scripts/"
cp "$ROOT_DIR/scripts/claude-statusline.sh" "$CONTENTS/Resources/scripts/"
cp "$ROOT_DIR/scripts/codex-ingest.sh" "$CONTENTS/Resources/scripts/"

chmod +x "$CONTENTS/MacOS/QuotaCardApp" "$CONTENTS/Helpers/quota-card-ingest" "$CONTENTS/Resources/scripts/"*.sh

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>QuotaCardApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.quotacard.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>QuotaCard</string>
    <key>CFBundleDisplayName</key>
    <string>QuotaCard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign locally so macOS Gatekeeper / launch services handle it cleanly
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
fi

echo "==> Done: $APP_BUNDLE"
ls -la "$CONTENTS/MacOS" "$CONTENTS/Helpers"
