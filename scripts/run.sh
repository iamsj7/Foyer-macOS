#!/bin/bash
# Builds (release, Apple Silicon) and launches the app from the build folder.
# Usage: scripts/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▶ Building (release, arm64)…"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
echo "▶ Launching"
exec "$BIN/Foyer"
