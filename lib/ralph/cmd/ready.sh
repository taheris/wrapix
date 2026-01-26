#!/usr/bin/env bash
set -euo pipefail

# ralph ready
# Converts spec to beads with task breakdown
# - Pins context by reading specs/README.md
# - Reads current spec from state
# - Analyzes spec and creates task breakdown
# - Creates parent/epic bead, then child tasks
# - Updates specs/README.md WIP table with parent bead ID
# - Finalizes spec to specs/ (stripping Implementation Notes section)

# Container detection: if not in container and wrapix is available, re-launch in container
# /etc/wrapix/claude-config.json only exists inside containers (baked into image)
if [ ! -f /etc/wrapix/claude-config.json ] && command -v wrapix &>/dev/null; then
  export RALPH_MODE=1
  export RALPH_CMD=ready
  export RALPH_ARGS="${*:-}"
  exec wrapix
fi

# Load shared helpers
# shellcheck source=util.sh
source "$(dirname "$0")/util.sh"

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
CONFIG_FILE="$RALPH_DIR/config.nix"
SPECS_DIR="specs"
SPECS_README="$SPECS_DIR/README.md"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: No ralph config found at $CONFIG_FILE"
  echo "Run 'ralph plan <label>' first."
  exit 1
fi

# Get label from state
LABEL_FILE="$RALPH_DIR/state/label"
if [ ! -f "$LABEL_FILE" ]; then
  echo "Error: No label file found. Run 'ralph plan <label>' first."
  exit 1
fi
LABEL=$(cat "$LABEL_FILE")

# Load config to check spec.hidden and get priority
CONFIG=$(nix eval --json --file "$CONFIG_FILE")
SPEC_HIDDEN=$(echo "$CONFIG" | jq -r '.spec.hidden // false')
DEFAULT_PRIORITY=$(echo "$CONFIG" | jq -r '.beads.priority // 2')

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

# Check spec file exists
if [ ! -f "$SPEC_PATH" ]; then
  echo "Error: Spec file not found: $SPEC_PATH"
  echo "Run 'ralph plan' first to create the specification."
  exit 1
fi

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

# Read template content (placeholders are substituted at runtime)
PROMPT_CONTENT=$(cat "$PROMPT_TEMPLATE")

# Substitute all placeholders at runtime
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{LABEL\}\}/$LABEL}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{SPEC_PATH\}\}/$SPEC_PATH}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{PRIORITY\}\}/$DEFAULT_PRIORITY}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{SPEC_TITLE\}\}/$SPEC_TITLE}"

# Multi-line substitutions using awk
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v replacement="$README_INSTRUCTIONS" '{gsub(/\{\{README_INSTRUCTIONS\}\}/, replacement); print}')
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v replacement="$README_UPDATE_SECTION" '{gsub(/\{\{README_UPDATE_SECTION\}\}/, replacement); print}')
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v ctx="$PINNED_CONTEXT" '{gsub(/\{\{PINNED_CONTEXT\}\}/, ctx); print}')

LOG="$RALPH_DIR/logs/ready-$(date +%Y%m%d-%H%M%S).log"

echo "=== Creating Task Breakdown ==="
echo ""
# Use stream-json for real-time output display
# --print with text format buffers until completion; stream-json streams each message
export PROMPT_CONTENT
claude --dangerously-skip-permissions --print --output-format stream-json --verbose "$PROMPT_CONTENT" 2>&1 \
  | tee "$LOG" \
  | jq --unbuffered -r '
    # Extract text from assistant messages
    if .type == "assistant" and .message.content then
      .message.content[] | select(.type == "text") | .text // empty
    # Show tool use activity
    elif .type == "assistant" and .message.tool_use then
      "[\(.message.tool_use.name // "tool")]"
    else
      empty
    end
  ' 2>/dev/null || true

# Check for completion by examining the result in the JSON log
if jq -e 'select(.type == "result") | .result | contains("RALPH_COMPLETE")' "$LOG" >/dev/null 2>&1; then
  echo ""
  echo "Task breakdown complete!"

  # Strip Implementation Notes section from spec if present
  FINAL_SPEC_PATH="$SPECS_DIR/$LABEL.md"
  SPEC_CONTENT=$(cat "$SPEC_PATH")
  FINAL_CONTENT=$(strip_implementation_notes "$SPEC_CONTENT")

  if [ "$SPEC_CONTENT" != "$FINAL_CONTENT" ]; then
    echo ""
    echo "Stripping Implementation Notes from $FINAL_SPEC_PATH..."
    echo "$FINAL_CONTENT" > "$FINAL_SPEC_PATH"
  fi

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
