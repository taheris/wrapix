#!/usr/bin/env bash
set -euo pipefail

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
CONFIG_FILE="$RALPH_DIR/config.nix"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: No ralph config found at $CONFIG_FILE"
  echo "Run 'ralph-init' first to initialize."
  exit 1
fi

# Load entire config as JSON once at startup
CONFIG=$(nix eval --json --file "$CONFIG_FILE")

# Extract values from cached JSON (no repeated nix eval calls)
MODE=$(echo "$CONFIG" | jq -r '.mode // "plan"')
MAX=$(echo "$CONFIG" | jq -r '.loop."max-iterations" // 0')
PAUSE_ON_FAIL=$(echo "$CONFIG" | jq -r '.loop."pause-on-failure" // true')
HISTORY_ENABLED=$(echo "$CONFIG" | jq -r '.history.enabled // true')
PRE_HOOK=$(echo "$CONFIG" | jq -r '.loop."pre-hook" // empty')
POST_HOOK=$(echo "$CONFIG" | jq -r '.loop."post-hook" // empty')
COMPLETE_SIGNAL=$(echo "$CONFIG" | jq -r '."exit-signals".complete // "PLAN_COMPLETE"')
BLOCKED_SIGNAL=$(echo "$CONFIG" | jq -r '."exit-signals".blocked // "BLOCKED:"')
CLARIFY_SIGNAL=$(echo "$CONFIG" | jq -r '."exit-signals".clarify // "CLARIFY:"')
PROMPT_PATH="$RALPH_DIR/$(echo "$CONFIG" | jq -r ".prompts.$MODE // \"prompts/$MODE.md\"")"

if [ ! -f "$PROMPT_PATH" ]; then
  echo "Error: Prompt file not found: $PROMPT_PATH"
  echo "Available prompts in $RALPH_DIR/prompts/:"
  ls -1 "$RALPH_DIR/prompts/" 2>/dev/null || echo "  (none)"
  exit 1
fi

mkdir -p "$RALPH_DIR/history" "$RALPH_DIR/logs" "$RALPH_DIR/state"

echo "Ralph Wiggum Loop starting..."
echo "  Mode: $MODE"
echo "  Prompt: $PROMPT_PATH"
echo "  Max iterations: ${MAX:-unlimited}"
echo ""

iteration=0
while :; do
  ((iteration++))

  if [ "$MAX" -gt 0 ] && [ "$iteration" -gt "$MAX" ]; then
    echo "Max iterations ($MAX) reached"
    break
  fi

  echo "=== Iteration $iteration ==="

  LOG="$RALPH_DIR/logs/iteration-$(printf '%03d' $iteration).log"

  # Snapshot prompt if history enabled
  if [ "$HISTORY_ENABLED" = "true" ]; then
    cp "$PROMPT_PATH" "$RALPH_DIR/history/$(printf '%03d' $iteration)-$(basename "$PROMPT_PATH")"
  fi

  # Run pre-hook
  if [ -n "$PRE_HOOK" ]; then
    echo "Running pre-hook..."
    eval "$PRE_HOOK"
  fi

  # Inject iteration and mode, then run claude
  PROMPT_CONTENT=$(sed "s/{{ITERATION}}/$iteration/g; s/{{MODE}}/$MODE/g" "$PROMPT_PATH")

  echo "$PROMPT_CONTENT" | claude --dangerously-skip-permissions 2>&1 | tee "$LOG"

  # Check exit signals in log
  if grep -q "$COMPLETE_SIGNAL" "$LOG" 2>/dev/null; then
    echo ""
    echo "Loop complete signal received: $COMPLETE_SIGNAL"
    break
  fi

  if grep -q "$BLOCKED_SIGNAL" "$LOG" 2>/dev/null; then
    echo ""
    echo "Blocked signal detected. Review logs and update prompts."
    grep "$BLOCKED_SIGNAL" "$LOG"
    break
  fi

  if grep -q "$CLARIFY_SIGNAL" "$LOG" 2>/dev/null; then
    echo ""
    echo "Clarification needed. Review logs and update prompts."
    grep "$CLARIFY_SIGNAL" "$LOG"
    break
  fi

  # Check failure patterns
  SHOULD_PAUSE=false
  while IFS= read -r fp; do
    pattern=$(echo "$fp" | jq -r '.pattern')
    action=$(echo "$fp" | jq -r '.action')
    if grep -q "$pattern" "$LOG" 2>/dev/null; then
      echo "Failure detected: $pattern (action: $action)"
      if [ "$action" = "pause" ] && [ "$PAUSE_ON_FAIL" = "true" ]; then
        SHOULD_PAUSE=true
      fi
    fi
  done < <(echo "$CONFIG" | jq -c '."failure-patterns" // [] | .[]')

  if [ "$SHOULD_PAUSE" = "true" ]; then
    echo ""
    echo "Pausing for prompt tuning. Edit $PROMPT_PATH and run ralph-loop again."
    exit 1
  fi

  # Run post-hook
  if [ -n "$POST_HOOK" ]; then
    echo "Running post-hook..."
    eval "$POST_HOOK"
  fi

  echo ""
done

echo ""
echo "Ralph loop finished after $iteration iteration(s)."
