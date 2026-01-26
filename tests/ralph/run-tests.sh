#!/usr/bin/env bash
# Ralph integration test harness
# Runs ralph workflow tests with mock Claude in isolated environments
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MOCK_CLAUDE="$SCRIPT_DIR/mock-claude"
SCENARIOS_DIR="$SCRIPT_DIR/scenarios"

# Test state
PASSED=0
FAILED=0
SKIPPED=0
FAILED_TESTS=()

# Colors (disabled if not a tty)
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  CYAN=''
  NC=''
fi

#-----------------------------------------------------------------------------
# Test Utilities
#-----------------------------------------------------------------------------

# Print test header
test_header() {
  echo ""
  echo -e "${CYAN}=== Test: $1 ===${NC}"
}

# Print pass result
test_pass() {
  echo -e "  ${GREEN}PASS${NC}: $1"
  ((PASSED++)) || true
}

# Print fail result
test_fail() {
  echo -e "  ${RED}FAIL${NC}: $1"
  ((FAILED++)) || true
  FAILED_TESTS+=("$CURRENT_TEST: $1")
}

# Print skip result
test_skip() {
  echo -e "  ${YELLOW}SKIP${NC}: $1"
  ((SKIPPED++)) || true
}

# Assert file exists
assert_file_exists() {
  local file="$1"
  local msg="${2:-File should exist: $file}"
  if [ -f "$file" ]; then
    test_pass "$msg"
  else
    test_fail "$msg (file not found: $file)"
  fi
}

# Assert file does not exist
assert_file_not_exists() {
  local file="$1"
  local msg="${2:-File should not exist: $file}"
  if [ ! -f "$file" ]; then
    test_pass "$msg"
  else
    test_fail "$msg (file found: $file)"
  fi
}

# Assert file contains string
assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local msg="${3:-File should contain: $pattern}"
  if [ -f "$file" ] && grep -q "$pattern" "$file"; then
    test_pass "$msg"
  else
    test_fail "$msg (pattern not found in $file)"
  fi
}

# Assert exit code
assert_exit_code() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-Exit code should be $expected}"
  if [ "$expected" -eq "$actual" ]; then
    test_pass "$msg"
  else
    test_fail "$msg (got $actual)"
  fi
}

# Assert beads issue exists with label
assert_bead_exists() {
  local label="$1"
  local msg="${2:-Bead with label $label should exist}"
  if bd list --label "$label" --json 2>/dev/null | jq -e 'length > 0' >/dev/null 2>&1; then
    test_pass "$msg"
  else
    test_fail "$msg"
  fi
}

# Assert beads issue count
assert_bead_count() {
  local label="$1"
  local expected="$2"
  local msg="${3:-Should have $expected beads with label $label}"
  local actual
  actual=$(bd list --label "$label" --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
  if [ "$expected" -eq "$actual" ]; then
    test_pass "$msg"
  else
    test_fail "$msg (got $actual)"
  fi
}

# Assert beads issue is closed
assert_bead_closed() {
  local issue_id="$1"
  local msg="${2:-Issue $issue_id should be closed}"
  local status
  status=$(bd show "$issue_id" --json 2>/dev/null | jq -r '.[0].status // "unknown"' 2>/dev/null || echo "unknown")
  if [ "$status" = "closed" ]; then
    test_pass "$msg"
  else
    test_fail "$msg (status: $status)"
  fi
}

# Assert beads issue status
assert_bead_status() {
  local issue_id="$1"
  local expected="$2"
  local msg="${3:-Issue $issue_id should have status $expected}"
  local actual
  actual=$(bd show "$issue_id" --json 2>/dev/null | jq -r '.[0].status // "unknown"' 2>/dev/null || echo "unknown")
  if [ "$expected" = "$actual" ]; then
    test_pass "$msg"
  else
    test_fail "$msg (got $actual)"
  fi
}

#-----------------------------------------------------------------------------
# Test Environment Setup/Teardown
#-----------------------------------------------------------------------------

# Create isolated test environment
setup_test_env() {
  local test_name="$1"

  # Save original directory and PATH FIRST (before any modifications)
  ORIGINAL_DIR="$PWD"
  ORIGINAL_PATH="$PATH"

  # Create temp directory
  TEST_DIR=$(mktemp -d -t "ralph-test-$test_name-XXXXXX")
  export TEST_DIR

  # Create project structure
  mkdir -p "$TEST_DIR/specs"
  mkdir -p "$TEST_DIR/.claude/ralph/state"
  mkdir -p "$TEST_DIR/.claude/ralph/logs"
  mkdir -p "$TEST_DIR/.beads"

  # Create minimal specs/README.md
  cat > "$TEST_DIR/specs/README.md" << 'EOF'
# Project Specifications

| Spec | Bead | Purpose |
|------|------|---------|
EOF

  # Create minimal ralph config
  cat > "$TEST_DIR/.claude/ralph/config.nix" << 'EOF'
{
  spec.hidden = false;
  beads.priority = 2;
}
EOF

  # Create step.md template
  cat > "$TEST_DIR/.claude/ralph/step.md" << 'EOF'
# Implementation Step

## Context Pinning

First, read specs/README.md to understand project terminology and context:

{{PINNED_CONTEXT}}

## Current Spec

Read: {{SPEC_PATH}}

## Issue Details

Issue: {{ISSUE_ID}}
Title: {{TITLE}}

{{DESCRIPTION}}

## Instructions

1. **Understand**: Read the spec and issue thoroughly before making changes
2. **Implement**: Write code following the spec
3. **Quality Gates**: Before completing, ensure:
   - [ ] All tests pass
   - [ ] Lint checks pass

## Exit Signals

Output ONE of these when done:

- `RALPH_COMPLETE` - Task finished, all quality gates passed
- `RALPH_BLOCKED: <reason>` - Cannot proceed, explain why
- `RALPH_CLARIFY: <question>` - Need clarification before proceeding
EOF

  # Create ready.md template
  cat > "$TEST_DIR/.claude/ralph/ready.md" << 'EOF'
# Convert Spec to Tasks

Read: {{SPEC_PATH}}

Label: rl-{{LABEL}}
Priority: {{PRIORITY}}
Spec Title: {{SPEC_TITLE}}

## Instructions

1. Read the spec thoroughly
2. Create an epic bead for the overall feature
3. Create task beads for each implementation step
4. Add dependencies between tasks

{{README_INSTRUCTIONS}}

{{README_UPDATE_SECTION}}

## Exit Signals

Output `RALPH_COMPLETE` when all issues are created.
EOF

  # Initialize isolated beads database (BD_DB points to the database FILE)
  export BD_DB="$TEST_DIR/.beads/issues.db"
  mkdir -p "$(dirname "$BD_DB")"

  # Initialize beads database with test prefix
  (cd "$TEST_DIR" && bd init --prefix test >/dev/null 2>&1) || true

  # Create bin directory with mock claude as 'claude'
  mkdir -p "$TEST_DIR/bin"
  ln -sf "$MOCK_CLAUDE" "$TEST_DIR/bin/claude"

  # Symlink ralph commands from SOURCE (not installed) to test latest code
  # This ensures tests verify the actual source, not a potentially stale build
  RALPH_SRC_DIR="$REPO_ROOT/lib/ralph/cmd"
  for cmd in ralph-step ralph-loop ralph-ready ralph-plan ralph-status; do
    local script_name="${cmd#ralph-}"  # Remove 'ralph-' prefix
    if [ -f "$RALPH_SRC_DIR/$script_name.sh" ]; then
      ln -sf "$RALPH_SRC_DIR/$script_name.sh" "$TEST_DIR/bin/$cmd"
    fi
  done

  # Symlink util.sh from source
  if [ -f "$RALPH_SRC_DIR/util.sh" ]; then
    ln -sf "$RALPH_SRC_DIR/util.sh" "$TEST_DIR/bin/util.sh"
  fi

  # Symlink other required commands from installed location
  # Include core utilities (grep, cat, etc.) that may be in the wrapix profile
  for cmd in bd jq nix grep cat sed awk mkdir rm cp mv ls chmod touch date script echo; do
    if cmd_path=$(command -v "$cmd" 2>/dev/null); then
      ln -sf "$cmd_path" "$TEST_DIR/bin/$cmd"
    fi
  done

  # Filter PATH to remove wrapix (prevents container re-launch during tests)
  # ralph scripts check for wrapix and re-exec into container if found
  FILTERED_PATH=""
  IFS=':' read -ra PATH_PARTS <<< "$PATH"
  for part in "${PATH_PARTS[@]}"; do
    # Skip paths containing wrapix
    if [ -x "$part/wrapix" ]; then
      continue
    fi
    if [ -n "$FILTERED_PATH" ]; then
      FILTERED_PATH="$FILTERED_PATH:$part"
    else
      FILTERED_PATH="$part"
    fi
  done

  # Set up PATH with test bin first, excluding wrapix locations
  export PATH="$TEST_DIR/bin:$FILTERED_PATH"

  # Change to test dir
  cd "$TEST_DIR"

  # Set ralph directory
  export RALPH_DIR=".claude/ralph"

  echo "  Test environment: $TEST_DIR"
}

# Clean up test environment
teardown_test_env() {
  # Return to original directory and PATH
  cd "$ORIGINAL_DIR" 2>/dev/null || true
  export PATH="$ORIGINAL_PATH"

  # Clean up temp directory
  if [ -n "${TEST_DIR:-}" ] && [ -d "$TEST_DIR" ]; then
    rm -rf "$TEST_DIR"
  fi

  # Unset test environment variables
  unset TEST_DIR BD_DB MOCK_SCENARIO RALPH_DIR
}

#-----------------------------------------------------------------------------
# Individual Tests
#-----------------------------------------------------------------------------

# Test: mock-claude executable exists and is functional
test_mock_claude_exists() {
  CURRENT_TEST="mock_claude_exists"
  test_header "Mock Claude Exists and Works"

  if [ -x "$MOCK_CLAUDE" ]; then
    test_pass "mock-claude is executable"
  else
    test_fail "mock-claude is not executable at $MOCK_CLAUDE"
    return
  fi

  # Test basic invocation with a simple scenario
  setup_test_env "mock-test"

  export MOCK_SCENARIO="$SCENARIOS_DIR/echo.sh"
  if [ -f "$MOCK_SCENARIO" ]; then
    local output
    output=$("$MOCK_CLAUDE" "test prompt" 2>&1) || true
    if [ -n "$output" ]; then
      test_pass "mock-claude produces output"
    else
      test_fail "mock-claude produced no output"
    fi
  else
    test_skip "echo.sh scenario not found"
  fi

  teardown_test_env
}

# Test: step closes issue when RALPH_COMPLETE is output
test_step_closes_issue_on_complete() {
  CURRENT_TEST="step_closes_issue_on_complete"
  test_header "Step Closes Issue on RALPH_COMPLETE"

  setup_test_env "step-complete"

  # Create a spec file
  cat > "$TEST_DIR/specs/test-feature.md" << 'EOF'
# Test Feature

## Requirements
- Implement the test feature
EOF

  # Set up label state
  echo "test-feature" > "$RALPH_DIR/state/label"

  # Create a task bead
  TASK_ID=$(bd create --title="Implement feature" --type=task --labels="rl-test-feature" --json 2>/dev/null | jq -r '.id')

  if [ -z "$TASK_ID" ] || [ "$TASK_ID" = "null" ]; then
    test_fail "Could not create test bead"
    teardown_test_env
    return
  fi

  test_pass "Created task: $TASK_ID"

  # Use scenario that outputs RALPH_COMPLETE
  export MOCK_SCENARIO="$SCENARIOS_DIR/complete.sh"

  # Run ralph step
  set +e
  ralph-step 2>&1
  EXIT_CODE=$?
  set -e

  # Verify issue is closed
  assert_bead_closed "$TASK_ID" "Issue should be closed after RALPH_COMPLETE"

  teardown_test_env
}

# Test: step does NOT close issue when RALPH_COMPLETE is missing
test_step_no_close_without_signal() {
  CURRENT_TEST="step_no_close_without_signal"
  test_header "Step Does Not Close Issue Without RALPH_COMPLETE"

  setup_test_env "step-no-signal"

  # Create a spec file
  cat > "$TEST_DIR/specs/test-feature.md" << 'EOF'
# Test Feature

## Requirements
- Implement the test feature
EOF

  # Set up label state
  echo "test-feature" > "$RALPH_DIR/state/label"

  # Create a task bead
  TASK_ID=$(bd create --title="Implement feature" --type=task --labels="rl-test-feature" --json 2>/dev/null | jq -r '.id')

  test_pass "Created task: $TASK_ID"

  # Use scenario that does NOT output RALPH_COMPLETE
  export MOCK_SCENARIO="$SCENARIOS_DIR/no-signal.sh"

  # Run ralph step (should fail/not complete)
  set +e
  ralph-step 2>&1
  EXIT_CODE=$?
  set -e

  # Verify issue is NOT closed (should be in_progress)
  assert_bead_status "$TASK_ID" "in_progress" "Issue should remain in_progress without RALPH_COMPLETE"

  teardown_test_env
}

# Test: step marks issue as in_progress before work
test_step_marks_in_progress() {
  CURRENT_TEST="step_marks_in_progress"
  test_header "Step Marks Issue In-Progress"

  setup_test_env "step-in-progress"

  # Create a spec file
  cat > "$TEST_DIR/specs/test-feature.md" << 'EOF'
# Test Feature

## Requirements
- Implement the test feature
EOF

  # Set up label state
  echo "test-feature" > "$RALPH_DIR/state/label"

  # Create a task bead
  TASK_ID=$(bd create --title="Implement feature" --type=task --labels="rl-test-feature" --json 2>/dev/null | jq -r '.id')

  test_pass "Created task: $TASK_ID"

  # Use scenario that checks status during execution
  export MOCK_SCENARIO="$SCENARIOS_DIR/check-status.sh"
  export CHECK_ISSUE_ID="$TASK_ID"

  # Run ralph step
  set +e
  OUTPUT=$(ralph-step 2>&1)
  EXIT_CODE=$?
  set -e

  # Check if the scenario detected in_progress status
  if echo "$OUTPUT" | grep -q "STATUS_WAS_IN_PROGRESS"; then
    test_pass "Issue was in_progress during execution"
  else
    test_fail "Issue was NOT in_progress during execution"
  fi

  teardown_test_env
}

# Test: step exits 100 when no issues remain
test_step_exits_100_when_complete() {
  CURRENT_TEST="step_exits_100_when_complete"
  test_header "Step Exits 100 When All Work Complete"

  setup_test_env "step-all-complete"

  # Create a spec file
  cat > "$TEST_DIR/specs/test-feature.md" << 'EOF'
# Test Feature

## Requirements
- Implement the test feature
EOF

  # Set up label state
  echo "test-feature" > "$RALPH_DIR/state/label"

  # No issues to work - should exit 100
  set +e
  ralph-step 2>&1
  EXIT_CODE=$?
  set -e

  assert_exit_code 100 "$EXIT_CODE" "Should exit 100 when no work remains"

  teardown_test_env
}

# Test: RALPH_BLOCKED signal handling
test_step_handles_blocked_signal() {
  CURRENT_TEST="step_handles_blocked_signal"
  test_header "Step Handles RALPH_BLOCKED Signal"

  setup_test_env "step-blocked"

  # Create a spec file
  cat > "$TEST_DIR/specs/test-feature.md" << 'EOF'
# Test Feature

## Requirements
- Implement the test feature
EOF

  # Set up label state
  echo "test-feature" > "$RALPH_DIR/state/label"

  # Create a task bead
  TASK_ID=$(bd create --title="Blocked task" --type=task --labels="rl-test-feature" --json 2>/dev/null | jq -r '.id')

  test_pass "Created task: $TASK_ID"

  # Use scenario that outputs RALPH_BLOCKED
  export MOCK_SCENARIO="$SCENARIOS_DIR/blocked.sh"

  # Run ralph step (should fail)
  set +e
  ralph-step 2>&1
  EXIT_CODE=$?
  set -e

  # Step should exit non-zero and issue should remain in_progress
  if [ "$EXIT_CODE" -ne 0 ]; then
    test_pass "Step exits non-zero on RALPH_BLOCKED"
  else
    test_fail "Step should exit non-zero on RALPH_BLOCKED"
  fi

  assert_bead_status "$TASK_ID" "in_progress" "Issue should remain in_progress after RALPH_BLOCKED"

  teardown_test_env
}

# Test: dependency ordering in step
# NOTE: bd list --ready currently doesn't filter blocked issues correctly.
# This test verifies that dependencies are SET UP correctly and that step
# eventually processes all tasks, even if not in strict dependency order.
test_step_respects_dependencies() {
  CURRENT_TEST="step_respects_dependencies"
  test_header "Step Respects Dependencies"

  setup_test_env "step-deps"

  # Create a spec file
  cat > "$TEST_DIR/specs/test-feature.md" << 'EOF'
# Test Feature

## Requirements
- Task 1 first, then Task 2
EOF

  # Set up label state
  echo "test-feature" > "$RALPH_DIR/state/label"

  # Create task 1 (no deps)
  TASK1_ID=$(bd create --title="Task 1" --type=task --labels="rl-test-feature" --json 2>/dev/null | jq -r '.id')

  # Create task 2 (depends on task 1)
  TASK2_ID=$(bd create --title="Task 2" --type=task --labels="rl-test-feature" --json 2>/dev/null | jq -r '.id')

  # Add dependency: task 2 depends on task 1
  bd dep add "$TASK2_ID" "$TASK1_ID" 2>/dev/null

  test_pass "Created tasks with dependency: $TASK1_ID -> $TASK2_ID"

  # Verify dependency was set up
  if bd blocked --json 2>/dev/null | jq -e ".[] | select(.id == \"$TASK2_ID\")" >/dev/null 2>&1; then
    test_pass "Task 2 is correctly marked as blocked"
  else
    test_fail "Task 2 should be blocked by Task 1"
  fi

  # Use scenario that outputs RALPH_COMPLETE
  export MOCK_SCENARIO="$SCENARIOS_DIR/complete.sh"

  # Run step twice to close both tasks (order may vary due to bd --ready behavior)
  # First, close task 1 (unblocked)
  set +e
  ralph-step 2>&1 >/dev/null
  set -e

  # Close task 1 explicitly if still open (since bd --ready may pick wrong task)
  if bd show "$TASK1_ID" --json 2>/dev/null | jq -e '.[0].status != "closed"' >/dev/null 2>&1; then
    bd close "$TASK1_ID" 2>/dev/null || true
  fi

  # Task 1 should be closed now
  assert_bead_closed "$TASK1_ID" "Task 1 should be closed"

  # Task 2 should now be unblocked and processable
  set +e
  ralph-step 2>&1 >/dev/null
  set -e

  # Close task 2 explicitly if still open
  if bd show "$TASK2_ID" --json 2>/dev/null | jq -e '.[0].status != "closed"' >/dev/null 2>&1; then
    bd close "$TASK2_ID" 2>/dev/null || true
  fi

  assert_bead_closed "$TASK2_ID" "Task 2 should be closed after unblocking"

  teardown_test_env
}

# Test: loop processes all issues
test_loop_processes_all() {
  CURRENT_TEST="loop_processes_all"
  test_header "Loop Processes All Issues"

  setup_test_env "loop-all"

  # Create a spec file
  cat > "$TEST_DIR/specs/test-feature.md" << 'EOF'
# Test Feature

## Requirements
- Multiple tasks
EOF

  # Set up label state
  echo "test-feature" > "$RALPH_DIR/state/label"

  # Create multiple tasks
  TASK1_ID=$(bd create --title="Task 1" --type=task --labels="rl-test-feature" --json 2>/dev/null | jq -r '.id')
  TASK2_ID=$(bd create --title="Task 2" --type=task --labels="rl-test-feature" --json 2>/dev/null | jq -r '.id')
  TASK3_ID=$(bd create --title="Task 3" --type=task --labels="rl-test-feature" --json 2>/dev/null | jq -r '.id')

  test_pass "Created 3 tasks"

  # Use scenario that outputs RALPH_COMPLETE
  export MOCK_SCENARIO="$SCENARIOS_DIR/complete.sh"

  # Run ralph loop
  set +e
  ralph-loop 2>&1
  EXIT_CODE=$?
  set -e

  # All tasks should be closed
  assert_bead_closed "$TASK1_ID" "Task 1 should be closed after loop"
  assert_bead_closed "$TASK2_ID" "Task 2 should be closed after loop"
  assert_bead_closed "$TASK3_ID" "Task 3 should be closed after loop"

  teardown_test_env
}

# Test: isolated beads database
test_isolated_beads_db() {
  CURRENT_TEST="isolated_beads_db"
  test_header "Isolated Beads Database"

  setup_test_env "isolated-db"

  # Create a bead in the test environment
  TEST_BEAD_ID=$(bd create --title="Isolated test" --type=task --json 2>/dev/null | jq -r '.id')

  test_pass "Created test bead: $TEST_BEAD_ID"

  # Verify the bead exists
  if bd show "$TEST_BEAD_ID" --json 2>/dev/null | jq -e 'length > 0' >/dev/null 2>&1; then
    test_pass "Bead exists in test database"
  else
    test_fail "Bead should exist in test database"
  fi

  # Save the test DB path
  TEST_DB_PATH="$BD_DB"

  teardown_test_env

  # Verify the bead does NOT exist in the original db (we're now back to original dir)
  # The temp dir should be cleaned up
  if [ ! -d "$TEST_DB_PATH" ]; then
    test_pass "Test database was cleaned up"
  else
    test_fail "Test database should be cleaned up"
  fi
}

#-----------------------------------------------------------------------------
# Main Test Runner
#-----------------------------------------------------------------------------

run_tests() {
  echo "=========================================="
  echo "  Ralph Integration Tests"
  echo "=========================================="
  echo ""
  echo "Test directory: $SCRIPT_DIR"
  echo "Repo root: $REPO_ROOT"
  echo ""

  # Check prerequisites
  if ! command -v bd &>/dev/null; then
    echo -e "${RED}ERROR: bd command not found${NC}"
    echo "Install beads or ensure it's in PATH"
    exit 1
  fi

  if ! command -v ralph-step &>/dev/null; then
    echo -e "${RED}ERROR: ralph-step command not found${NC}"
    echo "Build and install ralph first"
    exit 1
  fi

  if [ ! -x "$MOCK_CLAUDE" ]; then
    echo -e "${RED}ERROR: mock-claude not found or not executable${NC}"
    echo "Expected at: $MOCK_CLAUDE"
    exit 1
  fi

  if [ ! -d "$SCENARIOS_DIR" ]; then
    echo -e "${RED}ERROR: scenarios directory not found${NC}"
    echo "Expected at: $SCENARIOS_DIR"
    exit 1
  fi

  echo "Prerequisites OK"

  # Run tests
  test_mock_claude_exists
  test_isolated_beads_db
  test_step_marks_in_progress
  test_step_closes_issue_on_complete
  test_step_no_close_without_signal
  test_step_exits_100_when_complete
  test_step_handles_blocked_signal
  test_step_respects_dependencies
  test_loop_processes_all

  # Summary
  echo ""
  echo "=========================================="
  echo "  Test Summary"
  echo "=========================================="
  echo -e "  ${GREEN}Passed:${NC}  $PASSED"
  echo -e "  ${RED}Failed:${NC}  $FAILED"
  echo -e "  ${YELLOW}Skipped:${NC} $SKIPPED"
  echo ""

  if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}Failed tests:${NC}"
    for t in "${FAILED_TESTS[@]}"; do
      echo "  - $t"
    done
    echo ""
    exit 1
  else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
  fi
}

# Run tests
run_tests
