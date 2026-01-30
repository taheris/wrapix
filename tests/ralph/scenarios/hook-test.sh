# shellcheck shell=bash
# Hook test scenario - comprehensive hook testing
# Tests: All four hook points (pre-loop, pre-step, post-step, post-loop)
# Template variable substitution and failure handling modes
#
# The scenario creates marker files that tests can verify.
# Uses TEST_DIR environment variable for marker file paths.

phase_plan() {
  echo "Plan phase (hooks test)"
  echo "RALPH_COMPLETE"
}

phase_ready() {
  echo "Ready phase (hooks test)"
  echo "RALPH_COMPLETE"
}

phase_step() {
  # Create a marker file in the expected location (TEST_DIR/step-marker)
  # so the test can verify the step ran between pre-step and post-step hooks
  if [ -n "${TEST_DIR:-}" ]; then
    echo "step-executed:${MOCK_STEP_COUNT:-1}" >> "$TEST_DIR/step-marker"
  fi
  echo "Step executed"
  echo "RALPH_COMPLETE"
}
