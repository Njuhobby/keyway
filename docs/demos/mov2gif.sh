#!/usr/bin/env bash
# Convert a screen recording into an optimized GIF for the README.
#
# Usage:
#   docs/demos/mov2gif.sh <input.mov> <name>
# Example:
#   docs/demos/mov2gif.sh ~/Desktop/rec.mov hero    # → docs/demos/hero.gif
#
# Defaults: 18 fps, 900px wide, quality 90. Override per-run:
#   FPS=15 WIDTH=720 docs/demos/mov2gif.sh ~/Desktop/rec.mov electron
set -euo pipefail
cd "$(dirname "$0")/../.."            # repo root

IN="${1:?usage: mov2gif.sh <input.mov> <name>}"
NAME="${2:?usage: mov2gif.sh <input.mov> <name>}"
FPS="${FPS:-18}"
WIDTH="${WIDTH:-900}"
OUT="docs/demos/${NAME}.gif"

command -v gifski >/dev/null || { echo "gifski not found — run: brew install gifski"; exit 1; }

echo "==> $IN → $OUT  (${WIDTH}px, ${FPS}fps)"
# Recent gifski reads video directly. If your build lacks video support,
# install ffmpeg and gifski will use it automatically.
gifski --fps "$FPS" --width "$WIDTH" --quality 90 -o "$OUT" "$IN"

ls -lh "$OUT" | awk '{print "    "$5"  "$9}'
echo "    Done. Uncomment this demo's <img> line in README.md to show it."
