#!/usr/bin/env bash
set -euo pipefail

# ralph status
# Show current workflow state:
# - Current label and spec name
# - Beads progress: open/in_progress/closed counts
# - Next ready task (if any)
# - Spec status (WIP/REVIEW)

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
SPECS_DIR="specs"
SPECS_README="$SPECS_DIR/README.md"

echo "Ralph Status"
echo "============"
echo ""

# Check if ralph is initialized
if [ ! -d "$RALPH_DIR" ]; then
  echo "Ralph not initialized. Run 'ralph start' first."
  exit 0
fi

# Current label
LABEL_FILE="$RALPH_DIR/state/label"
if [ -f "$LABEL_FILE" ]; then
  LABEL=$(cat "$LABEL_FILE")
  echo "Label: $LABEL"
  BEAD_LABEL="rl-$LABEL"
else
  echo "Label: (not set)"
  LABEL=""
  BEAD_LABEL=""
fi

# Current spec
SPEC_FILE="$RALPH_DIR/state/spec"
if [ -f "$SPEC_FILE" ]; then
  SPEC_NAME=$(cat "$SPEC_FILE")
  SPEC_PATH="$SPECS_DIR/$SPEC_NAME.md"
  echo "Spec: $SPEC_NAME"
  if [ -f "$SPEC_PATH" ]; then
    echo "  File: $SPEC_PATH (exists)"
  else
    echo "  File: $SPEC_PATH (not created yet)"
  fi
else
  echo "Spec: (not set)"
fi

echo ""

# Beads progress (if label is set)
if [ -n "$BEAD_LABEL" ]; then
  echo "Beads Progress ($BEAD_LABEL):"

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
  NEXT_ISSUE=$(bd list --label "$BEAD_LABEL" --ready --limit 1 2>/dev/null | awk '{print $1}' | head -1) || true
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
else
  echo "No beads label set. Run 'ralph ready' after creating a spec."
fi

echo ""

# Spec status from README
if [ -f "$SPECS_README" ] && [ -n "${SPEC_NAME:-}" ]; then
  echo "Spec Status:"
  if grep -q "$SPEC_NAME.*WIP\|Active Work.*$SPEC_NAME" "$SPECS_README" 2>/dev/null; then
    echo "  Status: WIP (Work In Progress)"
  elif grep -q "$SPEC_NAME.*REVIEW\|Completed.*$SPEC_NAME" "$SPECS_README" 2>/dev/null; then
    echo "  Status: REVIEW"
  else
    echo "  Status: Not tracked in specs/README.md"
  fi
fi

echo ""
echo "Commands:"
echo "  ralph plan   - Create/continue spec interview"
echo "  ralph ready  - Convert spec to beads"
echo "  ralph step   - Work next task"
echo "  ralph loop   - Work all tasks"
