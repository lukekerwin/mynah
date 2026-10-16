#!/usr/bin/env bash
# Package build/Mynah.app into dist/Mynah-<version>.dmg (run scripts/build_app.sh first).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
APP="$ROOT/build/Mynah.app"
[[ -d "$APP" ]] || { echo "build/Mynah.app not found — run scripts/build_app.sh" >&2; exit 1; }
mkdir -p "$ROOT/dist"
DMG="$ROOT/dist/Mynah-$VERSION.dmg"
rm -f "$DMG"
UV="${UV_BIN:-$ROOT/build/.uv-0.13.1/uv}"
"$UV" tool run --from "dmgbuild==1.6.7" dmgbuild -s "$ROOT/scripts/dmg_settings.py" \
    -D app="$APP" -D bg="$ROOT/assets/dmg-background.tiff" "Mynah $VERSION" "$DMG"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
