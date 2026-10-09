#!/bin/zsh
set -eu
PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/build/Release/Mogu.app"
if [[ "${1:-}" == "--preview" ]]; then APP_DIR="$PROJECT_DIR/build/Mogu Preview.app"; fi
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$PROJECT_DIR/build/module-cache"
if [[ ! -f "$PROJECT_DIR/Art/AppIcon.icns" || "$PROJECT_DIR/Sources/PixelUI.swift" -nt "$PROJECT_DIR/Art/AppIcon.icns" ]]; then
  mkdir -p "$PROJECT_DIR/build/icon-tool" "$PROJECT_DIR/Art"
  cp "$PROJECT_DIR/scripts/make-icon.swift" "$PROJECT_DIR/build/icon-tool/main.swift"
  swiftc -swift-version 5 -framework AppKit -module-cache-path "$PROJECT_DIR/build/module-cache" "$PROJECT_DIR/Sources/PixelUI.swift" "$PROJECT_DIR/build/icon-tool/main.swift" -o "$PROJECT_DIR/build/icon-tool/render-icon"
  "$PROJECT_DIR/build/icon-tool/render-icon" "$PROJECT_DIR/build/AppIcon.iconset"
  iconutil -c icns "$PROJECT_DIR/build/AppIcon.iconset" -o "$PROJECT_DIR/Art/AppIcon.icns"
fi
# Universal binary: Apple Silicon and Intel.
for ARCH in arm64 x86_64; do
  swiftc -swift-version 5 -target "$ARCH-apple-macosx13.0" -O -framework AppKit -module-cache-path "$PROJECT_DIR/build/module-cache" "$PROJECT_DIR"/Sources/MoguCore/*.swift "$PROJECT_DIR"/Sources/*.swift -o "$PROJECT_DIR/build/Mogu-$ARCH"
done
lipo -create "$PROJECT_DIR/build/Mogu-arm64" "$PROJECT_DIR/build/Mogu-x86_64" -output "$APP_DIR/Contents/MacOS/Mogu"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Art/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/PrivacyInfo.xcprivacy" "$APP_DIR/Contents/Resources/PrivacyInfo.xcprivacy"
if [[ "${1:-}" == "--preview" ]]; then
  plutil -replace CFBundleIdentifier -string jp.rikuto.mogu.preview "$APP_DIR/Contents/Info.plist"
  plutil -replace CFBundleName -string 'Mogu Preview' "$APP_DIR/Contents/Info.plist"
  plutil -insert MoguPreview -bool true "$APP_DIR/Contents/Info.plist"
fi
codesign --force --sign - --options runtime --entitlements "$PROJECT_DIR/Mogu.entitlements" "$APP_DIR"
echo "$APP_DIR"
