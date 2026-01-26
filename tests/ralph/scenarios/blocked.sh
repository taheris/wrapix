# Blocked scenario - outputs RALPH_BLOCKED signal
# Used to test that workflow pauses when blocked

phase_plan() {
  echo "Attempting to create spec..."
  echo "RALPH_BLOCKED: Missing required context"
}

phase_ready() {
  echo "Attempting to create tasks..."
  echo "RALPH_BLOCKED: Spec is incomplete"
}

phase_step() {
  echo "Attempting to implement..."
  echo "Cannot proceed with implementation."
  echo "RALPH_BLOCKED: Need API key to access external service"
}
