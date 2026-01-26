# shellcheck shell=bash
# Happy path scenario - full workflow test
# Tests: ralph plan -> ralph ready -> ralph step -> ralph loop
#
# This scenario simulates a complete feature workflow:
# 1. plan: Creates a spec file
# 2. ready: Creates an epic and tasks with dependencies
# 3. step: Completes the first unblocked task
# 4. loop: Completes remaining tasks and closes epic

# State tracking (set by test harness)
# LABEL - feature label (e.g., "test-feature")
# TEST_DIR - test directory root
# RALPH_DIR - ralph directory (typically .claude/ralph)

phase_plan() {
  # Create the spec file
  local spec_path="${SPEC_PATH:-specs/${LABEL:-happy-path-test}.md}"

  mkdir -p "$(dirname "$spec_path")"

  cat > "$spec_path" << 'SPEC_EOF'
# Happy Path Feature

A test feature for verifying the full ralph workflow.

## Problem Statement

Need to verify that ralph plan, ready, step, and loop work correctly together.

## Requirements

### Functional

1. **Task A** - First task with no dependencies
2. **Task B** - Second task that depends on Task A
3. **Task C** - Third task that depends on Task A

### Non-Functional

- Tests should be deterministic
- Tests should be fast

## Success Criteria

- [ ] All tasks are completed in dependency order
- [ ] Epic is closed when all tasks complete

## Affected Files

| File | Change |
|------|--------|
| `tests/ralph/scenarios/happy-path.sh` | This test scenario |
SPEC_EOF

  echo "Created spec at $spec_path"
  echo "RALPH_COMPLETE"
}

phase_ready() {
  # Get label from state or environment
  local label="${LABEL:-happy-path-test}"

  # Create an epic for this feature
  local epic_json
  epic_json=$(bd create --title="Happy Path Feature" --type=epic --labels="rl-$label" --json 2>/dev/null)
  local epic_id
  epic_id=$(echo "$epic_json" | jq -r '.id')

  echo "Created epic: $epic_id"

  # Create tasks (all independent for happy path test)
  # Note: Dependency tests are covered by test_step_respects_dependencies.
  # The happy path test focuses on verifying the full workflow from
  # plan -> ready -> step -> loop without dependency complications.

  local task_a_json
  task_a_json=$(bd create --title="Task A - First task" --type=task --labels="rl-$label" --json 2>/dev/null)
  local task_a_id
  task_a_id=$(echo "$task_a_json" | jq -r '.id')
  echo "Created Task A: $task_a_id"

  local task_b_json
  task_b_json=$(bd create --title="Task B - Second task" --type=task --labels="rl-$label" --json 2>/dev/null)
  local task_b_id
  task_b_id=$(echo "$task_b_json" | jq -r '.id')
  echo "Created Task B: $task_b_id"

  local task_c_json
  task_c_json=$(bd create --title="Task C - Third task" --type=task --labels="rl-$label" --json 2>/dev/null)
  local task_c_id
  task_c_id=$(echo "$task_c_json" | jq -r '.id')
  echo "Created Task C: $task_c_id"

  echo ""
  echo "Task breakdown:"
  echo "  Epic: $epic_id (Happy Path Feature)"
  echo "  Task A: $task_a_id"
  echo "  Task B: $task_b_id"
  echo "  Task C: $task_c_id"
  echo ""
  echo "RALPH_COMPLETE"
}

phase_step() {
  # Simulate implementing the current task
  echo "Implementing the assigned task..."
  echo "Reading spec and understanding requirements..."
  echo "Writing code..."
  echo "Running tests..."
  echo "All quality gates passed."
  echo ""
  echo "RALPH_COMPLETE"
}
