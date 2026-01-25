#!/usr/bin/env bash
set -euo pipefail

# ralph step [feature-name]
# Executes work with test strategy selection and quality gates
# - Pins context (read specs/README.md)
# - Gets spec name from argument or state
# - Picks next ready bead with current label
# - Implements the task with quality gates
# - If this was the last bead, triggers completion (WIP -> REVIEW)

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
CONFIG_FILE="$RALPH_DIR/config.nix"
SPECS_DIR="specs"
SPECS_README="$SPECS_DIR/README.md"

# Function to update spec status to REVIEW in specs/README.md
update_spec_status_to_review() {
  local feature="$1"
  if [ ! -f "$SPECS_README" ]; then
    return
  fi

  # Move entry from WIP to REVIEW section
  # This is a simple implementation - just notify the user
  echo ""
  echo "All tasks for '$feature' are complete!"
  echo "Please update specs/README.md to move the spec from WIP to REVIEW."
}

# Function to check if all beads are complete
check_all_complete() {
  local label="$1"
  local feature="$2"
  # Check if any ready beads remain
  local remaining
  remaining=$(bd list --label "$label" --ready 2>/dev/null | wc -l) || remaining=0

  if [ "$remaining" -eq 0 ]; then
    update_spec_status_to_review "$feature"
  fi
}

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: No ralph config found at $CONFIG_FILE"
  exit 1
fi

# Get feature name from argument or state
FEATURE_NAME="${1:-}"
if [ -z "$FEATURE_NAME" ]; then
  SPEC_FILE="$RALPH_DIR/state/spec"
  if [ ! -f "$SPEC_FILE" ]; then
    echo "Error: No spec file reference found. Run 'ralph start' first or provide feature name."
    exit 1
  fi
  FEATURE_NAME=$(cat "$SPEC_FILE")
fi

# Get label from state or derive from feature name
LABEL_FILE="$RALPH_DIR/state/label"
if [ -f "$LABEL_FILE" ]; then
  STATE_LABEL=$(cat "$LABEL_FILE")
  # If feature name matches state, use state label
  # Otherwise, use feature name as label
  if [ "$FEATURE_NAME" = "$STATE_LABEL" ] || [ -z "${1:-}" ]; then
    LABEL="$STATE_LABEL"
  else
    LABEL="$FEATURE_NAME"
  fi
else
  LABEL="$FEATURE_NAME"
fi

BEAD_LABEL="rl-$LABEL"
SPEC_PATH="$SPECS_DIR/$FEATURE_NAME.md"

# Find next ready issue with this label
NEXT_ISSUE=$(bd list --label "$BEAD_LABEL" --ready --limit 1 2>/dev/null | awk '{print $1}' | head -1) || true

if [ -z "$NEXT_ISSUE" ]; then
  echo "No more ready issues with label: $BEAD_LABEL"
  echo "All work complete!"

  # Check if we should transition WIP -> REVIEW
  update_spec_status_to_review "$FEATURE_NAME"
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

PROMPT_TEMPLATE="$RALPH_DIR/step.md"
if [ ! -f "$PROMPT_TEMPLATE" ]; then
  echo "Error: Step prompt template not found: $PROMPT_TEMPLATE"
  echo "Make sure step.md exists in your ralph directory."
  exit 1
fi

# Pin context from specs/README.md
PINNED_CONTEXT=""
if [ -f "$SPECS_README" ]; then
  PINNED_CONTEXT=$(cat "$SPECS_README")
fi

# Read template and substitute placeholders
WORK_PROMPT=$(cat "$PROMPT_TEMPLATE")
WORK_PROMPT="${WORK_PROMPT//\{\{ISSUE_ID\}\}/$NEXT_ISSUE}"
WORK_PROMPT="${WORK_PROMPT//\{\{SPEC_PATH\}\}/$SPEC_PATH}"
WORK_PROMPT="${WORK_PROMPT//\{\{LABEL\}\}/$LABEL}"

# Handle title separately due to potential special chars
ESCAPED_TITLE=$(printf '%s\n' "$ISSUE_TITLE" | sed 's/[&/\]/\\&/g')
WORK_PROMPT=$(echo "$WORK_PROMPT" | sed "s/{{TITLE}}/$ESCAPED_TITLE/g")

# For description and pinned context, use awk for multi-line
WORK_PROMPT=$(echo "$WORK_PROMPT" | awk -v desc="$ISSUE_DESC" '{gsub(/\{\{DESCRIPTION\}\}/, desc); print}')
WORK_PROMPT=$(echo "$WORK_PROMPT" | awk -v ctx="$PINNED_CONTEXT" '{gsub(/\{\{PINNED_CONTEXT\}\}/, ctx); print}')

mkdir -p "$RALPH_DIR/logs"
LOG="$RALPH_DIR/logs/work-$NEXT_ISSUE.log"

# Run claude with FRESH CONTEXT (new process)
echo ""
echo "=== Starting work (fresh context) ==="
echo ""
# Use script to preserve tty behavior while logging
export WORK_PROMPT
script -q -c 'claude --dangerously-skip-permissions "$WORK_PROMPT"' "$LOG"

# Check for completion
if grep -q "WORK_COMPLETE" "$LOG" 2>/dev/null; then
  echo ""
  echo "Work complete. Closing issue: $NEXT_ISSUE"
  bd close "$NEXT_ISSUE"

  # Check if all beads with this label are complete
  check_all_complete "$BEAD_LABEL" "$FEATURE_NAME"
else
  echo ""
  echo "Work did not complete. Issue remains in-progress: $NEXT_ISSUE"
  echo "Review log: $LOG"
  echo ""
  echo "To retry this issue, reset its status:"
  echo "  bd update $NEXT_ISSUE --status=open"
  exit 1
fi
