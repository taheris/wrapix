#!/usr/bin/env bash
set -euo pipefail

DEST="${1:-.claude/ralph}"
TEMPLATE="${RALPH_TEMPLATE_DIR:-/etc/wrapix/ralph-template}"

if [ -d "$DEST" ]; then
  echo "Ralph already initialized at $DEST"
  echo "To reinitialize, remove the directory first: rm -rf $DEST"
  exit 1
fi

if [ ! -d "$TEMPLATE" ]; then
  echo "Error: Template directory not found at $TEMPLATE"
  echo "This usually means ralph is not properly installed."
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
cp -r "$TEMPLATE" "$DEST"
mkdir -p "$DEST/history" "$DEST/logs" "$DEST/state"
touch "$DEST/state/plan.md"

echo "Initialized ralph at $DEST"
echo ""
echo "Next steps:"
echo "  1. Edit prompts in $DEST/prompts/"
echo "  2. Adjust config in $DEST/config.nix"
echo "  3. Run 'ralph-loop' to start (mode=plan by default)"
