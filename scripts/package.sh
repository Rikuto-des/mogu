#!/bin/zsh
# Builds Mogu.app signed with Developer ID, notarizes and staples it, and zips it for a GitHub release:
# build/Mogu-<version>-macOS.zip
# Needs a notarytool profile: xcrun notarytool store-credentials mogu-notary --apple-id <id> --team-id N2TW4R972L
set -eu
PROJECT_DIR="${0:A:h:h}"
export MOGU_SIGN_IDENTITY="${MOGU_SIGN_IDENTITY:-4615A6797600C71AEB77243D29879B5B635676E6}"
NOTARY_PROFILE="${MOGU_NOTARY_PROFILE:-mogu-notary}"
APP="$PROJECT_DIR/build/Release/Mogu.app"
zsh "$PROJECT_DIR/scripts/build.sh" >/dev/null
VERSION=$(plutil -extract CFBundleShortVersionString raw "$PROJECT_DIR/Info.plist")
ZIP="$PROJECT_DIR/build/Mogu-$VERSION-macOS.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait >&2
xcrun stapler staple "$APP" >&2
# Re-zip so the download carries the stapled ticket and opens offline.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
spctl --assess --type execute "$APP"
echo "$ZIP"
