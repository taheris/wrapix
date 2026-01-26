#!/usr/bin/env bash
set -euo pipefail

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
COUNT="${1:-5}"

LOGS_PATTERN="$RALPH_DIR/logs/work-*.log"

# Find recent logs (use find for better handling of special filenames)
# shellcheck disable=SC2086 # LOGS_PATTERN is intentionally unquoted for glob expansion
RECENT_LOGS=$(find "$(dirname "$LOGS_PATTERN")" -maxdepth 1 -name "$(basename "$LOGS_PATTERN")" -type f -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -"$COUNT" | cut -f2) || true

if [ -z "$RECENT_LOGS" ]; then
  echo "No work logs found in $RALPH_DIR/logs/"
  exit 1
fi

echo "=== Recent work logs ==="
echo ""

for log in $RECENT_LOGS; do
  echo "--- $(basename "$log") ---"
  grep -E "(RALPH_COMPLETE|RALPH_BLOCKED:|RALPH_CLARIFY:|error:|Error:|ERROR)" "$log" 2>/dev/null || echo "(no signals found)"
  echo ""
done
