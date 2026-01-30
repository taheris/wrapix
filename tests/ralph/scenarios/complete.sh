# shellcheck shell=bash
# shellcheck disable=SC2034,SC1091  # SC2034: Variables used by sourced signal-base.sh
# Complete scenario - always outputs RALPH_COMPLETE
# Used to test successful task completion

# Source shared signal base (defines phase_* functions that read these variables)
# shellcheck source=lib/signal-base.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/signal-base.sh"

# Configure signals - all phases complete successfully
SIGNAL_PLAN="RALPH_COMPLETE"
SIGNAL_READY="RALPH_COMPLETE"
SIGNAL_STEP="RALPH_COMPLETE"

# Customize messages to match original behavior
MSG_PLAN_WORK="Creating spec..."
MSG_PLAN_DONE="Spec created successfully."
MSG_READY_WORK="Creating task breakdown..."
MSG_READY_DONE="Tasks created successfully."
MSG_STEP_WORK="Implementing task..."
MSG_STEP_DONE="Implementation complete.
All quality gates passed."
