#!/usr/bin/env bash
# Build a self-contained Mynah.app into build/.
#
#   scripts/build_app.sh             # build
#   scripts/build_app.sh --install   # build, then copy to /Applications and relaunch
#
# The app bundles the engine source + lockfile and a pinned `uv` binary; on first
# launch it creates its own Python environment in ~/.local/share/mynah.
#
# Signing: set MYNAH_SIGN_IDENTITY to a code-signing identity to get a stable
# signature (macOS keys Microphone/Accessibility grants to it). Otherwise the app
# is ad-hoc signed, which is what public release builds use.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Mynah"
BUNDLE_ID="com.lukekerwin.mynah"
VERSION="$(cat "$ROOT/VERSION")"
# Sparkle (in-app updates) reads this appcast and checks downloads against this
# EdDSA public key. The private key is the SPARKLE_ED_PRIVATE_KEY repo secret.
FEED_URL="https://raw.githubusercontent.com/lukekerwin/mynah/appcast/appcast.xml"
SPARKLE_PUBLIC_KEY="t/RvlKmBnJ0FdnNVKcg0prkEH2BZg/T7j2uwitMGBho="
# Pinned uv, bundled into the app (it builds the engine's Python environment).
UV_VERSION="0.13.1"
UV_SHA256="cfe454573412ff7380d15fc7dae5997ab53ffce72fce0a78e91ddbc84001acd2"
UV_DIR="$ROOT/build/.uv-$UV_VERSION"
UV_BIN="$UV_DIR/uv"
if [[ ! -x "$UV_BIN" ]]; then
    echo "==> Fetching uv $UV_VERSION"
    mkdir -p "$UV_DIR"
    curl -fsSL "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-aarch64-apple-darwin.tar.gz" -o "$UV_DIR/uv.tgz"
    echo "$UV_SHA256  $UV_DIR/uv.tgz" | shasum -a 256 -c - >/dev/null
    tar -xzf "$UV_DIR/uv.tgz" -C "$UV_DIR" --strip-components 1
    rm "$UV_DIR/uv.tgz"
fi

echo "==> Checking engine lockfile"
(cd "$ROOT/engine" && "$UV_BIN" lock --check --quiet)

echo "==> Building Swift app $VERSION"
(cd "$ROOT/app" && swift build -c release --arch arm64 --quiet)
BIN="$(cd "$ROOT/app" && swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"

OUT="$ROOT/build/$APP_NAME.app"
RES="$OUT/Contents/Resources"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Frameworks" "$RES/engine" "$RES/bin"
cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"
# Sparkle ships signed by its developers; copy it as-is (ditto keeps the symlinks).
ditto "$(dirname "$BIN")/Sparkle.framework" "$OUT/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$OUT/Contents/MacOS/$APP_NAME"

echo "==> Bundling engine + uv"
cp "$ROOT/engine/pyproject.toml" "$ROOT/engine/uv.lock" "$ROOT/engine/README.md" "$RES/engine/"
rsync -a --exclude '__pycache__' --exclude '*.pyc' "$ROOT/engine/src" "$RES/engine/"
cp "$UV_BIN" "$RES/bin/uv"
cp "$ROOT/assets/AppIcon.icns" "$ROOT/assets/MenuBarIcon.png" "$ROOT/assets/MenuBarIcon@2x.png" "$RES/"
cp "$ROOT/LICENSE" "$RES/"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Luke Kerwin. MIT License.</string>
    <key>NSMicrophoneUsageDescription</key><string>Mynah listens while you hold the dictation key and transcribes your speech locally on this Mac.</string>
    <key>NSAudioCaptureUsageDescription</key><string>Mynah records the audio of calls you choose to capture so it can transcribe them locally on this Mac.</string>
</dict>
</plist>
PLIST

echo "==> Signing"
IDENTITY="${MYNAH_SIGN_IDENTITY:--}"
[[ "$IDENTITY" == "-" ]] && echo "    ad-hoc (set MYNAH_SIGN_IDENTITY for a stable local signature)"
codesign --force --sign "$IDENTITY" "$RES/bin/uv"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$OUT"
codesign --verify --deep --strict "$OUT"
echo "Built $OUT ($(du -sh "$OUT" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    pkill -x "$APP_NAME" 2>/dev/null && sleep 1 || true
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$OUT" "/Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
fi
