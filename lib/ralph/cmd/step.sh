#!/usr/bin/env bash
set -euo pipefail

# ralph step [feature-name]
# Executes work with test strategy selection and quality gates
# - Pins context (read specs/README.md)
# - Gets spec name from argument or state
# - Picks next ready bead with current label
# - Implements the task with quality gates
# - If this was the last bead, triggers completion (WIP -> REVIEW)

# Container detection: if not in container and wrapix is available, re-launch in container
# /etc/wrapix/claude-config.json only exists inside containers (baked into image)
if [ ! -f /etc/wrapix/claude-config.json ] && command -v wrapix &>/dev/null; then
  export RALPH_MODE=1
  export RALPH_CMD=step
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

# Function to update spec status to REVIEW in specs/README.md
update_spec_status_to_review() {
  local feature="$1"
  local hidden="$2"

  echo ""
  echo "All tasks for '$feature' are complete!"

  # Only mention README update if not hidden
  if [ "$hidden" != "true" ] && [ -f "$SPECS_README" ]; then
    echo "Please update specs/README.md to move the spec from WIP to REVIEW."
  fi
}

# Function to check if all beads are complete
check_all_complete() {
  local label="$1"
  local feature="$2"
  local hidden="$3"
  # Check if any ready beads remain
  local remaining
  local output
  output=$(bd list --label "$label" --ready 2>&1) || {
    warn "Failed to check remaining issues: ${output:0:100}"
    remaining=0
  }
  remaining=$(echo "$output" | wc -l)
  debug "Remaining ready issues with label $label: $remaining"

  if [ "$remaining" -eq 0 ]; then
    update_spec_status_to_review "$feature" "$hidden"
  fi
}

require_file "$CONFIG_FILE" "Ralph config"

# Get label from state or argument
LABEL_FILE="$RALPH_DIR/state/label"
if [ -n "${1:-}" ]; then
  LABEL="$1"
  debug "Label from argument: $LABEL"
elif [ -f "$LABEL_FILE" ]; then
  LABEL=$(cat "$LABEL_FILE")
  debug "Label from state file: $LABEL"
else
  error "No label found. Run 'ralph start' first or provide feature name."
fi

# Load config to check spec.hidden
debug "Loading config from $CONFIG_FILE"
CONFIG=$(nix eval --json --file "$CONFIG_FILE") || error "Failed to evaluate config: $CONFIG_FILE"
if ! validate_json "$CONFIG" "Config"; then
  error "Config file did not produce valid JSON"
fi
SPEC_HIDDEN=$(echo "$CONFIG" | jq -r '.spec.hidden // false')
debug "spec.hidden = $SPEC_HIDDEN"

# Compute spec path based on hidden flag
if [ "$SPEC_HIDDEN" = "true" ]; then
  SPEC_PATH="$RALPH_DIR/state/$LABEL.md"
else
  SPEC_PATH="$SPECS_DIR/$LABEL.md"
fi

BEAD_LABEL="rl-$LABEL"
debug "Looking for issues with label: $BEAD_LABEL"

# Find next ready issue with this label
BD_LIST_OUTPUT=$(bd list --label "$BEAD_LABEL" --ready --sort priority --limit 1 --json 2>&1) || {
  warn "bd list command failed: ${BD_LIST_OUTPUT:0:200}"
  BD_LIST_OUTPUT="[]"
}
NEXT_ISSUE=$(bd_list_first_id "$BD_LIST_OUTPUT")

if [ -z "$NEXT_ISSUE" ]; then
  echo "No more ready issues with label: $BEAD_LABEL"
  echo "All work complete!"

  # Check if we should transition WIP -> REVIEW
  update_spec_status_to_review "$LABEL" "$SPEC_HIDDEN"
  exit 0
fi

echo "Working on: $NEXT_ISSUE"
bd show "$NEXT_ISSUE"

# Mark as in-progress
bd update "$NEXT_ISSUE" --status=in_progress

# Get issue details as JSON for prompt substitution
debug "Fetching issue details for $NEXT_ISSUE"
ISSUE_JSON_RAW=$(bd show "$NEXT_ISSUE" --json 2>&1) || {
  warn "bd show failed for $NEXT_ISSUE: ${ISSUE_JSON_RAW:0:200}"
  ISSUE_JSON_RAW="[]"
}

# Extract clean JSON (bd may emit warnings before JSON)
ISSUE_JSON=$(extract_json "$ISSUE_JSON_RAW")

# Validate JSON structure before parsing
if ! validate_json_array "$ISSUE_JSON" "Issue $NEXT_ISSUE"; then
  warn "Could not parse issue details for $NEXT_ISSUE, continuing with empty values"
  ISSUE_TITLE=""
  ISSUE_DESC=""
else
  ISSUE_TITLE=$(json_array_field "$ISSUE_JSON" "title" "Issue")
  ISSUE_DESC=$(json_array_field "$ISSUE_JSON" "description" "Issue")
fi

# Warn if critical fields are empty
if [ -z "$ISSUE_TITLE" ]; then
  warn "Issue $NEXT_ISSUE has no title"
fi
debug "Issue title: ${ISSUE_TITLE:0:50}..."

PROMPT_TEMPLATE="$RALPH_DIR/step.md"
require_file "$PROMPT_TEMPLATE" "Step prompt template (step.md)"

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

# Substitute title using parameter expansion
WORK_PROMPT="${WORK_PROMPT//\{\{TITLE\}\}/$ISSUE_TITLE}"

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
# shellcheck disable=SC2016 # Variable expanded by subshell, not current shell
script -q -c 'claude --dangerously-skip-permissions "$WORK_PROMPT"' "$LOG"

# Check for completion
if grep -q "WORK_COMPLETE" "$LOG" 2>/dev/null; then
  echo ""
  echo "Work complete. Closing issue: $NEXT_ISSUE"
  bd close "$NEXT_ISSUE"

  # Check if all beads with this label are complete
  check_all_complete "$BEAD_LABEL" "$LABEL" "$SPEC_HIDDEN"
else
  echo ""
  echo "Work did not complete. Issue remains in-progress: $NEXT_ISSUE"
  echo "Review log: $LOG"
  echo ""
  echo "To retry this issue, reset its status:"
  echo "  bd update $NEXT_ISSUE --status=open"
  exit 1
fi
