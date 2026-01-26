# shellcheck shell=bash
# Hook test scenario - creates a marker file to verify hooks are called
# Tests: loop.pre-hook and loop.post-hook configuration
# The hooks write to files that the test can verify

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
  # so the test can verify the step ran between pre-hook and post-hook
  if [ -n "${TEST_DIR:-}" ]; then
    echo "step-executed" >> "$TEST_DIR/step-marker"
  fi
  echo "Step executed"
  echo "RALPH_COMPLETE"
}
