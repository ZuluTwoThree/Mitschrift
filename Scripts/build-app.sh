#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/.build}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/dist}"
MODELS_DIR="${MODELS_DIR:-$PROJECT_DIR/Models}"
SDK_PATH="${SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
APP_DIR="$OUTPUT_DIR/Mitschrift.app"
CONTENTS_DIR="$APP_DIR/Contents"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"

for model in base small; do
  if [[ ! -f "$MODELS_DIR/ggml-$model.bin" ]]; then
    echo "Fehlendes Modell: $MODELS_DIR/ggml-$model.bin" >&2
    echo "Starte zuerst: zsh Scripts/download-models.sh" >&2
    exit 1
  fi
done

mkdir -p "$BUILD_DIR/module-cache" "$ICONSET_DIR" "$CONTENTS_DIR/MacOS" "$RESOURCES_DIR/models"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

swiftc \
  -sdk "$SDK_PATH" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -parse-as-library \
  -framework AppKit \
  "$PROJECT_DIR/Sources/IconMaker.swift" \
  -o "$BUILD_DIR/IconMaker"
"$BUILD_DIR/IconMaker" "$BUILD_DIR/AppIcon-1024.png"

sips -z 16 16 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
cp "$BUILD_DIR/AppIcon-1024.png" "$ICONSET_DIR/icon_512x512@2x.png"

swiftc \
  -sdk "$SDK_PATH" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -parse-as-library \
  "$PROJECT_DIR/Sources/ICNSMaker.swift" \
  -o "$BUILD_DIR/ICNSMaker"
"$BUILD_DIR/ICNSMaker" "$ICONSET_DIR" "$RESOURCES_DIR/AppIcon.icns"

swiftc \
  -sdk "$SDK_PATH" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -parse-as-library \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  -framework AVFoundation \
  -framework UniformTypeIdentifiers \
  "$PROJECT_DIR/Sources/MitschriftApp.swift" \
  -o "$CONTENTS_DIR/MacOS/Mitschrift"

cp "$MODELS_DIR/ggml-base.bin" "$RESOURCES_DIR/models/ggml-base.bin"
cp "$MODELS_DIR/ggml-small.bin" "$RESOURCES_DIR/models/ggml-small.bin"
codesign --force --deep --sign - "$APP_DIR"

echo "App erstellt: $APP_DIR"
