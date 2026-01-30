#!/usr/bin/env bash
set -euo pipefail

# ralph loop [feature-name]
# Iterate through all work items for a feature
# Each step runs with fresh context (new claude process)
# When last bead completes, transitions WIP -> REVIEW
#
# Note: No container check here - each ralph-step call enters its own
# fresh container, which is the intended behavior for context isolation.

# Load shared helpers
# shellcheck source=util.sh
source "$(dirname "$0")/util.sh"

RALPH_DIR="${RALPH_DIR:-.ralph}"
CONFIG_FILE="$RALPH_DIR/config.nix"

# Get feature name from argument or state
FEATURE_NAME="${1:-}"
if [ -z "$FEATURE_NAME" ]; then
  CURRENT_FILE="$RALPH_DIR/state/current.json"
  if [ -f "$CURRENT_FILE" ]; then
    FEATURE_NAME=$(jq -r '.label // empty' "$CURRENT_FILE" 2>/dev/null || true)
  fi
fi

# Load config for hooks if available
CONFIG=""
HOOK_PRE_LOOP=""
HOOK_PRE_STEP=""
HOOK_POST_STEP=""
HOOK_POST_LOOP=""
HOOKS_ON_FAILURE="block"

if [ -f "$CONFIG_FILE" ]; then
  CONFIG=$(nix eval --json --file "$CONFIG_FILE" 2>/dev/null || echo "{}")
  # New hooks.* schema takes precedence, with backward compat for loop.pre-hook/post-hook
  # loop.pre-hook/post-hook were "before/after each iteration" -> maps to pre-step/post-step
  HOOK_PRE_LOOP=$(echo "$CONFIG" | jq -r '.hooks."pre-loop" // empty' 2>/dev/null || true)
  HOOK_PRE_STEP=$(echo "$CONFIG" | jq -r '.hooks."pre-step" // .loop."pre-hook" // empty' 2>/dev/null || true)
  HOOK_POST_STEP=$(echo "$CONFIG" | jq -r '.hooks."post-step" // .loop."post-hook" // empty' 2>/dev/null || true)
  HOOK_POST_LOOP=$(echo "$CONFIG" | jq -r '.hooks."post-loop" // empty' 2>/dev/null || true)
  HOOKS_ON_FAILURE=$(echo "$CONFIG" | jq -r '."hooks-on-failure" // "block"' 2>/dev/null || echo "block")
  debug "Loaded hooks - pre-loop: ${HOOK_PRE_LOOP:-(none)}, pre-step: ${HOOK_PRE_STEP:-(none)}, post-step: ${HOOK_POST_STEP:-(none)}, post-loop: ${HOOK_POST_LOOP:-(none)}"
  debug "hooks-on-failure: $HOOKS_ON_FAILURE"
fi

# Run a hook with template variable substitution
# Usage: run_hook "hook_name" "hook_cmd" [issue_id] [step_count] [step_exit_code]
# Returns: 0 on success or if hook is empty, handles failure per HOOKS_ON_FAILURE
run_hook() {
  local hook_name="$1"
  local hook_cmd="$2"
  local issue_id="${3:-}"
  local step_count="${4:-}"
  local step_exit_code="${5:-}"

  # Skip if hook is empty
  [ -z "$hook_cmd" ] && return 0

  debug "Running hook: $hook_name"

  # Template variable substitution (FR4)
  hook_cmd="${hook_cmd//\{\{LABEL\}\}/${FEATURE_NAME:-}}"
  hook_cmd="${hook_cmd//\{\{ISSUE_ID\}\}/${issue_id}}"
  hook_cmd="${hook_cmd//\{\{STEP_COUNT\}\}/${step_count}}"
  hook_cmd="${hook_cmd//\{\{STEP_EXIT_CODE\}\}/${step_exit_code}}"

  debug "Hook command after substitution: $hook_cmd"

  # Execute the hook in a subshell to capture exit status
  # (direct eval would exit the shell if hook contains 'exit N')
  set +e
  (eval "$hook_cmd")
  local hook_exit=$?
  set -e

  if [ $hook_exit -ne 0 ]; then
    case "$HOOKS_ON_FAILURE" in
      block)
        echo "Hook '$hook_name' failed (exit code: $hook_exit). Stopping loop." >&2
        exit $hook_exit
        ;;
      warn)
        warn "Hook '$hook_name' failed (exit code: $hook_exit), continuing..."
        ;;
      skip)
        # Silently continue
        debug "Hook '$hook_name' failed (exit code: $hook_exit), skipping"
        ;;
      *)
        # Unknown mode, treat as block
        echo "Hook '$hook_name' failed (exit code: $hook_exit). Stopping loop." >&2
        exit $hook_exit
        ;;
    esac
  fi

  return 0
}

echo "Ralph Wiggum work loop starting..."
if [ -n "$FEATURE_NAME" ]; then
  echo "  Feature: $FEATURE_NAME"
fi
echo ""

# Run pre-loop hook
run_hook "pre-loop" "$HOOK_PRE_LOOP"

step_count=0
current_issue_id=""
while true; do
  ((++step_count))
  echo "=== Step $step_count ==="

  # Get current issue ID for hook variable substitution
  # This queries beads for the next ready issue with the feature label
  if [ -n "$FEATURE_NAME" ]; then
    current_issue_id=$(bd list --label "spec-$FEATURE_NAME" --ready --sort priority --json 2>/dev/null | \
      jq -r '[.[] | select(.issue_type == "epic" | not)][0].id // empty' 2>/dev/null || true)
  fi

  # Run pre-step hook
  run_hook "pre-step" "$HOOK_PRE_STEP" "$current_issue_id" "$step_count"

  # Run ralph-step directly for full TTY interactivity
  set +e
  ralph-step ${FEATURE_NAME:+"$FEATURE_NAME"}
  EXIT_CODE=$?
  set -e

  # Run post-step hook (with exit code available)
  run_hook "post-step" "$HOOK_POST_STEP" "$current_issue_id" "$step_count" "$EXIT_CODE"

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

# Run post-loop hook
run_hook "post-loop" "$HOOK_POST_LOOP"

echo ""
echo "All work complete after $step_count step(s)!"
