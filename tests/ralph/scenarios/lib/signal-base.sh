# shellcheck shell=bash
# Base library for signal scenarios
# Provides default phase implementations that can be customized
#
# Signal scenarios should source this file and set:
#   SIGNAL_PLAN - signal to output at end of plan phase (empty = no signal)
#   SIGNAL_READY - signal to output at end of ready phase (empty = no signal)
#   SIGNAL_STEP - signal to output at end of step phase (empty = no signal)
#
# Example:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/signal-base.sh"
#   SIGNAL_PLAN="RALPH_COMPLETE"
#   SIGNAL_READY="RALPH_COMPLETE"
#   SIGNAL_STEP="RALPH_COMPLETE"

# Default signals (empty = no signal)
SIGNAL_PLAN=""
SIGNAL_READY=""
SIGNAL_STEP=""

# Default messages for each phase
MSG_PLAN_WORK="Working on spec..."
MSG_PLAN_DONE="Spec work done."
MSG_READY_WORK="Breaking down work..."
MSG_READY_DONE="Task breakdown done."
MSG_STEP_WORK="Implementing task..."
MSG_STEP_DONE="Implementation work done."

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

phase_ready() {
  _emit_phase "$MSG_READY_WORK" "$MSG_READY_DONE" "$SIGNAL_READY"
}

phase_step() {
  _emit_phase "$MSG_STEP_WORK" "$MSG_STEP_DONE" "$SIGNAL_STEP"
}
