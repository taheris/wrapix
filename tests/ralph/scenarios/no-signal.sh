# shellcheck shell=bash
# shellcheck disable=SC2034,SC1091  # SC2034: Variables used by sourced signal-base.sh
# No-signal scenario - outputs without RALPH_COMPLETE
# Used to test that issues remain open when no completion signal is given

# Source shared signal base (defines phase_* functions that read these variables)
# shellcheck source=lib/signal-base.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/signal-base.sh"

# Configure signals - none (empty strings are the default, but being explicit)
SIGNAL_PLAN=""
SIGNAL_READY=""
SIGNAL_STEP=""

# Customize messages to match original behavior
# Note: No RALPH_COMPLETE signal - issue should remain in_progress
MSG_PLAN_WORK="Working on spec..."
MSG_PLAN_DONE="Made some progress but didn't finish."
MSG_READY_WORK="Analyzing spec..."
MSG_READY_DONE="Encountered an issue, stopping."
MSG_STEP_WORK="Implementing task..."
MSG_STEP_DONE="Still working on this...
Need more time."
