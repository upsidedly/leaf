#!/bin/zsh
set -euo pipefail
LEAF_ROOT=${0:A:h:h}
"$LEAF_ROOT/Scripts/build.sh"
if pgrep -x Leaf >/dev/null; then
  print -u2 'Quit Leaf before installing an update.'
  exit 1
fi
if [[ -d /Applications/Leaf.app ]]; then
  LEAF_BACKUP="$HOME/Library/Application Support/Leaf/Backups/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$LEAF_BACKUP"
  mv /Applications/Leaf.app "$LEAF_BACKUP/Leaf.app"
fi
ditto "$LEAF_ROOT/build/Leaf.app" /Applications/Leaf.app
codesign --verify --strict /Applications/Leaf.app
print 'Installed /Applications/Leaf.app'
