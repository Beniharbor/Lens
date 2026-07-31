#!/bin/bash
# Builds Lens and assembles Lens.app (no Xcode needed — SPM + manual bundling).
# Usage: Scripts/package.sh [debug|release] [install]
#   install: also copy to /Applications and relaunch
set -euo pipefail

CONFIG="${1:-release}"
INSTALL="${2:-}"
if [ "$CONFIG" = "install" ]; then CONFIG="release"; INSTALL="install"; fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Lens"
APP="build/Lens.app"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lens"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Lens.icns "$APP/Contents/Resources/Lens.icns"

# SPM resource bundles (e.g. KeyboardShortcuts localizations)
for bundle in .build/"$CONFIG"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# Stable identity keeps TCC permission grants across rebuilds (ad-hoc signatures
# change every build, making macOS re-prompt for Screen Recording each time).
# Reuses the self-signed "Vela Dev" identity from the Vela project — a personal
# codesigning cert isn't tied to one app, so it's fine to share across them.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Vela Dev"; then
  echo "==> Codesign with Vela Dev identity"
  codesign --force --deep --sign "Vela Dev" "$APP"
else
  echo "==> Ad-hoc codesign (Vela Dev identity not found — permissions will re-prompt after rebuilds)"
  codesign --force --deep --sign - "$APP"
fi

echo "==> Done: $ROOT/$APP"

if [ "$INSTALL" = "install" ]; then
  echo "==> Installing to /Applications"
  pkill -f "Lens.app/Contents/MacOS/Lens" 2>/dev/null || true
  # rm first: ditto merges into the existing bundle, which keeps the same
  # directory inode and leaves macOS's icon cache pointing at stale artwork.
  rm -rf /Applications/Lens.app
  ditto "$APP" /Applications/Lens.app
  touch /Applications/Lens.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Lens.app
  mdimport /Applications/Lens.app
  open /Applications/Lens.app
  echo "==> Installed and relaunched /Applications/Lens.app"
else
  echo "    Run with: open $ROOT/$APP   (or: Scripts/package.sh release install)"
fi
