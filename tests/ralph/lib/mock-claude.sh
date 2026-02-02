#!/usr/bin/env bash
# Mock Claude infrastructure for ralph integration tests
# Provides helpers for creating mock Claude responses in stream-json format

#-----------------------------------------------------------------------------
# Stream JSON Output Helpers
#-----------------------------------------------------------------------------

# Output text in stream-json format
# Usage: stream_text "your message"
stream_text() {
  local text="$1"
  # Escape for JSON (handle newlines, quotes, backslashes)
  local escaped
  escaped=$(echo "$text" | jq -Rs '.')
  # Output as assistant message with text content
  echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":$escaped}]}}"
}

# Output final result in stream-json format
# Usage: stream_result "final output text"
stream_result() {
  local text="$1"
  local escaped
  escaped=$(echo "$text" | jq -Rs '.')
  echo "{\"type\":\"result\",\"result\":$escaped,\"cost_usd\":0,\"usage\":{\"input_tokens\":100,\"output_tokens\":50},\"duration_ms\":1000}"
}

#-----------------------------------------------------------------------------
# Phase Detection
#-----------------------------------------------------------------------------

# Detect phase from prompt content
# Usage: detect_phase "$PROMPT"
# Returns: plan, todo, or run
detect_phase() {
  local prompt="$1"

  # Check for run phase markers FIRST (most specific)
  # Matches: "# Implementation Step" (the heading), "## Issue Details", "run.md"
  if echo "$prompt" | grep -qE "^# Implementation Step|^## Issue Details|run\.md"; then
    echo "run"
    return
  fi

  # Check for todo phase markers
  # Matches: "Convert Spec to Tasks", "task breakdown", "create task beads", "todo-new.md", "todo-update.md"
  if echo "$prompt" | grep -qiE "convert.spec|task.breakdown|create.task.bead|todo-new\.md|todo-update\.md"; then
    echo "todo"
    return
  fi

  # Check for plan phase markers
  # Matches: "Specification Interview", "spec interview", "plan-new.md", "plan-update.md"
  if echo "$prompt" | grep -qiE "specification.interview|spec.interview|plan-new\.md|plan-update\.md"; then
    echo "plan"
    return
  fi

  # Default to run (most common)
  echo "run"
}

#-----------------------------------------------------------------------------
# Mock Claude Execution
#-----------------------------------------------------------------------------

# Run mock Claude with a scenario file
# Usage: run_mock_claude <scenario_file> <prompt>
# Expects scenario file to define: phase_plan, phase_todo, phase_run functions
run_mock_claude() {
  local scenario_file="$1"
  local prompt="$2"

  # Debug output (only if RALPH_DEBUG is set)
  if [ "${RALPH_DEBUG:-0}" = "1" ]; then
    echo "[mock-claude] Scenario: ${scenario_file:-<none>}" >&2
    echo "[mock-claude] Prompt length: ${#prompt}" >&2
  fi

  # If no scenario, just echo and exit
  if [ -z "$scenario_file" ]; then
    stream_text "[mock-claude] No scenario file specified"
    stream_result "[mock-claude] Prompt received"
    return 0
  fi

  # Check scenario file exists
  if [ ! -f "$scenario_file" ]; then
    echo "[mock-claude] ERROR: Scenario file not found: $scenario_file" >&2
    return 1
  fi

  # Source the scenario file
  # shellcheck source=/dev/null
  source "$scenario_file"

  # Detect and run phase
  local phase
  phase=$(detect_phase "$prompt")

  if [ "${RALPH_DEBUG:-0}" = "1" ]; then
    echo "[mock-claude] Detected phase: $phase" >&2
  fi

  # Capture the phase function output
  local phase_output=""
  case "$phase" in
    plan)
      if type phase_plan &>/dev/null; then
        phase_output=$(phase_plan)
      else
        phase_output="[mock-claude] No phase_plan function defined"
      fi
      ;;
    todo)
      if type phase_todo &>/dev/null; then
        phase_output=$(phase_todo)
      else
        phase_output="[mock-claude] No phase_todo function defined"
      fi
      ;;
    run)
      if type phase_run &>/dev/null; then
        phase_output=$(phase_run)
      else
        phase_output="[mock-claude] No phase_run function defined"
      fi
      ;;
    *)
      phase_output="[mock-claude] Unknown phase: $phase"
      ;;
  esac

  # Output the phase result in stream-json format
  # First, output any intermediate text (everything except RALPH_* signals)
  local non_signal_output
  non_signal_output=$(echo "$phase_output" | grep -v "^RALPH_" || true)
  if [ -n "$non_signal_output" ]; then
    stream_text "$non_signal_output"
  fi

  # Then output the result (including any RALPH_* signals)
  stream_result "$phase_output"
}

#-----------------------------------------------------------------------------
# Signal Base Library
#-----------------------------------------------------------------------------
# Provides default phase implementations that can be customized
# Signal scenarios should set:
#   SIGNAL_PLAN - signal to output at end of plan phase (empty = no signal)
#   SIGNAL_TODO - signal to output at end of todo phase (empty = no signal)
#   SIGNAL_RUN - signal to output at end of run phase (empty = no signal)

# Default signals (empty = no signal)
# Note: Scenarios may use either naming convention:
#   SIGNAL_PLAN / SIGNAL_TODO / SIGNAL_RUN (original)
#   SIGNAL_PLAN / SIGNAL_READY / SIGNAL_STEP (alternative)
SIGNAL_PLAN="${SIGNAL_PLAN:-}"
SIGNAL_TODO="${SIGNAL_TODO:-}"
SIGNAL_RUN="${SIGNAL_RUN:-}"
SIGNAL_READY="${SIGNAL_READY:-}"
SIGNAL_STEP="${SIGNAL_STEP:-}"

# Default messages for each phase
MSG_PLAN_WORK="${MSG_PLAN_WORK:-Working on spec...}"
MSG_PLAN_DONE="${MSG_PLAN_DONE:-Spec work done.}"
MSG_TODO_WORK="${MSG_TODO_WORK:-Breaking down work...}"
MSG_TODO_DONE="${MSG_TODO_DONE:-Task breakdown done.}"
MSG_RUN_WORK="${MSG_RUN_WORK:-Implementing task...}"
MSG_RUN_DONE="${MSG_RUN_DONE:-Implementation work done.}"

# Helper to output phase content with optional signal
_emit_phase() {
  local work_msg="$1"
  local done_msg="$2"
  local signal="${3:-}"

  if [ -n "$work_msg" ]; then
    echo "$work_msg"
  fi
  if [ -n "$done_msg" ]; then
    echo "$done_msg"
  fi
  if [ -n "$signal" ]; then
    echo "$signal"
  fi
}

# Default phase implementations (can be overridden by scenarios)
_default_phase_plan() {
  _emit_phase "$MSG_PLAN_WORK" "$MSG_PLAN_DONE" "$SIGNAL_PLAN"
}

_default_phase_todo() {
  # Support both SIGNAL_TODO and SIGNAL_READY (alias)
  local signal="${SIGNAL_TODO:-$SIGNAL_READY}"
  _emit_phase "$MSG_TODO_WORK" "$MSG_TODO_DONE" "$signal"
}

_default_phase_run() {
  # Support both SIGNAL_RUN and SIGNAL_STEP (alias)
  local signal="${SIGNAL_RUN:-$SIGNAL_STEP}"
  _emit_phase "$MSG_RUN_WORK" "$MSG_RUN_DONE" "$signal"
}
