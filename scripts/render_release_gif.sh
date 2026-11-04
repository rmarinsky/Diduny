#!/bin/bash
# Render the release "What's new" GIF from release-demo/scenario.js (played by release-demo/player.html).
# One headless Chrome captures frames deterministically; ffmpeg builds a palette-optimised looping GIF.
#
#   scripts/render_release_gif.sh [out.gif] [fps]
#   default out: Diduny/Resources/ReleaseDemo.gif — bundled for the in-app What's New card,
#   attached to the GitHub Release by release.yml, and embedded in the release PR.
# Needs: node, ffmpeg, Google Chrome (override with CHROME=/path/to/chrome).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/Diduny/Resources/ReleaseDemo.gif}"
FPS="${2:-15}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

node "$ROOT/scripts/render_release_frames.mjs" "file://$ROOT/release-demo/player.html" "$TMP" "$FPS" "$CHROME"

ffmpeg -loglevel error -y -framerate "$FPS" -i "$TMP/f%05d.png" \
  -vf "palettegen=stats_mode=diff:max_colors=128" "$TMP/palette.png"
ffmpeg -loglevel error -y -framerate "$FPS" -i "$TMP/f%05d.png" -i "$TMP/palette.png" \
  -lavfi "paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" -loop 0 "$OUT"

SIZE=$(stat -f%z "$OUT")
echo "$OUT $(( SIZE / 1024 )) KB"
[ "$SIZE" -le 4000000 ] || echo "warning: over 4 MB — lower fps or shorten scenes" >&2
