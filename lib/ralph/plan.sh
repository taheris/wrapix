#!/usr/bin/env bash
set -euo pipefail

# ralph plan
# Interactive interview that creates formal specifications
# - Pins context by reading specs/README.md
# - Opens bypass permissions prompt for user to type idea
# - Runs iterative interview loop until user says "done"
# - Creates specs/<label>.md with full specification
# - Updates specs/README.md with new terminology and WIP entry

# Container detection: if not in container and wrapix is available, re-launch in container
# /etc/wrapix/claude-config.json only exists inside containers (baked into image)
if [ ! -f /etc/wrapix/claude-config.json ] && command -v wrapix &>/dev/null; then
  export RALPH_MODE=1
  export RALPH_CMD=plan
  export RALPH_ARGS="${*:-}"
  exec wrapix
fi

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
CONFIG_FILE="$RALPH_DIR/config.nix"
SPECS_DIR="specs"
SPECS_README="$SPECS_DIR/README.md"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: No ralph config found at $CONFIG_FILE"
  echo "Run 'ralph start' first to initialize."
  exit 1
fi

# Get label from state (created by ralph start)
LABEL_FILE="$RALPH_DIR/state/label"
if [ ! -f "$LABEL_FILE" ]; then
  echo "Error: No label file found. Run 'ralph start' first."
  exit 1
fi
LABEL=$(cat "$LABEL_FILE")

# Load config to check spec.hidden
CONFIG=$(nix eval --json --file "$CONFIG_FILE")
SPEC_HIDDEN=$(echo "$CONFIG" | jq -r '.spec.hidden // false')

# Compute spec path based on hidden flag
if [ "$SPEC_HIDDEN" = "true" ]; then
  SPEC_PATH="$RALPH_DIR/state/$LABEL.md"
  README_INSTRUCTIONS=""
else
  SPEC_PATH="$SPECS_DIR/$LABEL.md"
  README_INSTRUCTIONS="2. **Update specs/README.md**:
   - Add new terminology to the Terminology Index
   - Add WIP entry to Active Work table:
     \`\`\`
     | [$LABEL.md](./$LABEL.md) | (pending) | Brief purpose |
     \`\`\`"
fi

PROMPT_TEMPLATE="$RALPH_DIR/plan.md"
if [ ! -f "$PROMPT_TEMPLATE" ]; then
  echo "Error: Plan prompt template not found: $PROMPT_TEMPLATE"
  echo "Make sure plan.md exists in your ralph directory."
  exit 1
fi

mkdir -p "$RALPH_DIR/history" "$RALPH_DIR/logs" "$RALPH_DIR/state"

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

# Read template and substitute placeholders
PROMPT_CONTENT=$(cat "$PROMPT_TEMPLATE")
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{LABEL\}\}/$LABEL}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{SPEC_PATH\}\}/$SPEC_PATH}"

# Use awk for multi-line substitutions
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v ctx="$PINNED_CONTEXT" '{gsub(/\{\{PINNED_CONTEXT\}\}/, ctx); print}')
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v instr="$README_INSTRUCTIONS" '{gsub(/\{\{README_INSTRUCTIONS\}\}/, instr); print}')

LOG="$RALPH_DIR/logs/plan-interview-$(date +%Y%m%d-%H%M%S).log"

echo "=== Starting Interview ==="
echo ""
# Use script to preserve tty behavior while logging
# This keeps stdin/stdout as a terminal so Claude runs interactively
export PROMPT_CONTENT
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
