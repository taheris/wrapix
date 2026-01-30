# shellcheck shell=bash
# shellcheck disable=SC2034,SC1091  # SC2034: Variables used by sourced signal-base.sh
# Clarify scenario - outputs RALPH_CLARIFY signal
# Used to test that workflow pauses for clarification without closing issue
# Unlike RALPH_BLOCKED, RALPH_CLARIFY is for questions that need user input

# Source shared signal base (defines phase_* functions that read these variables)
# shellcheck source=lib/signal-base.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/signal-base.sh"

# Configure signals - all phases need clarification
SIGNAL_PLAN="RALPH_CLARIFY: Should the authentication use OAuth 2.0 or SAML?"
SIGNAL_READY="RALPH_CLARIFY: Should we create separate issues for frontend and backend?"
SIGNAL_STEP="RALPH_CLARIFY: The spec mentions 'retry logic' but doesn't specify max attempts - should I use 3 or 5?"

# Customize messages to match original behavior
MSG_PLAN_WORK="Analyzing requirements..."
MSG_PLAN_DONE=""
MSG_READY_WORK="Breaking down work..."
MSG_READY_DONE=""
MSG_STEP_WORK="Implementing task..."
MSG_STEP_DONE="Found an ambiguity in the spec."
