#!/usr/bin/env bash
set -euo pipefail

# ralph loop [feature-name]
# Iterate through all work items for a feature
# Each step runs with fresh context (new claude process)
# When last bead completes, transitions WIP -> REVIEW
#
# Note: No container check here - each ralph-step call enters its own
# fresh container, which is the intended behavior for context isolation.

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"

# Get feature name from argument or state
FEATURE_NAME="${1:-}"
if [ -z "$FEATURE_NAME" ]; then
  LABEL_FILE="$RALPH_DIR/state/label"
  if [ -f "$LABEL_FILE" ]; then
    FEATURE_NAME=$(cat "$LABEL_FILE")
  fi
fi

echo "Ralph Wiggum Work Loop starting..."
if [ -n "$FEATURE_NAME" ]; then
  echo "  Feature: $FEATURE_NAME"
fi
echo ""

step_count=0
while true; do
  ((++step_count))
  echo "=== Step $step_count ==="

  # Run ralph-step with optional feature name argument
  # Capture output and exit code separately
  set +e
  OUTPUT=$(ralph-step ${FEATURE_NAME:+"$FEATURE_NAME"} 2>&1)
  EXIT_CODE=$?
  set -e

  echo "$OUTPUT"

  # Check if all work is complete (either no more ready issues, or last task finished)
  if echo "$OUTPUT" | grep -q "All work complete!"; then
    break
  fi

  # Check if step failed (non-zero exit and not "all complete")
  if [ "$EXIT_CODE" -ne 0 ]; then
    echo ""
    echo "Step failed (exit code: $EXIT_CODE). Pausing work loop."
    echo "Review the logs and fix the issue before continuing."
    echo "To resume: ralph loop${FEATURE_NAME:+ $FEATURE_NAME}"
    exit 1
  fi

  echo ""
  echo "--- Continuing to next step ---"
  echo ""
done

echo ""
echo "All work complete after $step_count step(s)!"
