# shellcheck shell=bash
# shellcheck disable=SC2034,SC1091  # SC2034: Variables used by sourced signal-base.sh
# Blocked scenario - outputs RALPH_BLOCKED signal
# Used to test that workflow pauses when blocked

# Source shared signal base (defines phase_* functions that read these variables)
# shellcheck source=lib/signal-base.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/signal-base.sh"

# Configure signals - all phases blocked with different reasons
SIGNAL_PLAN="RALPH_BLOCKED: Missing required context"
SIGNAL_READY="RALPH_BLOCKED: Spec is incomplete"
SIGNAL_STEP="RALPH_BLOCKED: Need API key to access external service"

# Customize messages to match original behavior
MSG_PLAN_WORK="Attempting to create spec..."
MSG_PLAN_DONE=""
MSG_READY_WORK="Attempting to create tasks..."
MSG_READY_DONE=""
MSG_STEP_WORK="Attempting to implement..."
MSG_STEP_DONE="Cannot proceed with implementation."
