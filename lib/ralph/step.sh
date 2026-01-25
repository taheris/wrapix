#!/usr/bin/env bash
set -euo pipefail

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
CONFIG_FILE="$RALPH_DIR/config.nix"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: No ralph config found at $CONFIG_FILE"
  exit 1
fi

# Get label from state (created by ralph ready)
LABEL_FILE="$RALPH_DIR/state/label"
if [ ! -f "$LABEL_FILE" ]; then
  echo "Error: No label file found. Run 'ralph ready' first."
  exit 1
fi
LABEL=$(cat "$LABEL_FILE")

# Find next ready issue with this label
# Use --ready to get only issues that are open and not blocked/deferred
NEXT_ISSUE=$(bd list --label "$LABEL" --ready --limit 1 2>/dev/null | awk '{print $1}' | head -1) || true

if [ -z "$NEXT_ISSUE" ]; then
  echo "No more ready issues with label: $LABEL"
  echo "All work complete!"
  exit 0
fi

echo "Working on: $NEXT_ISSUE"
bd show "$NEXT_ISSUE"

# Mark as in-progress
bd update "$NEXT_ISSUE" --status=in_progress

# Get issue details as JSON for prompt substitution
ISSUE_JSON=$(bd show "$NEXT_ISSUE" --json 2>/dev/null) || ISSUE_JSON="{}"
ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title // ""')
ISSUE_DESC=$(echo "$ISSUE_JSON" | jq -r '.description // ""')

PROMPT_TEMPLATE="$RALPH_DIR/prompts/step.md"
if [ ! -f "$PROMPT_TEMPLATE" ]; then
  echo "Error: Step prompt template not found: $PROMPT_TEMPLATE"
  echo "Make sure prompts/step.md exists in your ralph directory."
  exit 1
fi

# Read template and substitute placeholders
# Use perl for safer multi-line substitution
WORK_PROMPT=$(perl -pe "
  s/\\{\\{ISSUE_ID\\}\\}/$NEXT_ISSUE/g;
" "$PROMPT_TEMPLATE")

# Handle title separately due to potential special chars
# shellcheck disable=SC2001 # sed needed for escaping special chars
WORK_PROMPT=$(echo "$WORK_PROMPT" | sed "s/{{TITLE}}/$(echo "$ISSUE_TITLE" | sed 's/[&/\]/\\&/g')/g")

# For description, we need to be careful with multi-line content
# Use a here-doc approach
WORK_PROMPT=$(echo "$WORK_PROMPT" | awk -v desc="$ISSUE_DESC" '{gsub(/\{\{DESCRIPTION\}\}/, desc); print}')

mkdir -p "$RALPH_DIR/logs"
LOG="$RALPH_DIR/logs/work-$NEXT_ISSUE.log"

# Run claude with FRESH CONTEXT (new process)
echo ""
echo "=== Starting work (fresh context) ==="
echo ""
echo "$WORK_PROMPT" | claude --dangerously-skip-permissions 2>&1 | tee "$LOG"

# Check for completion
if grep -q "WORK_COMPLETE" "$LOG" 2>/dev/null; then
  echo ""
  echo "Work complete. Closing issue: $NEXT_ISSUE"
  bd close "$NEXT_ISSUE"
else
  echo ""
  echo "Work did not complete. Issue remains in-progress: $NEXT_ISSUE"
  echo "Review log: $LOG"
  echo ""
  echo "To retry this issue, reset its status:"
  echo "  bd update $NEXT_ISSUE --status=open"
  exit 1
fi
