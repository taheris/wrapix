#!/usr/bin/env bash
set -euo pipefail

# ralph run [--once|-1] [--profile=X] [--spec <name>|-s <name>]
# Execute work items for a feature
#
# Modes:
#   Default: Loop through all work items until done (replaces loop.sh)
#   --once/-1: Execute single issue then exit (replaces step.sh)
#
# Options:
#   --profile=X: Override container profile (rust, python, base)
#   --spec/-s <name>: Operate on named spec (default: current spec from state/current)
#
# Spec resolution: reads the spec label ONCE at startup (from --spec flag or
# state/current). The label is held in memory for the duration of the run —
# switching state/current via 'ralph use' does not affect a running 'ralph run'.
# Does NOT update state/current during execution.
#
# Each iteration runs with fresh context (new claude process).
# When all beads complete, transitions WIP -> REVIEW.

# Parse flags (including --spec/-s early, before container detection)
RUN_ONCE=false
PROFILE_OVERRIDE=""
SPEC_FLAG=""
RUN_ARGS=()

for arg in "$@"; do
  if [ "${_next_is_spec:-}" = "1" ]; then
    SPEC_FLAG="$arg"
    unset _next_is_spec
    continue
  fi
  case "$arg" in
    --once|-1)
      RUN_ONCE=true
      ;;
    --profile=*)
      PROFILE_OVERRIDE="${arg#--profile=}"
      ;;
    --spec|-s)
      _next_is_spec=1
      ;;
    --spec=*)
      SPEC_FLAG="${arg#--spec=}"
      ;;
    *)
      RUN_ARGS+=("$arg")
      ;;
  esac
done
unset _next_is_spec

# Replace positional params with filtered args
set -- "${RUN_ARGS[@]+"${RUN_ARGS[@]}"}"

# Container detection: if not in container and wrapix is available, re-launch in container
# /etc/wrapix/claude-config.json only exists inside containers (baked into image)
if [ ! -f /etc/wrapix/claude-config.json ] && command -v wrapix &>/dev/null; then
  export RALPH_MODE=1
  export RALPH_CMD=run
  # Preserve --once and --spec flags in args for container re-exec
  RALPH_ARGS_PARTS=""
  if [ "$RUN_ONCE" = "true" ]; then
    RALPH_ARGS_PARTS="--once"
  fi
  if [ -n "$SPEC_FLAG" ]; then
    RALPH_ARGS_PARTS="${RALPH_ARGS_PARTS:+$RALPH_ARGS_PARTS }--spec $SPEC_FLAG"
  fi
  export RALPH_ARGS="${RALPH_ARGS_PARTS:+$RALPH_ARGS_PARTS }${*:-}"

  # Determine profile to use:
  # 1. --profile=X flag takes precedence
  # 2. Otherwise, read profile:X label from the next ready bead
  # 3. Fall back to 'base' if neither
  SELECTED_PROFILE="${PROFILE_OVERRIDE:-}"

  if [ -z "$SELECTED_PROFILE" ]; then
    # Resolve label from --spec flag or state/current (read once)
    RALPH_DIR="${RALPH_DIR:-.wrapix/ralph}"
    RUN_LABEL=""

    if [ -n "$SPEC_FLAG" ]; then
      RUN_LABEL="$SPEC_FLAG"
    elif [ -n "${1:-}" ]; then
      RUN_LABEL="$1"
    else
      # Read from state/current (plain text file)
      local_current="$RALPH_DIR/state/current"
      if [ -f "$local_current" ]; then
        RUN_LABEL=$(<"$local_current")
        RUN_LABEL="${RUN_LABEL#"${RUN_LABEL%%[![:space:]]*}"}"
        RUN_LABEL="${RUN_LABEL%"${RUN_LABEL##*[![:space:]]}"}"
      fi
    fi

    if [ -n "$RUN_LABEL" ]; then
      # Find next ready issue and extract profile label
      BEAD_LABEL="spec-$RUN_LABEL"
      NEXT_ISSUE_JSON=$(bd list --label "$BEAD_LABEL" --ready --sort priority --json 2>/dev/null || echo "[]")

      # Filter out epics and get first work item with profile label
      PROFILE_FROM_BEAD=$(echo "$NEXT_ISSUE_JSON" | jq -r '
        [.[] | select(.issue_type == "epic" | not)][0].labels // []
        | map(select(startswith("profile:")))
        | .[0]
        | if . then split(":")[1] else empty end
      ' 2>/dev/null || true)

      SELECTED_PROFILE="${PROFILE_FROM_BEAD:-base}"
    else
      SELECTED_PROFILE="base"
    fi
  fi

  # Select wrapix command based on profile
  # Available: wrapix (base), wrapix-rust, wrapix-python
  case "$SELECTED_PROFILE" in
    base)
      WRAPIX_CMD="wrapix"
      ;;
    rust|python)
      WRAPIX_CMD="wrapix-${SELECTED_PROFILE}"
      ;;
    *)
      echo "Warning: Unknown profile '$SELECTED_PROFILE', falling back to base" >&2
      WRAPIX_CMD="wrapix"
      ;;
  esac

  # Check if the profile-specific wrapix command exists
  if ! command -v "$WRAPIX_CMD" &>/dev/null; then
    echo "Warning: $WRAPIX_CMD not found, falling back to wrapix" >&2
    WRAPIX_CMD="wrapix"
  fi

  exec "$WRAPIX_CMD"
fi

# Load shared helpers
# shellcheck source=util.sh
source "$(dirname "$0")/util.sh"

# Pull latest beads state to ensure we have current data
# This is critical - container may have stale data
debug "Pulling beads database..."
bd dolt pull >/dev/null 2>&1 || warn "bd dolt pull failed, continuing with local state"

RALPH_DIR="${RALPH_DIR:-.wrapix/ralph}"
CONFIG_FILE="$RALPH_DIR/config.nix"
SPECS_DIR="specs"
SPECS_README="$SPECS_DIR/README.md"

# Resolve the spec label ONCE at startup using --spec flag or state/current.
# This label is held in a shell variable for the entire run duration —
# switching state/current via 'ralph use' does NOT affect a running 'ralph run'.
FEATURE_NAME=""
MOLECULE_ID=""
SPEC_HIDDEN="false"

if [ -n "$SPEC_FLAG" ]; then
  # Explicit --spec flag: use resolve_spec_label (errors on missing state file)
  FEATURE_NAME=$(resolve_spec_label "$SPEC_FLAG")
else
  # No --spec flag: try resolve_spec_label first, fall back to legacy current.json
  FEATURE_NAME=$(resolve_spec_label "" 2>/dev/null) || true

  if [ -z "$FEATURE_NAME" ]; then
    # Legacy fallback: try reading from current.json
    CURRENT_FILE="$RALPH_DIR/state/current.json"
    if [ -f "$CURRENT_FILE" ]; then
      FEATURE_NAME=$(jq -r '.label // empty' "$CURRENT_FILE" 2>/dev/null || true)
    fi
  fi
fi

# Read state from per-label state file: state/<label>.json
STATE_FILE="$RALPH_DIR/state/${FEATURE_NAME}.json"
if [ -f "$STATE_FILE" ]; then
  MOLECULE_ID=$(jq -r '.molecule // empty' "$STATE_FILE" 2>/dev/null || true)
  SPEC_HIDDEN=$(jq -r '.hidden // false' "$STATE_FILE" 2>/dev/null || true)
else
  # Legacy fallback: try reading from current.json if per-label state file doesn't exist
  CURRENT_FILE="$RALPH_DIR/state/current.json"
  if [ -f "$CURRENT_FILE" ]; then
    MOLECULE_ID=$(jq -r '.molecule // empty' "$CURRENT_FILE" 2>/dev/null || true)
    SPEC_HIDDEN=$(jq -r '.hidden // false' "$CURRENT_FILE" 2>/dev/null || true)
  fi
fi

# Validate we have required state
if [ -z "$MOLECULE_ID" ] && [ -z "$FEATURE_NAME" ]; then
  echo "Error: No molecule ID or feature label found." >&2
  echo "Run 'ralph todo' first to create a molecule." >&2
  exit 1
fi

require_file "$CONFIG_FILE" "Ralph config"

# Load config
debug "Loading config from $CONFIG_FILE"
CONFIG=$(nix eval --json --file "$CONFIG_FILE") || error "Failed to evaluate config: $CONFIG_FILE"
if ! validate_json "$CONFIG" "Config"; then
  error "Config file did not produce valid JSON"
fi

# Load hooks from config
HOOK_PRE_LOOP=""
HOOK_PRE_STEP=""
HOOK_POST_STEP=""
HOOK_POST_LOOP=""
HOOKS_ON_FAILURE="block"

HOOK_PRE_LOOP=$(echo "$CONFIG" | jq -r '.hooks."pre-loop" // empty' 2>/dev/null || true)
HOOK_PRE_STEP=$(echo "$CONFIG" | jq -r '.hooks."pre-step" // .loop."pre-hook" // empty' 2>/dev/null || true)
HOOK_POST_STEP=$(echo "$CONFIG" | jq -r '.hooks."post-step" // .loop."post-hook" // empty' 2>/dev/null || true)
HOOK_POST_LOOP=$(echo "$CONFIG" | jq -r '.hooks."post-loop" // empty' 2>/dev/null || true)
HOOKS_ON_FAILURE=$(echo "$CONFIG" | jq -r '."hooks-on-failure" // "block"' 2>/dev/null || echo "block")

debug "Loaded hooks - pre-loop: ${HOOK_PRE_LOOP:-(none)}, pre-step: ${HOOK_PRE_STEP:-(none)}"
debug "  post-step: ${HOOK_POST_STEP:-(none)}, post-loop: ${HOOK_POST_LOOP:-(none)}"
debug "hooks-on-failure: $HOOKS_ON_FAILURE"

#-----------------------------------------------------------------------------
# Hook Support
#-----------------------------------------------------------------------------

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
        echo "Hook '$hook_name' failed (exit code: $hook_exit). Stopping." >&2
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
        echo "Hook '$hook_name' failed (exit code: $hook_exit). Stopping." >&2
        exit $hook_exit
        ;;
    esac
  fi

  return 0
}

#-----------------------------------------------------------------------------
# Completion Helpers
#-----------------------------------------------------------------------------

# Update spec status to REVIEW in specs/README.md
update_spec_status_to_review() {
  local feature="$1"
  local hidden="$2"

  echo ""
  echo "All tasks for '$feature' are complete!"

  # Only mention README update if not hidden
  if [ "$hidden" != "true" ] && [ -f "$SPECS_README" ]; then
    echo "Please update specs/README.md to move the spec from WIP to REVIEW."
  fi
}

# Close the epic for this label if it exists and is open
close_epic_if_exists() {
  local label="$1"

  debug "Checking for open epic with label: $label"
  local epic_json
  epic_json=$(bd_json list --label "$label" --json) || {
    warn "Failed to check for epic"
    return 0
  }

  local epic_id
  epic_id=$(echo "$epic_json" | jq -r '[.[] | select(.issue_type == "epic" and (.status == "closed" | not))][0].id // empty' 2>/dev/null)

  if [ -n "$epic_id" ]; then
    echo "Closing epic: $epic_id"
    bd close "$epic_id" --reason="All tasks complete" || warn "Failed to close epic $epic_id"
  fi
}

# Check if all beads are complete
check_all_complete() {
  local label="$1"
  local feature="$2"
  local hidden="$3"

  # Check if any ready beads remain (excluding epics)
  local remaining=0
  local json
  json=$(bd_json list --label "$label" --ready --json) || {
    warn "Failed to check remaining issues"
    remaining=0
  }

  # Count non-epic work items
  if [ -n "$json" ] && echo "$json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    remaining=$(echo "$json" | jq '[.[] | select(.issue_type == "epic" | not)] | length')
  fi
  debug "Remaining ready work items with label $label: $remaining"

  if [ "$remaining" -eq 0 ]; then
    # Close the epic if all tasks are done
    close_epic_if_exists "$label"
    update_spec_status_to_review "$feature" "$hidden"
  fi
}

#-----------------------------------------------------------------------------
# Core Step Execution
#-----------------------------------------------------------------------------

# Execute a single work item
# Returns:
#   0 - Task completed, more work may remain
#   100 - All work complete
#   1 - Task failed
run_step() {
  local label="$1"
  local hidden="$2"

  local bead_label="spec-$label"
  debug "Looking for issues with label: $bead_label"

  # Find next ready issue with this label (excluding epics - they're containers, not work items)
  local bd_list_json
  bd_list_json=$(bd_json list --label "$bead_label" --ready --sort priority --json) || {
    warn "bd list command failed"
    bd_list_json="[]"
  }

  # Filter out epics and beads with awaiting:input label (not truly ready)
  local bd_work_items
  bd_work_items=$(echo "$bd_list_json" | jq '[.[] | select((.issue_type == "epic" | not) and ((.labels // []) | map(select(. == "awaiting:input")) | length == 0))]' 2>/dev/null || echo "[]")

  # Note: || true prevents set -e from exiting on empty array (return code 1)
  local next_issue
  next_issue=$(bd_list_first_id "$bd_work_items") || true

  if [ -z "$next_issue" ]; then
    echo "No more ready issues with label: $bead_label"
    echo "All work complete!"

    # Close the epic and transition WIP -> REVIEW
    close_epic_if_exists "$bead_label"
    update_spec_status_to_review "$label" "$hidden"
    # Return 100 signals "all complete"
    return 100
  fi

  echo "Working on: $next_issue"
  bd show "$next_issue"

  # Mark as in-progress
  bd update "$next_issue" --status=in_progress

  # Write bead ID for session audit trail (read by entrypoint on exit)
  echo "$next_issue" > /tmp/wrapix-bead-id

  # Get issue details as JSON for prompt substitution
  debug "Fetching issue details for $next_issue"
  local issue_json
  issue_json=$(bd_json show "$next_issue" --json) || {
    warn "bd show failed for $next_issue"
    issue_json="[]"
  }

  # Parse issue fields
  local issue_title=""
  local issue_desc=""

  if ! validate_json_array "$issue_json" "Issue $next_issue"; then
    warn "Could not parse issue details for $next_issue, continuing with empty values"
  else
    issue_title=$(json_array_field "$issue_json" "title" "Issue")
    issue_desc=$(json_array_field "$issue_json" "description" "Issue")
  fi

  # Warn if critical fields are empty
  if [ -z "$issue_title" ]; then
    warn "Issue $next_issue has no title"
  fi
  debug "Issue title: ${issue_title:0:50}..."

  # Pin context from specs/README.md
  local pinned_context=""
  if [ -f "$SPECS_README" ]; then
    pinned_context=$(cat "$SPECS_README")
  fi

  # Compute spec path based on hidden flag
  local spec_path
  if [ "$hidden" = "true" ]; then
    spec_path="$RALPH_DIR/state/$label.md"
  else
    spec_path="$SPECS_DIR/$label.md"
  fi

  # Render template using centralized render_template function
  local work_prompt
  work_prompt=$(render_template run \
    "SPEC_PATH=$spec_path" \
    "ISSUE_ID=$next_issue" \
    "TITLE=$issue_title" \
    "LABEL=$label" \
    "MOLECULE_ID=$MOLECULE_ID" \
    "DESCRIPTION=$issue_desc" \
    "PINNED_CONTEXT=$pinned_context" \
    "EXIT_SIGNALS=")

  mkdir -p "$RALPH_DIR/logs"
  local log="$RALPH_DIR/logs/work-$next_issue.log"

  # Run claude with FRESH CONTEXT (new process)
  echo ""
  echo "=== Starting work (fresh context) ==="
  echo ""

  # Use stream-json for real-time output display with configurable visibility
  export WORK_PROMPT="$work_prompt"
  run_claude_stream "WORK_PROMPT" "$log" "$CONFIG"

  # Check for completion by examining the result in the JSON log
  if jq -e 'select(.type == "result") | .result | contains("RALPH_COMPLETE")' "$log" >/dev/null 2>&1; then
    echo ""
    echo "Work complete. Closing issue: $next_issue"
    bd close "$next_issue"

    # Check if all beads with this label are complete
    check_all_complete "$bead_label" "$label" "$hidden"
    return 0
  elif jq -e 'select(.type == "result") | .result | contains("RALPH_CLARIFY")' "$log" >/dev/null 2>&1; then
    # Agent needs clarification — add awaiting:input label and store question
    local clarify_text
    clarify_text=$(jq -r 'select(.type == "result") | .result' "$log" \
      | grep -oP 'RALPH_CLARIFY:\s*\K.*' | head -1)

    echo ""
    echo "Agent needs clarification on issue: $next_issue"
    if [ -n "$clarify_text" ]; then
      echo "  Question: $clarify_text"
    fi

    # Add awaiting:input label so ralph run skips this bead
    bd update "$next_issue" --add-label "awaiting:input" || warn "Failed to add awaiting:input label"

    # Store question in bead notes
    if [ -n "$clarify_text" ]; then
      bd update "$next_issue" --append-notes "Question: $clarify_text" || warn "Failed to store question in notes"
    fi

    echo ""
    echo "To answer and unblock:"
    echo "  bd update $next_issue --append-notes 'Answer: <your answer>'"
    echo "  bd update $next_issue --remove-label awaiting:input"
    return 1
  else
    echo ""
    echo "Work did not complete. Issue remains in-progress: $next_issue"
    echo "Review log: $log"
    echo ""
    echo "To retry this issue, reset its status:"
    echo "  bd update $next_issue --status=open"
    return 1
  fi
}

#-----------------------------------------------------------------------------
# Main Execution
#-----------------------------------------------------------------------------

if [ "$RUN_ONCE" = "true" ]; then
  echo "Ralph Wiggum executing single step..."
else
  echo "Ralph Wiggum work loop starting..."
fi

if [ -n "$FEATURE_NAME" ]; then
  echo "  Feature: $FEATURE_NAME"
fi
if [ -n "$MOLECULE_ID" ]; then
  echo "  Molecule: $MOLECULE_ID"
fi
echo ""

# Run pre-loop hook (even in --once mode, for consistency)
run_hook "pre-loop" "$HOOK_PRE_LOOP"

step_count=0
current_issue_id=""
FINAL_EXIT_CODE=0

while true; do
  ((++step_count))

  if [ "$RUN_ONCE" != "true" ]; then
    echo "=== Step $step_count ==="
  fi

  # Get current issue ID for hook variable substitution
  # Query using molecule ID (preferred) or fall back to feature label
  if [ -n "$MOLECULE_ID" ]; then
    # Use bd ready with molecule filter - more direct and accurate
    current_issue_id=$(bd ready --mol "$MOLECULE_ID" --limit 1 --sort priority 2>/dev/null | \
      grep -oE '^[a-z]+-[a-zA-Z0-9.]+' | head -1 || true)
  elif [ -n "$FEATURE_NAME" ]; then
    # Fall back to label-based query for backward compatibility
    current_issue_id=$(bd list --label "spec-$FEATURE_NAME" --ready --sort priority --json 2>/dev/null | \
      jq -r '[.[] | select(.issue_type == "epic" | not)][0].id // empty' 2>/dev/null || true)
  fi

  # Run pre-step hook
  run_hook "pre-step" "$HOOK_PRE_STEP" "$current_issue_id" "$step_count"

  # Execute the step
  set +e
  run_step "$FEATURE_NAME" "$SPEC_HIDDEN"
  EXIT_CODE=$?
  set -e

  # Run post-step hook (with exit code available)
  run_hook "post-step" "$HOOK_POST_STEP" "$current_issue_id" "$step_count" "$EXIT_CODE"

  case $EXIT_CODE in
    0)
      # Task completed, more work may remain
      if [ "$RUN_ONCE" = "true" ]; then
        # Exit after single step
        break
      fi
      # Continue loop
      ;;
    100)
      # All work complete - exit loop
      # In --once mode, propagate exit code 100 to indicate "no work to do"
      if [ "$RUN_ONCE" = "true" ]; then
        FINAL_EXIT_CODE=100
      fi
      break
      ;;
    *)
      echo ""
      echo "Step failed (exit code: $EXIT_CODE). Pausing work."
      echo "Review the logs and fix the issue before continuing."
      echo "To resume: ralph run${FEATURE_NAME:+ $FEATURE_NAME}"
      exit 1
      ;;
  esac

  if [ "$RUN_ONCE" != "true" ]; then
    echo ""
    echo "--- Continuing to next step ---"
    echo ""
  fi
done

# Run post-loop hook (even in --once mode, for consistency)
run_hook "post-loop" "$HOOK_POST_LOOP"

echo ""
echo "All work complete after $step_count step(s)!"

exit $FINAL_EXIT_CODE
