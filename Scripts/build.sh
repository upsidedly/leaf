#!/bin/zsh
set -euo pipefail
LEAF_ROOT=${0:A:h:h}
cd "$LEAF_ROOT"
LEAF_SDK=${LEAF_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}
LEAF_CONFIG=${LEAF_CONFIG:-release}
swift build -c "$LEAF_CONFIG" --sdk "$LEAF_SDK" --product Leaf
LEAF_BIN=$(swift build -c "$LEAF_CONFIG" --sdk "$LEAF_SDK" --show-bin-path)
LEAF_APP="$LEAF_ROOT/build/Leaf.app"
# Build a fresh package: merging bundles can retain obsolete renderer resources.
if [[ -d "$LEAF_APP" ]]; then
  LEAF_PREVIOUS=$(mktemp -d /tmp/leaf-previous.XXXXXX)
  mv "$LEAF_APP" "$LEAF_PREVIOUS/Leaf.app"
fi
mkdir -p "$LEAF_APP/Contents/MacOS" "$LEAF_APP/Contents/Resources"
cp "$LEAF_BIN/Leaf" "$LEAF_APP/Contents/MacOS/Leaf"
cp Assets/Info.plist "$LEAF_APP/Contents/Info.plist"
for LEAF_BUNDLE in "$LEAF_BIN"/*.bundle; do
  if [[ -e "$LEAF_BUNDLE" ]]; then
    ditto "$LEAF_BUNDLE" "$LEAF_APP/Contents/Resources/${LEAF_BUNDLE:t}"
  fi
done
if [[ -e Assets/AppIcon.icns ]]; then cp Assets/AppIcon.icns "$LEAF_APP/Contents/Resources/AppIcon.icns"; fi
cp THIRD_PARTY_NOTICES.md "$LEAF_APP/Contents/Resources/ThirdPartyNotices.md"
ditto Licenses "$LEAF_APP/Contents/Resources/Licenses"
mkdir -p "$LEAF_APP/Contents/Resources/Licenses/MarkdownEngine" "$LEAF_APP/Contents/Resources/Licenses/SwiftMath"
cp Vendor/MarkdownEngine/LICENSE "$LEAF_APP/Contents/Resources/Licenses/MarkdownEngine/"
cp Vendor/SwiftMath/LICENSE "$LEAF_APP/Contents/Resources/Licenses/SwiftMath/"
codesign --force --deep --sign - "$LEAF_APP"
codesign --verify --strict "$LEAF_APP"
plutil -lint "$LEAF_APP/Contents/Info.plist"
print "Built $LEAF_APP"
