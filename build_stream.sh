#!/bin/bash
# StakeStream — Headless Air-Gap Engine build (Zero-Window Streaming Daemon)
# Target: Stake.com in Floorp browser + OBS WebSocket auto-pause + Web Dashboard
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/StakeStream"

echo ""
echo "=== Building StakeStream (Headless Air-Gap Engine) ==="
echo ""

echo "→ Compiling Swift (StakeCommon + StakeNativeWatcher + StakeStream)..."
swiftc \
    "$DIR/StakeCommon.swift" \
    "$DIR/StakeNativeWatcher.swift" \
    "$DIR/StakeStream.swift" \
    -o "$BIN" \
    -lsqlite3 \
    -framework AppKit \
    -framework Foundation \
    -framework CryptoKit \
    -framework Vision \
    -framework CoreImage

if [ ! -f "$BIN" ]; then
    echo "❌ Compile failed — binary missing"
    exit 1
fi

chmod +x "$BIN"
echo "→ Binary compiled OK: $BIN"

# Ad-hoc sign for local ScreenCapture permission stability
codesign --force --deep --sign - "$BIN" 2>/dev/null || true

echo ""
echo "✅ StakeStream built successfully at: $BIN"
echo ""
echo "To run:"
echo "  $BIN"
echo ""
echo "Air-Gap Web Dashboard will be live at: http://localhost:8765"
echo "Open on your Mac mini (3rd monitor) or iPhone via your iMac IP: http://<iMac-IP>:8765"
