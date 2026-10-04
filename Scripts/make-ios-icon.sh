#!/bin/zsh
# Erzeugt das iOS-App-Icon aus Tools/IOSIconMaker.swift nach ios/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png.
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/.build}"
OUT="$PROJECT_DIR/ios/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
mkdir -p "$BUILD_DIR/module-cache" "$(dirname "$OUT")"
swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path "$BUILD_DIR/module-cache" \
  -parse-as-library -framework AppKit "$PROJECT_DIR/Tools/IOSIconMaker.swift" -o "$BUILD_DIR/IOSIconMaker"
"$BUILD_DIR/IOSIconMaker" "$OUT"
echo "Icon erzeugt: $OUT"
