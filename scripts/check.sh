#!/bin/bash
# End-to-end checks against real add-ons: build, catalogs, details, streams, playback (AVPlayer and
# mpv), subtitles, persistence.
#
# Usage:
#   scripts/check.sh "<stream add-on manifest URL>"            # everything
#   scripts/check.sh "<manifest URL>" --only catalog,subtitles # just some groups
#   STREAM_ADDON_URL="<manifest URL>" scripts/check.sh
#
# Groups: setup, catalog, streams, quality, playback, mpv, subtitles, persistence.
# The manifest URL may contain a private token: it is never printed (only its host is).
set -uo pipefail
cd "$(dirname "$0")/.."

URL="${1:-${STREAM_ADDON_URL:-}}"
if [ -z "$URL" ]; then
  echo "Usage: scripts/check.sh \"<stream add-on manifest URL>\" [--only group,group]"
  exit 1
fi

echo "── Toolchain ───────────────────────────────"
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "🔴 FAIL  Swift toolchain   install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi
echo "🟢 PASS  Swift toolchain   $(swift --version 2>&1 | head -1)"
echo "🟢 PASS  Machine           $(uname -m) · macOS $(sw_vers -productVersion)"

echo
echo "── Build (release, arm64) ──────────────────"
LOG="$(mktemp -t foyer-build)"
if swift build -c release --arch arm64 >"$LOG" 2>&1; then
  echo "🟢 PASS  Build             $(grep -c 'warning:' "$LOG") warnings"
else
  echo "🔴 FAIL  Build"
  grep -E "error:" "$LOG" | head -30
  exit 1
fi

echo
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
"$BIN/checks" "$URL" "${@:2}"
