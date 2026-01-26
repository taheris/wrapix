# shellcheck shell=bash
# Failure pattern scenario - outputs configurable failure pattern
# Used to test failure-patterns configuration
# MOCK_FAILURE_OUTPUT controls what pattern is output

phase_plan() {
  echo "Plan phase"
  echo "RALPH_COMPLETE"
}

phase_ready() {
  echo "Ready phase"
  echo "RALPH_COMPLETE"
}

phase_step() {
  # Output the failure pattern from environment (set by test)
  local failure_output="${MOCK_FAILURE_OUTPUT:-}"

  if [ -n "$failure_output" ]; then
    echo "Processing task..."
    echo "$failure_output"
    # Note: Still output RALPH_COMPLETE because the failure pattern
    # detection happens in the loop/step wrapper, not here
    echo "RALPH_COMPLETE"
  else
    echo "Task completed normally"
    echo "RALPH_COMPLETE"
  fi
}
