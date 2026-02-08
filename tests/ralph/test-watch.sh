#!/usr/bin/env bash
# Integration tests for ralph status --watch
# Tests that --watch requires tmux and errors clearly when not in a tmux session
# shellcheck disable=SC2329,SC2086,SC2034,SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
MOCK_CLAUDE="$SCRIPT_DIR/mock-claude"
SCENARIOS_DIR="$SCRIPT_DIR/scenarios"
LIB_DIR="$SCRIPT_DIR/lib"

# Source test libraries
source "$LIB_DIR/assertions.sh"
source "$LIB_DIR/fixtures.sh"
source "$LIB_DIR/runner.sh"

init_test_state
setup_colors

#-----------------------------------------------------------------------------
# Test: ralph status --watch errors when not in tmux
#-----------------------------------------------------------------------------
test_watch_errors_without_tmux() {
  CURRENT_TEST="watch_errors_without_tmux"
  test_header "Status --watch Errors Without tmux"

  setup_test_env "watch-no-tmux"

  # Create minimal state so ralph-status doesn't exit early
  cat > "$TEST_DIR/specs/test-feature.md" << 'EOF'
# Test Feature

## Requirements
- Test requirement
EOF

  cat > "$TEST_DIR/.wrapix/ralph/state/current.json" << 'JSON'
{"label":"test-feature","hidden":false}
JSON

  # Ensure TMUX is NOT set
  unset TMUX 2>/dev/null || true

  local output exit_code
  set +e
  output=$(ralph-status --watch 2>&1)
  exit_code=$?
  set -e

  # Should exit with non-zero
  if [ "$exit_code" -ne 0 ]; then
    test_pass "Exits with non-zero when not in tmux"
  else
    test_fail "Should exit non-zero when not in tmux (got exit 0)"
  fi

  # Should show a clear error message mentioning tmux
  if echo "$output" | grep -qi "tmux"; then
    test_pass "Error message mentions tmux"
  else
    test_fail "Error message should mention tmux: $output"
  fi

  teardown_test_env
}

#-----------------------------------------------------------------------------
# Test: ralph status --watch flag is recognized (doesn't show as unknown)
#-----------------------------------------------------------------------------
test_watch_flag_recognized() {
  CURRENT_TEST="watch_flag_recognized"
  test_header "Status --watch Flag Recognized"

  setup_test_env "watch-flag"

  # Create minimal state
  cat > "$TEST_DIR/specs/test-feature.md" << 'EOF'
# Test Feature

## Requirements
- Test requirement
EOF

  cat > "$TEST_DIR/.wrapix/ralph/state/current.json" << 'JSON'
{"label":"test-feature","hidden":false}
JSON

  # Ensure TMUX is NOT set so we get the tmux error (not "unknown flag")
  unset TMUX 2>/dev/null || true

  local output
  set +e
  output=$(ralph-status --watch 2>&1)
  set -e

  # Should NOT say "unknown" flag/option/command
  if echo "$output" | grep -qi "unknown\|unrecognized\|invalid option"; then
    test_fail "--watch should not be treated as unknown flag"
  else
    test_pass "--watch is recognized (not treated as unknown)"
  fi

  teardown_test_env
}

#-----------------------------------------------------------------------------
# Test: ralph status -w short flag also works
#-----------------------------------------------------------------------------
test_watch_short_flag() {
  CURRENT_TEST="watch_short_flag"
  test_header "Status -w Short Flag"

  setup_test_env "watch-short"

  # Create minimal state
  cat > "$TEST_DIR/specs/test-feature.md" << 'EOF'
# Test Feature

## Requirements
- Test requirement
EOF

  cat > "$TEST_DIR/.wrapix/ralph/state/current.json" << 'JSON'
{"label":"test-feature","hidden":false}
JSON

  # Ensure TMUX is NOT set
  unset TMUX 2>/dev/null || true

  local output exit_code
  set +e
  output=$(ralph-status -w 2>&1)
  exit_code=$?
  set -e

  # -w should behave the same as --watch
  if [ "$exit_code" -ne 0 ]; then
    test_pass "-w exits non-zero when not in tmux"
  else
    test_fail "-w should exit non-zero when not in tmux"
  fi

  if echo "$output" | grep -qi "tmux"; then
    test_pass "-w error message mentions tmux"
  else
    test_fail "-w error message should mention tmux: $output"
  fi

  teardown_test_env
}

#-----------------------------------------------------------------------------
# Test: ralph status without --watch works normally (no tmux requirement)
#-----------------------------------------------------------------------------
test_status_without_watch_works() {
  CURRENT_TEST="status_without_watch_works"
  test_header "Status Without --watch Works Normally"

  setup_test_env "status-normal"

  # Create minimal state
  cat > "$TEST_DIR/specs/test-feature.md" << 'EOF'
# Test Feature

## Requirements
- Test requirement
EOF

  cat > "$TEST_DIR/.wrapix/ralph/state/current.json" << 'JSON'
{"label":"test-feature","hidden":false}
JSON

  # Ensure TMUX is NOT set (should still work without --watch)
  unset TMUX 2>/dev/null || true

  local exit_code
  set +e
  ralph-status >/dev/null 2>&1
  exit_code=$?
  set -e

  # ralph status (no --watch) should work fine outside tmux
  if [ "$exit_code" -eq 0 ]; then
    test_pass "ralph status works without tmux when --watch not used"
  else
    test_fail "ralph status should work without tmux (got exit $exit_code)"
  fi

  teardown_test_env
}

#-----------------------------------------------------------------------------
# Main Test Runner
#-----------------------------------------------------------------------------

ALL_TESTS=(
  test_watch_errors_without_tmux
  test_watch_flag_recognized
  test_watch_short_flag
  test_status_without_watch_works
)

main() {
  echo "=========================================="
  echo "  Ralph Status --watch Tests"
  echo "=========================================="
  echo ""
  echo "Test directory: $SCRIPT_DIR"
  echo "Repo root: $REPO_ROOT"
  echo ""

  # Check prerequisites
  check_prerequisites "$MOCK_CLAUDE" "$SCENARIOS_DIR" || exit 1

  run_tests ALL_TESTS "${1:-}"
}

main "$@"
