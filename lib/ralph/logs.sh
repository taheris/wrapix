#!/usr/bin/env bash
set -euo pipefail

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
PHASE="${1:-}"
COUNT="${2:-5}"

case "$PHASE" in
  plan)
    LOGS_PATTERN="$RALPH_DIR/logs/plan-*.log"
    ;;
  step)
    LOGS_PATTERN="$RALPH_DIR/logs/work-*.log"
    ;;
  "")
    echo "Usage: ralph logs <plan|step> [count]"
    echo ""
    echo "  plan [N]  Show last N plan logs (default 5)"
    echo "  step [N]  Show last N step logs (default 5)"
    exit 0
    ;;
  *)
    echo "Unknown phase: $PHASE"
    echo "Usage: ralph logs <plan|step> [count]"
    exit 1
    ;;
esac

# Find recent logs (use find for better handling of special filenames)
# shellcheck disable=SC2086 # LOGS_PATTERN is intentionally unquoted for glob expansion
RECENT_LOGS=$(find "$(dirname "$LOGS_PATTERN")" -maxdepth 1 -name "$(basename "$LOGS_PATTERN")" -type f -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -"$COUNT" | cut -f2) || true

if [ -z "$RECENT_LOGS" ]; then
  echo "No $PHASE logs found in $RALPH_DIR/logs/"
  exit 1
fi

echo "=== Recent $PHASE logs ==="
echo ""

for log in $RECENT_LOGS; do
  echo "--- $(basename "$log") ---"
  grep -E "(PLAN_COMPLETE|WORK_COMPLETE|BLOCKED:|CLARIFY:|error:|Error:|ERROR)" "$log" 2>/dev/null || echo "(no signals found)"
  echo ""
done
