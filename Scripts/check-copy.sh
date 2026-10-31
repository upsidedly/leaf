#!/bin/zsh
set -euo pipefail
LEAF_ROOT=${0:A:h:h}
LEAF_CONFIG=${LEAF_CONFIG:-debug} "$LEAF_ROOT/Scripts/build.sh"
LEAF_CHECK_OUTPUT=$(mktemp -d /tmp/leaf-copy-checks.XXXXXX)
"$LEAF_ROOT/build/Leaf.app/Contents/MacOS/Leaf" --check-clipboard "$LEAF_CHECK_OUTPUT"
