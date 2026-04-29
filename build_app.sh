#!/bin/bash
# build_app.sh — Build NetWatch.app and install to /Applications
# Usage: ./build_app.sh [--debug] [--no-install]
# After first run: open /Applications/NetWatch.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="NetWatch"
BUNDLE_ID="com.louisswingrover.netwatch"
CONFIG="release"
NO_INSTALL=false

for arg in "$@"; do
  case "$arg" in
    --debug)      CONFIG="debug" ;;
    --no-install) NO_INSTALL=true ;;
  esac
done

INSTALL_DIR="/Applications"
APP_BUNDLE="$APP_NAME.app"
BUILD_DIR="$SCRIPT_DIR/.build"
BINARY="$BUILD_DIR/$CONFIG/$APP_NAME"
TMP_APP="/tmp/$APP_BUNDLE"

# ── 1. Build ───────────────────────────────────────────────────────────────────
echo ""
echo "▶ Building $APP_NAME ($CONFIG)..."
cd "$SCRIPT_DIR"
swift build -c "$CONFIG" 2>&1 | grep -E "error:|warning:|Build complete|Compiling" || true

if [[ ! -f "$BINARY" ]]; then
  echo "❌  Build failed — binary not found at $BINARY"
  exit 1
fi
echo "✅  Build complete: $BINARY"

# ── 2. Icon ────────────────────────────────────────────────────────────────────
ICON_DIR="/tmp/netwatch_icon_build"
ICNS_PATH="$ICON_DIR/AppIcon.icns"

echo ""
echo "▶ Generating app icon..."
swift "$SCRIPT_DIR/make_icon.swift" "$ICON_DIR" 2>/dev/null && \
  echo "✅  Icon generated" || \
  echo "⚠️   Icon generation skipped — generic icon will be used"

# ── 3. Assemble .app bundle ────────────────────────────────────────────────────
echo ""
echo "▶ Assembling $APP_BUNDLE..."
rm -rf "$TMP_APP"
mkdir -p "$TMP_APP/Contents/MacOS"
mkdir -p "$TMP_APP/Contents/Resources"

# Binary
cp "$BINARY" "$TMP_APP/Contents/MacOS/$APP_NAME"
chmod +x "$TMP_APP/Contents/MacOS/$APP_NAME"

# Info.plist (lives in support/ — not inside SPM resources, which forbids it)
cp "$SCRIPT_DIR/support/Info.plist" "$TMP_APP/Contents/Info.plist"

# Resource bundle (SPM compiles resources alongside the binary)
RESOURCE_BUNDLE="$BUILD_DIR/$CONFIG/NetWatch_NetWatch.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$TMP_APP/Contents/Resources/"
  echo "   ✓ Resource bundle copied"
fi

# App icon
if [[ -f "$ICNS_PATH" ]]; then
  cp "$ICNS_PATH" "$TMP_APP/Contents/Resources/AppIcon.icns"
  echo "   ✓ AppIcon.icns installed"
fi

echo "✅  Bundle assembled at $TMP_APP"

# ── 4. Ad-hoc code sign ────────────────────────────────────────────────────────
echo ""
echo "▶ Signing (ad-hoc)..."
codesign \
  --sign - \
  --force \
  --deep \
  --timestamp=none \
  --identifier "$BUNDLE_ID" \
  --options runtime \
  "$TMP_APP" 2>&1 | grep -v "replacing existing" || true
echo "✅  Signed"

# ── 5. Install ─────────────────────────────────────────────────────────────────
if [[ "$NO_INSTALL" == true ]]; then
  echo ""
  echo "▶ --no-install: app is at $TMP_APP"
  echo "   Run with: open '$TMP_APP'"
  exit 0
fi

echo ""
echo "▶ Installing to $INSTALL_DIR/$APP_BUNDLE..."
if [[ -d "$INSTALL_DIR/$APP_BUNDLE" ]]; then
  # Quit running instance if any
  osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
  sleep 0.5
  rm -rf "$INSTALL_DIR/$APP_BUNDLE"
fi
cp -R "$TMP_APP" "$INSTALL_DIR/"
echo "✅  Installed"

# ── 6. Register with Launch Services ──────────────────────────────────────────
echo ""
echo "▶ Registering with Launch Services..."
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -f "$INSTALL_DIR/$APP_BUNDLE" 2>/dev/null || true
echo "✅  Registered"

# ── 7. Launch ─────────────────────────────────────────────────────────────────
echo ""
echo "▶ Launching $APP_NAME..."
open "$INSTALL_DIR/$APP_BUNDLE"

echo ""
echo "╔════════════════════════════════════════════╗"
echo "║  NetWatch installed to /Applications  ✅   ║"
echo "║                                            ║"
echo "║  Drag to your Dock from /Applications      ║"
echo "║  or: open /Applications/NetWatch.app       ║"
echo "╚════════════════════════════════════════════╝"
