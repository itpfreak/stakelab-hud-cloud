#!/bin/bash
# Stake Lab HUD — Native Swift build (zero Python)
# Target: Stake.com in Floorp browser
set -e

APP="/Applications/StakeLabHUDCloud.app"
ALT_APP="$HOME/Applications/StakeLabHUDCloud.app"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_BUILD_APP="$SCRIPT_DIR/build/StakeLabHUDCloud.app"
REPO_ROOT_APP="$SCRIPT_DIR/StakeLabHUDCloud.app"
DOWNLOADS_APP="$HOME/Downloads/StakeLabHUDCloud.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
BUILD_ID="stakelab-cloud-gemini-direct-6458565"

echo ""
echo "=== Building Stake Lab HUD (Native Swift / Local Qwen) ==="
echo "Build ID: $BUILD_ID"
echo ""

pkill -9 StakeLabHUDCloud 2>/dev/null || true
rm -rf "$APP" "$ALT_APP" "$REPO_BUILD_APP" "$REPO_ROOT_APP" "$DOWNLOADS_APP"
mkdir -p "$MACOS" "$RES"

echo "→ Compiling Swift (StakeCommon + StakeLabHUDCloud + StakeNativeWatcher)..."
swiftc \
    StakeCommon.swift \
    StakeLabHUD.swift \
    StakeNativeWatcher.swift \
    -o "$MACOS/StakeLabHUDCloud" \
    -lsqlite3 \
    -framework AppKit \
    -framework Foundation \
    -framework CryptoKit \
    -framework Vision \
    -framework CoreImage

if [ ! -f "$MACOS/StakeLabHUDCloud" ]; then
    echo "❌ Compile failed — binary missing"
    exit 1
fi
echo "→ Binary compiled OK"

echo "→ Writing Info.plist..."
cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>StakeLabHUDCloud</string>
    <key>CFBundleIdentifier</key>
    <string>com.stakelab.hud.cloud</string>
    <key>CFBundleName</key>
    <string>StakeLabHUDCloud</string>
    <key>CFBundleDisplayName</key>
    <string>Stake Lab HUD Cloud</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Stake Lab HUD needs Screen Recording to read the Stake.com poker table in Floorp.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Stake Lab HUD needs Automation access to track the Floorp browser window position.</string>
</dict>
</plist>
PLIST

echo "→ Ad-hoc code signing cleanly..."
codesign --force --deep --sign - "$APP"
if ! codesign --verify --deep --strict --verbose=2 "$APP"; then
    echo "❌ Code-signature verification failed"
    exit 1
fi

echo "→ Clearing quarantine..."
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "→ Registering with LaunchServices..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" 2>/dev/null || true

echo ""
echo "✅ StakeLabHUDCloud.app built at $APP"
echo ""
echo "First launch: right-click → Open to bypass Gatekeeper"
echo "Then grant Screen Recording in System Settings → Privacy"
echo ""
