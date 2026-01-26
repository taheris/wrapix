# No-signal scenario - outputs without RALPH_COMPLETE
# Used to test that issues remain open when no completion signal is given

phase_plan() {
  echo "Working on spec..."
  echo "Made some progress but didn't finish."
  # Note: No RALPH_COMPLETE signal
}

phase_ready() {
  echo "Analyzing spec..."
  echo "Encountered an issue, stopping."
  # Note: No RALPH_COMPLETE signal
}

phase_step() {
  echo "Implementing task..."
  echo "Still working on this..."
  echo "Need more time."
  # Note: No RALPH_COMPLETE signal - issue should remain in_progress
}
