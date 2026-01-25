#!/usr/bin/env bash
set -euo pipefail

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
LOGS="$RALPH_DIR/logs"
CONFIG_FILE="$RALPH_DIR/config.nix"

if [ ! -d "$LOGS" ]; then
  echo "No logs directory found at $LOGS"
  exit 0
fi

# Find recent log files (use find for better handling of filenames)
mapfile -t LOG_FILES < <(find "$LOGS" -maxdepth 1 -name "*.log" -type f -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -5 | cut -f2)

if [ ${#LOG_FILES[@]} -eq 0 ]; then
  echo "No log files found in $LOGS"
  exit 0
fi

echo "=== Recent Iteration Analysis ==="
echo ""

for log in "${LOG_FILES[@]}"; do
  echo "--- $(basename "$log") ---"

  # Show exit signals
  if grep -q "PLAN_COMPLETE\|BLOCKED:\|CLARIFY:" "$log" 2>/dev/null; then
    echo "Exit signals:"
    grep -E "PLAN_COMPLETE|BLOCKED:|CLARIFY:" "$log" | head -3 | sed 's/^/  /'
    echo ""
  fi

  # Show failure patterns
  FAILURES=$(grep -iE "error:|failed|exception|blocked:|panic:|fatal:" "$log" 2>/dev/null | head -5) || true
  if [ -n "$FAILURES" ]; then
    echo "Potential issues:"
    while IFS= read -r line; do
      echo "  $line"
    done <<< "$FAILURES"
    echo ""
  fi

  # Show warnings
  WARNINGS=$(grep -iE "warning:|warn:|deprecated:" "$log" 2>/dev/null | head -3) || true
  if [ -n "$WARNINGS" ]; then
    echo "Warnings:"
    while IFS= read -r line; do
      echo "  $line"
    done <<< "$WARNINGS"
    echo ""
  fi
done

echo "=== Tuning Suggestions ==="
echo ""
echo "Common prompt improvements:"
echo "  - Add explicit constraints for edge cases"
echo "  - Clarify exit conditions (PLAN_COMPLETE, BLOCKED:, CLARIFY:)"
echo "  - Add 'Do NOT...' guardrails for unwanted behaviors"
echo "  - Include more context about project structure"
echo ""
echo "Prompts location: $RALPH_DIR/prompts/"
echo "Config location: $CONFIG_FILE"
