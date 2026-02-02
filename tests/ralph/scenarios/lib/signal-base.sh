# shellcheck shell=bash
# Base library for signal scenarios
# Provides default phase implementations that can be customized
#
# Signal scenarios should source this file and set:
#   SIGNAL_PLAN - signal to output at end of plan phase (empty = no signal)
#   SIGNAL_TODO - signal to output at end of todo phase (empty = no signal)
#   SIGNAL_RUN - signal to output at end of run phase (empty = no signal)
#
# Example:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/signal-base.sh"
#   SIGNAL_PLAN="RALPH_COMPLETE"
#   SIGNAL_TODO="RALPH_COMPLETE"
#   SIGNAL_RUN="RALPH_COMPLETE"

# Default signals (empty = no signal)
# Note: Scenarios may use either naming convention:
#   SIGNAL_PLAN / SIGNAL_TODO / SIGNAL_RUN (original)
#   SIGNAL_PLAN / SIGNAL_READY / SIGNAL_STEP (alternative)
SIGNAL_PLAN=""
SIGNAL_TODO=""
SIGNAL_RUN=""
SIGNAL_READY=""
SIGNAL_STEP=""

# Default messages for each phase
MSG_PLAN_WORK="Working on spec..."
MSG_PLAN_DONE="Spec work done."
MSG_TODO_WORK="Breaking down work..."
MSG_TODO_DONE="Task breakdown done."
MSG_RUN_WORK="Implementing task..."
MSG_RUN_DONE="Implementation work done."

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

phase_plan() {
  _emit_phase "$MSG_PLAN_WORK" "$MSG_PLAN_DONE" "$SIGNAL_PLAN"
}

phase_todo() {
  # Support both SIGNAL_TODO and SIGNAL_READY (alias)
  local signal="${SIGNAL_TODO:-$SIGNAL_READY}"
  _emit_phase "$MSG_TODO_WORK" "$MSG_TODO_DONE" "$signal"
}

phase_run() {
  # Support both SIGNAL_RUN and SIGNAL_STEP (alias)
  local signal="${SIGNAL_RUN:-$SIGNAL_STEP}"
  _emit_phase "$MSG_RUN_WORK" "$MSG_RUN_DONE" "$signal"
}
