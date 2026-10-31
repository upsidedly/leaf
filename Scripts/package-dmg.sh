#!/bin/zsh
set -euo pipefail
PROJECT_ROOT=${0:A:h:h}
cd "$PROJECT_ROOT"
if [[ ${1:-} != --no-build ]]; then ./Scripts/build.sh; fi
APP="$PROJECT_ROOT/build/Leaf.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Contents/Info.plist")"
OUTPUT="$PROJECT_ROOT/build/Leaf-$VERSION-arm64.dmg"
if [[ -e "$OUTPUT" ]]; then print -u2 "Release image already exists: $OUTPUT"; exit 1; fi
lipo "$APP/Contents/MacOS/$EXECUTABLE" -verify_arch arm64
codesign --verify --deep --strict "$APP"
if ! command -v uv >/dev/null; then print -u2 'DMG packaging requires uv to run pinned dmgbuild 1.6.7.'; exit 1; fi
uv tool run --from dmgbuild==1.6.7 dmgbuild \
    -s "$PROJECT_ROOT/Scripts/dmg-settings.py" -D "app=$APP" -D "resources=$PROJECT_ROOT/Scripts" \
    "Leaf $VERSION" "$OUTPUT"
hdiutil verify "$OUTPUT"
(cd "$PROJECT_ROOT/build" && shasum -a 256 "${OUTPUT:t}" > "${OUTPUT:t}.sha256")
print "Packaged $OUTPUT"
