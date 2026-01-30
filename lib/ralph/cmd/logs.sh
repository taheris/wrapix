#!/usr/bin/env bash
set -euo pipefail

RALPH_DIR="${RALPH_DIR:-.ralph}"
COUNT="${1:-5}"

LOGS_PATTERN="$RALPH_DIR/logs/work-*.log"

# Find recent logs (use find for better handling of special filenames)
# shellcheck disable=SC2086 # LOGS_PATTERN is intentionally unquoted for glob expansion
RECENT_LOGS=$(
  find "$(dirname "$LOGS_PATTERN")" -maxdepth 1 \
    -name "$(basename "$LOGS_PATTERN")" -type f \
    -printf '%T@\t%p\n' 2>/dev/null \
  | sort -rn \
  | head -"$COUNT" \
  | cut -f2
) || true

if [ -z "$RECENT_LOGS" ]; then
  echo "No work logs found in $RALPH_DIR/logs/"
  exit 1
fi

echo "=== Recent work logs ==="
echo ""

# jq filter to extract signals from JSON log format
JQ_FILTER='
  select(.type == "result") |
  "status: " + (.subtype // "unknown")
  + (if (.result | test("RALPH_COMPLETE")) then " | RALPH_COMPLETE" else "" end)
  + (if (.result | test("RALPH_BLOCKED")) then " | RALPH_BLOCKED" else "" end)
  + (if (.result | test("RALPH_CLARIFY")) then " | RALPH_CLARIFY" else "" end)
  + (if .is_error == true then " | ERROR" else "" end)
'

for log in $RECENT_LOGS; do
  echo "--- $(basename "$log") ---"
  result_info=$(jq -r "$JQ_FILTER" "$log" 2>/dev/null) || true

  if [ -n "$result_info" ]; then
    echo "$result_info"
  else
    echo "(no result found - may be old format or incomplete)"
  fi
  echo ""
done
