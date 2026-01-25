#!/usr/bin/env bash
set -euo pipefail

# The main Ralph Wiggum Loop - iterate through all work items
# Each step runs with fresh context (new claude process)

echo "Ralph Wiggum Work Loop starting..."
echo ""

step_count=0
while true; do
  ((step_count++))
  echo "=== Step $step_count ==="

  # Run ralph-step and capture output to check for completion
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

  echo "$OUTPUT"
  echo ""
  echo "--- Continuing to next step ---"
  echo ""
done

echo ""
echo "All work complete after $step_count step(s)!"
