#!/usr/bin/env bash
set -euo pipefail

# ralph status
# Show current workflow state using bd mol commands:
# - Current label and spec name
# - Molecule progress (completion %, rate, ETA)
# - Current position in DAG
# - Stale molecule warnings

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
SPECS_DIR="specs"

# Helper to indent each line of output
indent() {
  while IFS= read -r line; do
    printf '  %s\n' "$line"
  done
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

# If molecule is set, use bd mol commands for progress tracking
if [ -n "$MOLECULE" ]; then
  # Progress section
  echo "Progress:"
  if PROGRESS_OUTPUT=$(bd mol progress "$MOLECULE" 2>&1); then
    # Indent each line of progress output
    echo "$PROGRESS_OUTPUT" | indent
  else
    echo "  (unable to get progress)"
  fi

  echo ""

  # Current position in DAG
  echo "Current Position:"
  if CURRENT_OUTPUT=$(bd mol current "$MOLECULE" 2>&1); then
    echo "$CURRENT_OUTPUT" | indent
  else
    echo "  (unable to get current position)"
  fi

  echo ""

  # Check for stale molecules (hygiene warnings)
  if STALE_OUTPUT=$(bd mol stale --quiet 2>&1) && [ -n "$STALE_OUTPUT" ]; then
    echo "Warnings:"
    echo "$STALE_OUTPUT" | indent
    echo ""
  fi
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
  echo "Run 'ralph ready' to create a molecule for this spec."
fi

echo ""
echo "Commands:"
echo "  ralph plan   - Create/continue spec interview"
echo "  ralph ready  - Convert spec to beads"
echo "  ralph step   - Work next task"
echo "  ralph loop   - Work all tasks"
