#!/bin/zsh
# Build the Galactic Odyssey screensaver and preview harness.
# Usage: ./build.sh [preview|install]
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build

SHARED_SRC=(Sources/ShaderSource.swift Sources/Uniforms.swift Sources/Director.swift Sources/Renderer.swift Sources/HUD.swift)

echo "==> building preview harness"
swiftc -O -swift-version 5 -target arm64-apple-macos13 \
    "${SHARED_SRC[@]}" Harness/main.swift \
    -framework Metal -framework MetalKit -framework CoreGraphics -framework ImageIO -framework AppKit -framework QuartzCore \
    -o build/preview

echo "==> building saver dylib (arm64)"
swiftc -O -wmo -swift-version 5 -parse-as-library -target arm64-apple-macos13 \
    -emit-library \
    "${SHARED_SRC[@]}" Sources/SaverView.swift \
    -framework ScreenSaver -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore \
    -o build/GalacticOdyssey-arm64

if swiftc -O -wmo -swift-version 5 -parse-as-library -target x86_64-apple-macos13 \
    -emit-library \
    "${SHARED_SRC[@]}" Sources/SaverView.swift \
    -framework ScreenSaver -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore \
    -o build/GalacticOdyssey-x86_64 2>/dev/null; then
  lipo -create build/GalacticOdyssey-arm64 build/GalacticOdyssey-x86_64 -output build/GalacticOdyssey-bin
  echo "==> universal binary"
else
  cp build/GalacticOdyssey-arm64 build/GalacticOdyssey-bin
  echo "==> arm64-only binary (x86_64 build unavailable)"
fi

echo "==> assembling bundle"
SAVER=build/GalacticOdyssey.saver
rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
cp Info.plist "$SAVER/Contents/Info.plist"
cp build/GalacticOdyssey-bin "$SAVER/Contents/MacOS/GalacticOdyssey"
if [[ -f Preview/04_galaxy_mid.png ]]; then
  sips -Z 600 Preview/04_galaxy_mid.png --out "$SAVER/Contents/Resources/thumbnail.png" >/dev/null 2>&1 || true
fi
# bundle verified NASA seed images (deep-field scenes) + credits + license
if ls SeedImages/*.jpg >/dev/null 2>&1; then
  mkdir -p "$SAVER/Contents/Resources/SeedImages"
  cp SeedImages/*.jpg "$SAVER/Contents/Resources/SeedImages/"
  [[ -f SeedImages/CREDITS.md ]] && cp SeedImages/CREDITS.md "$SAVER/Contents/Resources/SeedImages/"
fi
[[ -f LICENSE ]] && cp LICENSE "$SAVER/Contents/Resources/"
codesign --force --sign - "$SAVER"
echo "==> built $SAVER"

if [[ "${1:-}" == "preview" ]]; then
  ./build/preview Preview
fi

if [[ "${1:-}" == "install" ]]; then
  DEST="$HOME/Library/Screen Savers"
  mkdir -p "$DEST"
  rm -rf "$DEST/GalacticOdyssey.saver"
  cp -R "$SAVER" "$DEST/"
  echo "==> installed to $DEST/GalacticOdyssey.saver"
  # re-assert selection for ALL displays/spaces (System Settings sometimes
  # rewrites entries with a provider that can't host legacy .saver bundles).
  # Set SKIP_SELECT=1 to install without changing your screensaver selection.
  if [[ "${SKIP_SELECT:-0}" != "1" ]]; then
    python3 select_saver.py && killall WallpaperAgent 2>/dev/null || true
    killall legacyScreenSaver 2>/dev/null || true
    echo "==> selected as screensaver on all displays (SKIP_SELECT=1 to opt out)"
  fi
fi
