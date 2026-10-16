#!/usr/bin/env bash
# Regenerate app icon, menu-bar icon, README logo and DMG background from assets/*.svg.
# Outputs are committed, so this only needs re-running after editing an SVG.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
A="$ROOT/assets"; TMP="$(mktemp -d)"
render() { swift "$ROOT/scripts/render_svg.swift" "$@"; }

# App icon: Quick Look (WebKit) renders the drop shadow; AppKit doesn't.
qlmanage -t -s 1024 -o "$TMP" "$A/logo.svg" >/dev/null 2>&1
SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/logo.svg.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/logo.svg.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$A/AppIcon.icns"
sips -z 256 256 "$TMP/logo.svg.png" --out "$A/logo-256.png" >/dev/null

# Menu-bar template icon (18pt tall).
render "$A/menubar.svg" "$A/MenuBarIcon.png" 21 18
render "$A/menubar.svg" "$A/MenuBarIcon@2x.png" 42 36

# DMG window background (660x400 window, retina-aware TIFF).
render "$A/dmg-background.svg" "$TMP/bg.png" 660 400
render "$A/dmg-background.svg" "$TMP/bg@2x.png" 1320 800
tiffutil -cathidpicheck "$TMP/bg.png" "$TMP/bg@2x.png" -out "$A/dmg-background.tiff" >/dev/null 2>&1
rm -rf "$TMP"
echo "assets rendered into $A"
