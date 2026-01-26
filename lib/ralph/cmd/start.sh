#!/usr/bin/env bash
set -euo pipefail

# ralph start <label>
# Sets up for a new feature
# - Creates specs/ directory if needed
# - Creates specs/README.md from template if not exists
# - Clears previous plan state
# - Sets label in state
# - Substitutes placeholders in template files (LABEL, SPEC_PATH, etc.)

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
TEMPLATE="${RALPH_TEMPLATE_DIR:-/etc/wrapix/ralph-template}"
SPECS_DIR="specs"

# Label is required
if [ -z "${1:-}" ]; then
  echo "Error: Label is required"
  echo "Usage: ralph start <label>"
  echo ""
  echo "Example: ralph start user-auth"
  exit 1
fi
LABEL="$1"

# Ensure ralph directory structure exists
if [ ! -d "$RALPH_DIR" ]; then
  if [ ! -d "$TEMPLATE" ]; then
    echo "Error: Template directory not found at $TEMPLATE"
    echo "This usually means ralph is not properly installed."
    exit 1
  fi

  mkdir -p "$(dirname "$RALPH_DIR")"
  cp -r "$TEMPLATE" "$RALPH_DIR"
  # Fix permissions - Nix store files may be read-only
  chmod -R u+rwX "$RALPH_DIR"
  echo "Initialized ralph at $RALPH_DIR"
fi

# Ensure required directories exist
mkdir -p "$RALPH_DIR/history" "$RALPH_DIR/logs" "$RALPH_DIR/state"

# Create specs directory if not exists
if [ ! -d "$SPECS_DIR" ]; then
  mkdir -p "$SPECS_DIR"
  echo "Created $SPECS_DIR directory"
fi

# Create specs/README.md from template if not exists (never overwrite)
SPECS_README="$SPECS_DIR/README.md"
if [ ! -f "$SPECS_README" ]; then
  cat > "$SPECS_README" << 'EOF'
# Project Specifications

| Spec | Code | Purpose |
|------|------|---------|

## Terminology Index

| Term | Definition |
|------|------------|
EOF
  echo "Created $SPECS_README"
fi

# Clear previous state (but preserve prompts and config)
rm -f "$RALPH_DIR/state/label"

# Set new label
echo "$LABEL" > "$RALPH_DIR/state/label"

# Update config.nix with the label
CONFIG_FILE="$RALPH_DIR/config.nix"
if [ -f "$CONFIG_FILE" ]; then
  # Handle both null and previously set string values
  sed -i 's/label = null;/label = "'"$LABEL"'";/' "$CONFIG_FILE"
  sed -i 's/label = "[^"]*";/label = "'"$LABEL"'";/' "$CONFIG_FILE"
fi

# Load config to compute derived values
CONFIG=$(nix eval --json --file "$CONFIG_FILE")
DEFAULT_PRIORITY=$(echo "$CONFIG" | jq -r '.beads.priority // 2')
SPEC_HIDDEN=$(echo "$CONFIG" | jq -r '.spec.hidden // false')

# Compute spec path based on hidden flag
if [ "$SPEC_HIDDEN" = "true" ]; then
  SPEC_PATH="$RALPH_DIR/state/$LABEL.md"
  README_INSTRUCTIONS=""
  README_UPDATE_SECTION=""
else
  SPEC_PATH="$SPECS_DIR/$LABEL.md"
  README_INSTRUCTIONS="5. **Update specs/README.md** with the epic bead ID"
  README_UPDATE_SECTION="## Update specs/README.md

After creating the epic, update the WIP table entry with the bead ID:
\`\`\`markdown
| [$LABEL.md](./$LABEL.md) | beads-XXXXXX | Brief purpose |
\`\`\`"
fi

# Substitute placeholders in template files
# These are the placeholders that can be computed at start time
for template in "$RALPH_DIR"/*.md; do
  [ -f "$template" ] || continue

  # Substitute simple placeholders with sed
  sed -i "s|{{LABEL}}|$LABEL|g" "$template"
  sed -i "s|{{SPEC_PATH}}|$SPEC_PATH|g" "$template"
  sed -i "s|{{PRIORITY}}|$DEFAULT_PRIORITY|g" "$template"

  # For multi-line substitutions, use awk
  if grep -q '{{README_INSTRUCTIONS}}' "$template" 2>/dev/null; then
    awk -v replacement="$README_INSTRUCTIONS" '{gsub(/\{\{README_INSTRUCTIONS\}\}/, replacement); print}' "$template" > "$template.tmp"
    mv "$template.tmp" "$template"
  fi

  if grep -q '{{README_UPDATE_SECTION}}' "$template" 2>/dev/null; then
    awk -v replacement="$README_UPDATE_SECTION" '{gsub(/\{\{README_UPDATE_SECTION\}\}/, replacement); print}' "$template" > "$template.tmp"
    mv "$template.tmp" "$template"
  fi
done

echo ""
echo "Ralph started for feature: $LABEL"
echo ""
echo "State: $RALPH_DIR/state/label"
echo "Spec:  $SPEC_PATH"
echo ""
echo "Next steps:"
echo "  1. Run 'ralph plan' to conduct an interview and create the spec"
echo "  2. Run 'ralph ready' to convert spec to beads"
echo "  3. Run 'ralph step' or 'ralph loop' to work through issues"
