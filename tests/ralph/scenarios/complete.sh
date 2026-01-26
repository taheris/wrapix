# shellcheck shell=bash
# Complete scenario - always outputs RALPH_COMPLETE
# Used to test successful task completion

phase_plan() {
  echo "Creating spec..."
  echo "Spec created successfully."
  echo "RALPH_COMPLETE"
}

phase_ready() {
  echo "Creating task breakdown..."
  echo "Tasks created successfully."
  echo "RALPH_COMPLETE"
}

phase_step() {
  echo "Implementing task..."
  echo "Implementation complete."
  echo "All quality gates passed."
  echo "RALPH_COMPLETE"
}
