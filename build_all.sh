#!/bin/bash
# Build both StakeLabHUD (Solo App) and StakeStream (Air-Gap Streaming Daemon)
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=============================================="
echo "  Building Complete Stake HUD & Stream Suite  "
echo "=============================================="

bash "$DIR/build_app.sh"
bash "$DIR/build_stream.sh"

echo ""
echo "🎉 All targets built successfully!"
echo "  1. Solo Grinder HUD:      /Applications/StakeLabHUD.app"
echo "  2. Live Stream Air-Gap:   $DIR/StakeStream"
