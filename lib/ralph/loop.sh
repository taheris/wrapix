#!/usr/bin/env bash
set -euo pipefail

# ralph loop [feature-name]
# Iterate through all work items for a feature
# Each step runs with fresh context (new claude process)
# When last bead completes, transitions WIP -> REVIEW

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"

# Get feature name from argument or state
FEATURE_NAME="${1:-}"
if [ -z "$FEATURE_NAME" ]; then
  SPEC_FILE="$RALPH_DIR/state/spec"
  if [ -f "$SPEC_FILE" ]; then
    FEATURE_NAME=$(cat "$SPEC_FILE")
  fi
fi

echo "Ralph Wiggum Work Loop starting..."
if [ -n "$FEATURE_NAME" ]; then
  echo "  Feature: $FEATURE_NAME"
fi
echo ""

step_count=0
while true; do
  ((step_count++))
  echo "=== Step $step_count ==="

  # Run ralph-step with optional feature name argument
  if [ -n "$FEATURE_NAME" ]; then
    OUTPUT=$(ralph-step "$FEATURE_NAME" 2>&1) || {
      EXIT_CODE=$?
      echo "$OUTPUT"

      # Check if we exited because no more issues (success message)
      if echo "$OUTPUT" | grep -q "All work complete!"; then
        break
      fi

      echo ""
      echo "Step failed (exit code: $EXIT_CODE). Pausing work loop."
      echo "Review the logs and fix the issue before continuing."
      echo "To resume: ralph loop $FEATURE_NAME"
      exit 1
    }
  else
    OUTPUT=$(ralph-step 2>&1) || {
      EXIT_CODE=$?
      echo "$OUTPUT"

      # Check if we exited because no more issues (success message)
      if echo "$OUTPUT" | grep -q "All work complete!"; then
        break
      fi

      echo ""
      echo "Step failed (exit code: $EXIT_CODE). Pausing work loop."
      echo "Review the logs and fix the issue before continuing."
      echo "To resume: ralph loop"
      exit 1
    }
  fi

  echo "$OUTPUT"
  echo ""
  echo "--- Continuing to next step ---"
  echo ""
done

echo ""
echo "All work complete after $step_count step(s)!"
