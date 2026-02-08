#!/usr/bin/env bash
set -euo pipefail

# ralph status [--watch|-w]
# Show current workflow state using bd mol commands:
# - Current label and spec name
# - Molecule progress (completion %, rate, ETA)
# - Current position in DAG
# - Stale molecule warnings
#
# --watch / -w: Auto-refreshing live view using tmux split panes.
#   Top pane: `watch -n5 ralph status` (molecule progress refresh)
#   Bottom pane: live tail of agent output if ralph run is active,
#                otherwise recent git log + last errors from ralph logs.
#   Requires tmux — errors with a clear message if $TMUX is not set.

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=util.sh
source "$SCRIPT_DIR/util.sh"

RALPH_DIR="${RALPH_DIR:-.wrapix/ralph}"
SPECS_DIR="specs"

#-----------------------------------------------------------------------------
# Flag parsing
#-----------------------------------------------------------------------------
WATCH_MODE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --watch|-w)
      WATCH_MODE=true
      shift
      ;;
    -h|--help)
      echo "Usage: ralph status [--watch|-w]"
      echo ""
      echo "Show current workflow state."
      echo ""
      echo "Options:"
      echo "  --watch, -w   Auto-refreshing live view (requires tmux)"
      echo "  -h, --help    Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

#-----------------------------------------------------------------------------
# Watch mode: tmux split layout
#-----------------------------------------------------------------------------
if [ "$WATCH_MODE" = "true" ]; then
  # Require tmux
  if [ -z "${TMUX:-}" ]; then
    echo "Error: --watch requires a tmux session." >&2
    echo "Start tmux first, then run 'ralph status --watch'." >&2
    exit 1
  fi

  # Find the most recent active log file (from ralph run)
  LOGS_DIR="$RALPH_DIR/logs"
  ACTIVE_LOG=""
  if [ -d "$LOGS_DIR" ]; then
    ACTIVE_LOG=$(find "$LOGS_DIR" -maxdepth 1 -name "work-*.log" -type f \
      -printf '%T@\t%p\n' 2>/dev/null \
      | sort -rn \
      | head -1 \
      | cut -f2) || true
  fi

  # Build bottom pane command
  if [ -n "$ACTIVE_LOG" ]; then
    # Active log found — tail it for live agent output
    BOTTOM_CMD="echo '=== Agent Output: $(basename "$ACTIVE_LOG") ===' && tail -f '$ACTIVE_LOG' | jq -r 'if .type == \"assistant\" then .message.content // .content // \"\" elif .type == \"result\" then \"--- result: \" + (.subtype // \"\") + \" ---\\n\" + (.result // \"\") else empty end' 2>/dev/null || tail -f '$ACTIVE_LOG'"
  else
    # No active log — show recent git log + last errors
    BOTTOM_CMD="echo '=== Recent Activity ===' && echo '' && git log --oneline -15 2>/dev/null || echo '(no git history)' && echo '' && echo '=== Last Errors ===' && ralph logs 2>/dev/null || echo '(no ralph logs found)'"
  fi

  # Create tmux split layout
  # Top pane: auto-refreshing ralph status
  # Bottom pane: agent output or recent activity
  tmux split-window -v -p 40 "$BOTTOM_CMD"
  tmux select-pane -t 0
  exec watch -n5 ralph status
fi

# Helper to indent each line of output
indent() {
  while IFS= read -r line; do
    printf '  %s\n' "$line"
  done
}

# Generate a visual progress bar
# Usage: progress_bar <completed> <total> [<width>]
# Example: progress_bar 4 10 10 => "[####------] 40% (4/10)"
progress_bar() {
  local completed="${1:-0}"
  local total="${2:-0}"
  local width="${3:-10}"

  # Handle edge cases
  if [ "$total" -eq 0 ]; then
    printf "[%s] 0%% (0/0)" "$(printf '%*s' "$width" '' | tr ' ' '-')"
    return
  fi

  # Calculate percentage and filled width
  local percent=$((completed * 100 / total))
  local filled=$((completed * width / total))
  local empty=$((width - filled))

  # Build the bar
  local bar_filled bar_empty
  bar_filled=$(printf '%*s' "$filled" '' | tr ' ' '#')
  bar_empty=$(printf '%*s' "$empty" '' | tr ' ' '-')

  printf "[%s%s] %d%% (%d/%d)" "$bar_filled" "$bar_empty" "$percent" "$completed" "$total"
}

# Check if ralph is initialized
if [ ! -d "$RALPH_DIR" ]; then
  echo "Ralph not initialized. Run 'ralph plan <label>' first."
  exit 0
fi

# Read state from current.json
CURRENT_FILE="$RALPH_DIR/state/current.json"
LABEL=""
MOLECULE=""
SPEC_HIDDEN="false"

if [ -f "$CURRENT_FILE" ]; then
  LABEL=$(jq -r '.label // empty' "$CURRENT_FILE" 2>/dev/null || true)
  MOLECULE=$(jq -r '.molecule // empty' "$CURRENT_FILE" 2>/dev/null || true)
  SPEC_HIDDEN=$(jq -r '.hidden // false' "$CURRENT_FILE" 2>/dev/null || echo "false")
fi

# Header
if [ -n "$LABEL" ]; then
  echo "Ralph Status: $LABEL"
  echo "==============================="
else
  echo "Ralph Status"
  echo "============"
  echo ""
  echo "Label: (not set)"
  echo ""
  echo "Run 'ralph plan <label>' to start a new feature."
  exit 0
fi

# Molecule ID
if [ -n "$MOLECULE" ]; then
  echo "Molecule: $MOLECULE"
else
  echo "Molecule: (not set)"
fi

# Spec location
if [ "$SPEC_HIDDEN" = "true" ]; then
  SPEC_PATH="$RALPH_DIR/state/$LABEL.md"
  echo "Spec: $SPEC_PATH (hidden)"
else
  SPEC_PATH="$SPECS_DIR/$LABEL.md"
  echo "Spec: $SPEC_PATH"
fi

echo ""

# Helper function for label-based progress (fallback when molecule commands fail)
show_label_progress() {
  local bead_label="spec-$LABEL"

  # Count by status
  local open_count in_progress_count closed_count ready_count total
  open_count=$(bd list --label "$bead_label" --status=open 2>/dev/null | wc -l) || open_count=0
  in_progress_count=$(bd list --label "$bead_label" --status=in_progress 2>/dev/null | wc -l) || in_progress_count=0
  closed_count=$(bd list --label "$bead_label" --status=closed 2>/dev/null | wc -l) || closed_count=0
  ready_count=$(bd list --label "$bead_label" --ready 2>/dev/null | wc -l) || ready_count=0
  total=$((open_count + in_progress_count + closed_count))

  echo "  Open:        $open_count"
  echo "  In Progress: $in_progress_count"
  echo "  Closed:      $closed_count"
  echo "  Ready:       $ready_count"
  echo "  Total:       $total"

  if [ "$total" -gt 0 ]; then
    local percent=$((closed_count * 100 / total))
    echo "  Progress:    $percent% complete"
  fi
}

# If molecule is set, use bd mol commands for progress tracking
if [ -n "$MOLECULE" ]; then
  # Progress section - use JSON for reliable parsing
  echo "Progress:"
  PROGRESS_JSON=$(bd_json mol progress "$MOLECULE" --json 2>/dev/null) || true
  if [ -n "$PROGRESS_JSON" ] && echo "$PROGRESS_JSON" | jq empty 2>/dev/null; then
    # Extract stats from JSON
    COMPLETED=$(echo "$PROGRESS_JSON" | jq -r '.completed // 0')
    TOTAL=$(echo "$PROGRESS_JSON" | jq -r '.total // 0')

    # Display visual progress bar
    echo "  $(progress_bar "$COMPLETED" "$TOTAL")"
  else
    # Fallback to label-based counting when molecule commands fail
    echo "  (molecule progress unavailable, using label counts)"
    show_label_progress
  fi

  echo ""

  # Current position in DAG - use the formatted text output
  echo "Current Position:"
  if CURRENT_OUTPUT=$(bd mol current "$MOLECULE" 2>&1); then
    # Skip the header lines and just show the task list (already indented by bd mol current)
    echo "$CURRENT_OUTPUT" | grep -E '^\s*\[(done|current|ready|blocked|pending)\]' || echo "  (no position markers found)"
  else
    # Fallback: show next ready task
    BEAD_LABEL="spec-$LABEL"
    NEXT_ISSUE=$(bd list --label "$BEAD_LABEL" --ready --sort priority --limit 1 --json 2>/dev/null | jq -r '.[0].id // empty') || true
    if [ -n "$NEXT_ISSUE" ]; then
      NEXT_TITLE=$(bd show "$NEXT_ISSUE" --json 2>/dev/null | jq -r '.[0].title // empty') || NEXT_TITLE=""
      echo "  Next ready: $NEXT_ISSUE - $NEXT_TITLE"
    else
      IN_PROGRESS=$(bd list --label "$BEAD_LABEL" --status=in_progress --limit 1 --json 2>/dev/null | jq -r '.[0].id // empty') || true
      if [ -n "$IN_PROGRESS" ]; then
        IN_PROGRESS_TITLE=$(bd show "$IN_PROGRESS" --json 2>/dev/null | jq -r '.[0].title // empty') || IN_PROGRESS_TITLE=""
        echo "  In progress: $IN_PROGRESS - $IN_PROGRESS_TITLE"
      else
        echo "  (no tasks ready or in progress)"
      fi
    fi
  fi

  echo ""

  # Check for stale molecules (hygiene warnings)
  echo "Warnings:"
  if STALE_OUTPUT=$(bd mol stale --quiet 2>&1) && [ -n "$STALE_OUTPUT" ]; then
    echo "$STALE_OUTPUT" | indent
  else
    echo "  (none)"
  fi
  echo ""
else
  # Fallback: no molecule set, use legacy label-based counting
  BEAD_LABEL="spec-$LABEL"
  echo "Beads Progress ($BEAD_LABEL):"
  echo "  (No molecule set - using label-based counting)"
  echo ""

  # Count by status
  OPEN_COUNT=$(bd list --label "$BEAD_LABEL" --status=open 2>/dev/null | wc -l) || OPEN_COUNT=0
  IN_PROGRESS_COUNT=$(bd list --label "$BEAD_LABEL" --status=in_progress 2>/dev/null | wc -l) || IN_PROGRESS_COUNT=0
  CLOSED_COUNT=$(bd list --label "$BEAD_LABEL" --status=closed 2>/dev/null | wc -l) || CLOSED_COUNT=0
  READY_COUNT=$(bd list --label "$BEAD_LABEL" --ready 2>/dev/null | wc -l) || READY_COUNT=0

  TOTAL=$((OPEN_COUNT + IN_PROGRESS_COUNT + CLOSED_COUNT))

  echo "  Open:        $OPEN_COUNT"
  echo "  In Progress: $IN_PROGRESS_COUNT"
  echo "  Closed:      $CLOSED_COUNT"
  echo "  Ready:       $READY_COUNT"
  echo "  Total:       $TOTAL"

  if [ "$TOTAL" -gt 0 ]; then
    PERCENT=$((CLOSED_COUNT * 100 / TOTAL))
    echo "  Progress:    $PERCENT% complete"
  fi

  echo ""

  # Next ready task
  NEXT_ISSUE=$(bd list --label "$BEAD_LABEL" --ready --sort priority --limit 1 --json 2>/dev/null | jq -r '.[0].id // empty') || true
  if [ -n "$NEXT_ISSUE" ]; then
    echo "Next Ready Task:"
    bd show "$NEXT_ISSUE" 2>/dev/null | head -5 || echo "  $NEXT_ISSUE"
  else
    if [ "$TOTAL" -gt 0 ] && [ "$CLOSED_COUNT" -eq "$TOTAL" ]; then
      echo "All tasks complete!"
    elif [ "$IN_PROGRESS_COUNT" -gt 0 ]; then
      echo "No ready tasks. $IN_PROGRESS_COUNT task(s) in progress."
    else
      echo "No tasks found for label: $BEAD_LABEL"
    fi
  fi

  echo ""
  echo "Run 'ralph todo' to create a molecule for this spec."
fi

echo ""
echo "Commands:"
echo "  ralph plan   - Create/continue spec interview"
echo "  ralph todo   - Convert spec to beads"
echo "  ralph run    - Work all tasks (or --once for single task)"
