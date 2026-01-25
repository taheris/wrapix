#!/usr/bin/env bash
set -euo pipefail

# ralph ready
# Converts spec to beads with task breakdown
# - Pins context by reading specs/README.md
# - Reads current spec from state
# - Analyzes spec and creates task breakdown
# - Creates parent/epic bead, then child tasks
# - Updates specs/README.md WIP table with parent bead ID

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
CONFIG_FILE="$RALPH_DIR/config.nix"
SPECS_DIR="specs"
SPECS_README="$SPECS_DIR/README.md"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: No ralph config found at $CONFIG_FILE"
  echo "Run 'ralph start' first."
  exit 1
fi

# Get label from state
LABEL_FILE="$RALPH_DIR/state/label"
if [ ! -f "$LABEL_FILE" ]; then
  echo "Error: No label file found. Run 'ralph start' first."
  exit 1
fi
LABEL=$(cat "$LABEL_FILE")

# Get spec name from state
SPEC_FILE="$RALPH_DIR/state/spec"
if [ ! -f "$SPEC_FILE" ]; then
  echo "Error: No spec file reference found. Run 'ralph start' first."
  exit 1
fi
SPEC_NAME=$(cat "$SPEC_FILE")

# Check spec file exists
SPEC_PATH="$SPECS_DIR/$SPEC_NAME.md"
if [ ! -f "$SPEC_PATH" ]; then
  echo "Error: Spec file not found: $SPEC_PATH"
  echo "Run 'ralph plan' first to create the specification."
  exit 1
fi

# Load config as JSON once
CONFIG=$(nix eval --json --file "$CONFIG_FILE")
DEFAULT_PRIORITY=$(echo "$CONFIG" | jq -r '.beads.priority // 2')

PROMPT_TEMPLATE="$RALPH_DIR/ready.md"
if [ ! -f "$PROMPT_TEMPLATE" ]; then
  echo "Error: Ready prompt template not found: $PROMPT_TEMPLATE"
  echo "Make sure ready.md exists in your ralph directory."
  exit 1
fi

mkdir -p "$RALPH_DIR/logs"

# Pin context from specs/README.md
PINNED_CONTEXT=""
if [ -f "$SPECS_README" ]; then
  PINNED_CONTEXT=$(cat "$SPECS_README")
fi

# Extract title from spec file (first heading)
SPEC_TITLE=$(grep -m 1 '^#' "$SPEC_PATH" | sed 's/^#* *//' || echo "$SPEC_NAME")

echo "Ralph Ready: Converting spec to beads..."
echo "  Label: $LABEL"
echo "  Spec: $SPEC_PATH"
echo "  Title: $SPEC_TITLE"
echo ""

# Read template and substitute placeholders
PROMPT_CONTENT=$(cat "$PROMPT_TEMPLATE")
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{LABEL\}\}/$LABEL}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{SPEC_NAME\}\}/$SPEC_NAME}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{SPEC_PATH\}\}/$SPEC_PATH}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{PRIORITY\}\}/$DEFAULT_PRIORITY}"

# Use sed for title substitution (handle special chars)
ESCAPED_TITLE=$(printf '%s\n' "$SPEC_TITLE" | sed 's/[&/\]/\\&/g')
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | sed "s/{{SPEC_TITLE}}/$ESCAPED_TITLE/g")

# Use awk for multi-line pinned context substitution
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v ctx="$PINNED_CONTEXT" '{gsub(/\{\{PINNED_CONTEXT\}\}/, ctx); print}')

LOG="$RALPH_DIR/logs/ready-$(date +%Y%m%d-%H%M%S).log"

echo "=== Creating Task Breakdown ==="
echo ""
echo "$PROMPT_CONTENT" | claude --dangerously-skip-permissions 2>&1 | tee "$LOG"

# Check for completion
if grep -q "READY_COMPLETE" "$LOG" 2>/dev/null; then
  echo ""
  echo "Task breakdown complete!"
  echo ""
  echo "To list created issues:"
  echo "  bd list --label rl-$LABEL"
  echo ""
  echo "To work through issues:"
  echo "  ralph step      # Work one issue at a time"
  echo "  ralph loop      # Work all issues automatically"
else
  echo ""
  echo "Task breakdown did not complete. Review log: $LOG"
  echo "To retry: ralph ready"
fi
