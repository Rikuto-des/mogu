#!/bin/zsh
# Builds Mogu.app and zips it for a GitHub release: build/Mogu-<version>-macOS.zip
set -eu
PROJECT_DIR="${0:A:h:h}"
zsh "$PROJECT_DIR/scripts/build.sh" >/dev/null
VERSION=$(plutil -extract CFBundleShortVersionString raw "$PROJECT_DIR/Info.plist")
ZIP="$PROJECT_DIR/build/Mogu-$VERSION-macOS.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$PROJECT_DIR/build/Release/Mogu.app" "$ZIP"
echo "$ZIP"
