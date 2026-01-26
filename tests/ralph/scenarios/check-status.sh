# Check-status scenario - verifies issue is in_progress during execution
# Used to test that step.sh marks issues as in_progress before work starts

phase_step() {
  local issue_id="${CHECK_ISSUE_ID:-}"

  if [ -z "$issue_id" ]; then
    echo "ERROR: CHECK_ISSUE_ID not set"
    exit 1
  fi

  # Check the issue status
  local status
  status=$(bd show "$issue_id" --json 2>/dev/null | jq -r '.[0].status // "unknown"' 2>/dev/null || echo "unknown")

  echo "Checking issue status during execution..."
  echo "Issue: $issue_id"
  echo "Status: $status"

  if [ "$status" = "in_progress" ]; then
    echo "STATUS_WAS_IN_PROGRESS"
  else
    echo "STATUS_WAS_NOT_IN_PROGRESS: $status"
  fi

  echo "RALPH_COMPLETE"
}

phase_plan() {
  echo "RALPH_COMPLETE"
}

phase_ready() {
  echo "RALPH_COMPLETE"
}
