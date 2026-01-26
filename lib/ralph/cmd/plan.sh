#!/usr/bin/env bash
set -euo pipefail

# ralph plan <label>
# Combined feature initialization and spec interview
# - Sets up ralph directory structure if needed
# - Creates specs/ directory if needed
# - Sets label in state
# - Substitutes placeholders in templates at runtime (fresh each run)
# - Conducts interactive spec interview
# - Creates spec file

# Container detection: if not in container and wrapix is available, re-launch in container
# /etc/wrapix/claude-config.json only exists inside containers (baked into image)
if [ ! -f /etc/wrapix/claude-config.json ] && command -v wrapix &>/dev/null; then
  export RALPH_MODE=1
  export RALPH_CMD=plan
  export RALPH_ARGS="${*:-}"
  exec wrapix
fi

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
TEMPLATE="${RALPH_TEMPLATE_DIR:-/etc/wrapix/ralph-template}"
SPECS_DIR="specs"
SPECS_README="$SPECS_DIR/README.md"

# Label can be passed as argument or read from state
LABEL="${1:-}"
LABEL_FILE="$RALPH_DIR/state/label"

# If no argument provided, try to read from state file
if [ -z "$LABEL" ] && [ -f "$LABEL_FILE" ]; then
  LABEL=$(cat "$LABEL_FILE")
fi

# Label is required
if [ -z "$LABEL" ]; then
  echo "Error: Label is required"
  echo "Usage: ralph plan <label>"
  echo ""
  echo "Example: ralph plan user-auth"
  echo ""
  echo "Or resume an existing plan by running 'ralph plan' after 'ralph plan <label>' was run."
  exit 1
fi

# Ensure ralph directory structure exists (idempotent)
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

# Set/update label in state
echo "$LABEL" > "$LABEL_FILE"

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

# Compute spec path and README instructions based on hidden flag
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

# Read template and substitute ALL placeholders at runtime (fresh each time)
PROMPT_TEMPLATE="$RALPH_DIR/plan.md"
if [ ! -f "$PROMPT_TEMPLATE" ]; then
  echo "Error: Plan prompt template not found: $PROMPT_TEMPLATE"
  echo "Make sure plan.md exists in your ralph directory."
  exit 1
fi

# Pin context from specs/README.md
PINNED_CONTEXT=""
if [ -f "$SPECS_README" ]; then
  PINNED_CONTEXT=$(cat "$SPECS_README")
fi

echo "Ralph Plan Interview starting..."
echo "  Label: $LABEL"
echo "  Spec: $SPEC_PATH"
echo "  Hidden: $SPEC_HIDDEN"
echo ""

# Read template content
PROMPT_CONTENT=$(cat "$PROMPT_TEMPLATE")

# Substitute all placeholders at runtime (this is the key fix - fresh substitution each time)
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{LABEL\}\}/$LABEL}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{SPEC_PATH\}\}/$SPEC_PATH}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{PRIORITY\}\}/$DEFAULT_PRIORITY}"

# Multi-line substitutions using awk
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v replacement="$README_INSTRUCTIONS" '{gsub(/\{\{README_INSTRUCTIONS\}\}/, replacement); print}')
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v replacement="$README_UPDATE_SECTION" '{gsub(/\{\{README_UPDATE_SECTION\}\}/, replacement); print}')
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v ctx="$PINNED_CONTEXT" '{gsub(/\{\{PINNED_CONTEXT\}\}/, ctx); print}')

LOG="$RALPH_DIR/logs/plan-interview-$(date +%Y%m%d-%H%M%S).log"

echo "=== Starting Interview ==="
echo ""
# Use script to preserve tty behavior while logging
# This keeps stdin/stdout as a terminal so Claude runs interactively
export PROMPT_CONTENT
# shellcheck disable=SC2016 # Variable expanded by subshell, not current shell
script -q -c 'claude --dangerously-skip-permissions "$PROMPT_CONTENT"' "$LOG"

# Check for completion
if grep -q "INTERVIEW_COMPLETE" "$LOG" 2>/dev/null; then
  echo ""
  echo "Interview complete. Specification created at: $SPEC_PATH"
  echo ""
  echo "Next steps:"
  echo "  1. Review the spec: cat $SPEC_PATH"
  echo "  2. Convert to beads: ralph ready"
else
  echo ""
  echo "Interview did not complete. Review log: $LOG"
  echo "To continue: ralph plan"
fi
