#!/bin/zsh
set -euo pipefail
LEAF_ROOT=${0:A:h:h}
cd "$LEAF_ROOT"
LEAF_SDK=${LEAF_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}
swift run --sdk "$LEAF_SDK" LeafChecks
if command -v node >/dev/null; then
  node Scripts/bundle-engines.native-check.mjs
else
  print 'Node is not installed; bundled-engine probes were skipped.'
fi
if [[ ${LEAF_NATIVE_CHECKS:-0} == 1 ]]; then
  LEAF_CONFIG=${LEAF_CONFIG:-debug} "$LEAF_ROOT/Scripts/build.sh"
  LEAF_CHECK_OUTPUT=$(mktemp -d /tmp/leaf-native-checks.XXXXXX)
  "$LEAF_ROOT/build/Leaf.app/Contents/MacOS/Leaf" --check-native "$LEAF_CHECK_OUTPUT"
  print "Native check artifacts: $LEAF_CHECK_OUTPUT"
fi
