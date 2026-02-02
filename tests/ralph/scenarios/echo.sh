# shellcheck shell=bash
# Echo scenario - simple echo for basic testing
# Used to verify mock-claude is working

phase_plan() {
  echo "Echo scenario: plan phase"
  echo "RALPH_COMPLETE"
}

phase_todo() {
  echo "Echo scenario: ready phase"
  echo "RALPH_COMPLETE"
}

phase_run() {
  echo "Echo scenario: run phase"
  echo "RALPH_COMPLETE"
}
