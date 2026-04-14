#!/usr/bin/env bash
# Promote staged gc layout (.gc/.staged/) to live (.gc/).
#
# stageGcLayout writes formulas and scripts into .gc/.staged/ so a
# running city is never disturbed by a devShell reload. This script
# atomically swaps the staged content into the live paths, which gc
# detects via fsnotify and reloads on the next tick.
#
# Safe to call when no staged content exists (no-op) or when no city
# is running (first-time setup).
set -euo pipefail

_promote_dir() {
  local staged="$1" live="$2"
  [ -d "$staged" ] || return 0
  _old="${live}-old.$$"
  mv "$live" "$_old" 2>/dev/null || true
  mv "$staged" "$live"
  rm -rf "$_old"
}

_promote_dir .gc/.staged/formulas .gc/formulas
_promote_dir .gc/.staged/scripts  .gc/scripts
rmdir .gc/.staged 2>/dev/null || true
