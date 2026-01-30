# shellcheck shell=bash
# Clarify scenario - outputs RALPH_CLARIFY signal
# Used to test that workflow pauses for clarification without closing issue
# Unlike RALPH_BLOCKED, RALPH_CLARIFY is for questions that need user input

phase_plan() {
  echo "Analyzing requirements..."
  echo "RALPH_CLARIFY: Should the authentication use OAuth 2.0 or SAML?"
}

phase_ready() {
  echo "Breaking down work..."
  echo "RALPH_CLARIFY: Should we create separate issues for frontend and backend?"
}

phase_step() {
  echo "Implementing task..."
  echo "Found an ambiguity in the spec."
  echo "RALPH_CLARIFY: The spec mentions 'retry logic' but doesn't specify max attempts - should I use 3 or 5?"
}
