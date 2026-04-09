#!/usr/bin/env bash
# Cooldown-aware dispatch check for gc's worker scale_check.
#
# Returns the number of dispatchable beads, considering:
# - P0 beads always bypass cooldown (dispatched immediately)
# - Cooldown timer between normal dispatches
# - Reactive backpressure when rate-limited
#
# Environment:
#   GC_COOLDOWN     — duration string ("2h", "30m", "2h30m"); "0" = disabled
#   GC_WORKSPACE    — workspace path (for state files)
set -euo pipefail

COOLDOWN="${GC_COOLDOWN:-0}"
STATE_DIR="${GC_WORKSPACE:-.}/.wrapix/state"
COOLDOWN_FILE="$STATE_DIR/last-dispatch"
BACKPRESSURE_FILE="$STATE_DIR/rate-limited"

# Parse Go-style duration string to seconds: "2h30m" -> 9000
parse_duration() {
  local input="$1" total=0 num=""
  for (( i=0; i<${#input}; i++ )); do
    local c="${input:$i:1}"
    case "$c" in
      [0-9]) num+="$c" ;;
      h) total=$(( total + ${num:-0} * 3600 )); num="" ;;
      m) total=$(( total + ${num:-0} * 60 )); num="" ;;
      s) total=$(( total + ${num:-0} )); num="" ;;
    esac
  done
  # Bare number without suffix treated as seconds
  if [[ -n "$num" ]]; then
    total=$(( total + num ))
  fi
  echo "$total"
}

# --- Reactive backpressure: if rate-limited, pause all dispatching ---
if [[ -f "$BACKPRESSURE_FILE" ]]; then
  limit_until=$(cat "$BACKPRESSURE_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  if (( now < limit_until )); then
    echo 0
    exit 0
  fi
  rm -f "$BACKPRESSURE_FILE"
fi

# --- P0 bypass: always count P0 beads regardless of cooldown ---
p0_count=$(bd list --metadata-field gc.routed_to=worker --status open,in_progress \
  --no-assignee --priority 0 --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
if (( p0_count > 0 )); then
  echo "$p0_count"
  exit 0
fi

# --- No cooldown: count all beads normally ---
if [[ "$COOLDOWN" == "0" ]]; then
  bd list --metadata-field gc.routed_to=worker --status open,in_progress \
    --no-assignee --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0
  exit 0
fi

# --- Cooldown check: only dispatch if cooldown has elapsed ---
if [[ -f "$COOLDOWN_FILE" ]]; then
  last_dispatch=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  cooldown_secs=$(parse_duration "$COOLDOWN")
  if (( now - last_dispatch < cooldown_secs )); then
    echo 0
    exit 0
  fi
fi

# Cooldown elapsed (or first dispatch) — count available beads
bd list --metadata-field gc.routed_to=worker --status open,in_progress \
  --no-assignee --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0
