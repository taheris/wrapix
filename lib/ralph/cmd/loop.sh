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
  CURRENT_FILE="$RALPH_DIR/state/current.json"
  if [ -f "$CURRENT_FILE" ]; then
    FEATURE_NAME=$(jq -r '.label // empty' "$CURRENT_FILE" 2>/dev/null || true)
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

  # Run ralph-step directly for full TTY interactivity
  set +e
  ralph-step ${FEATURE_NAME:+"$FEATURE_NAME"}
  EXIT_CODE=$?
  set -e

  case $EXIT_CODE in
    0)
      # Task completed, more work may remain - continue loop
      ;;
    100)
      # All work complete - exit loop
      break
      ;;
    *)
      echo ""
      echo "Step failed (exit code: $EXIT_CODE). Pausing work loop."
      echo "Review the logs and fix the issue before continuing."
      echo "To resume: ralph loop${FEATURE_NAME:+ $FEATURE_NAME}"
      exit 1
      ;;
  esac

  echo ""
  echo "--- Continuing to next step ---"
  echo ""
done

echo ""
echo "All work complete after $step_count step(s)!"
