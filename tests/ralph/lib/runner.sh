#!/usr/bin/env bash
# Test runner infrastructure for ralph integration tests
# Provides parallel and sequential test execution

#-----------------------------------------------------------------------------
# Color Setup
#-----------------------------------------------------------------------------

# Initialize colors (disabled if not a tty)
setup_colors() {
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
  export RED GREEN YELLOW CYAN NC
}

#-----------------------------------------------------------------------------
# Test State
#-----------------------------------------------------------------------------

# Initialize test counters
init_test_state() {
  PASSED=0
  FAILED=0
  SKIPPED=0
  FAILED_TESTS=()
  export PASSED FAILED SKIPPED FAILED_TESTS
}

#-----------------------------------------------------------------------------
# Isolated Test Execution
#-----------------------------------------------------------------------------

# Run a single test in isolation and write results to file
# Usage: run_test_isolated <test_func> <result_file> <output_file>
run_test_isolated() {
  local test_func="$1"
  local result_file="$2"
  local output_file="$3"

  # Reset counters for this test
  PASSED=0
  FAILED=0
  SKIPPED=0
  FAILED_TESTS=()

  # Run the test, capturing output
  "$test_func" > "$output_file" 2>&1

  # Write results
  echo "passed=$PASSED" > "$result_file"
  echo "failed=$FAILED" >> "$result_file"
  echo "skipped=$SKIPPED" >> "$result_file"
  for t in "${FAILED_TESTS[@]}"; do
    echo "failed_test=$t" >> "$result_file"
  done
}

#-----------------------------------------------------------------------------
# Parallel Test Runner
#-----------------------------------------------------------------------------

# Check if GNU parallel is available
has_parallel() {
  command -v parallel &>/dev/null
}

# Run tests in parallel using background jobs
# Usage: run_tests_parallel <test_array_name>
# Example: run_tests_parallel ALL_TESTS
run_tests_parallel() {
  local -n tests_ref=$1
  local results_dir
  results_dir=$(mktemp -d -t "ralph-test-results-XXXXXX")

  local pids=()
  local test_names=()

  echo "Running ${#tests_ref[@]} tests in parallel..."
  echo ""

  # Launch all tests in background
  for test_func in "${tests_ref[@]}"; do
    local result_file="$results_dir/${test_func}.result"
    local output_file="$results_dir/${test_func}.output"

    # Run test in subshell
    (run_test_isolated "$test_func" "$result_file" "$output_file") &
    pids+=($!)
    test_names+=("$test_func")
  done

  # Wait for all tests to complete
  declare -A exit_codes
  for i in "${!pids[@]}"; do
    local pid="${pids[$i]}"
    local test_func="${test_names[$i]}"

    if wait "$pid"; then
      exit_codes[$test_func]=0
    else
      exit_codes[$test_func]=$?
    fi

    # Show output
    local output_file="$results_dir/${test_func}.output"
    if [ -f "$output_file" ]; then
      cat "$output_file"
    fi
  done

  # Aggregate results
  local total_passed=0
  local total_failed=0
  local total_skipped=0
  local all_failed_tests=()

  for test_func in "${tests_ref[@]}"; do
    local result_file="$results_dir/${test_func}.result"
    local exit_code="${exit_codes[$test_func]:-1}"

    if [ -f "$result_file" ] && [ -s "$result_file" ]; then
      local p f s
      p=$(grep "^passed=" "$result_file" | cut -d= -f2)
      f=$(grep "^failed=" "$result_file" | cut -d= -f2)
      s=$(grep "^skipped=" "$result_file" | cut -d= -f2)
      total_passed=$((total_passed + p))
      total_failed=$((total_failed + f))
      total_skipped=$((total_skipped + s))

      while IFS= read -r line; do
        all_failed_tests+=("${line#failed_test=}")
      done < <(grep "^failed_test=" "$result_file")
    elif [ "$exit_code" -ne 0 ]; then
      # Test subprocess crashed before writing results
      total_failed=$((total_failed + 1))
      all_failed_tests+=("$test_func: CRASHED (exit code $exit_code)")
      echo -e "  ${RED}CRASH${NC}: $test_func (subprocess exited with code $exit_code)"
    fi
  done

  # Clean up
  rm -rf "$results_dir"

  # Summary
  print_test_summary "$total_passed" "$total_failed" "$total_skipped" "${all_failed_tests[@]}"

  [ "$total_failed" -eq 0 ]
}

#-----------------------------------------------------------------------------
# Sequential Test Runner
#-----------------------------------------------------------------------------

# Run tests sequentially with proper isolation
# Each test runs in a subshell to prevent exit calls from killing the main shell
# Usage: run_tests_sequential <test_array_name>
run_tests_sequential() {
  local -n tests_ref=$1
  local results_dir
  results_dir=$(mktemp -d -t "ralph-test-results-XXXXXX")

  local total_passed=0
  local total_failed=0
  local total_skipped=0
  local all_failed_tests=()

  for test_func in "${tests_ref[@]}"; do
    local result_file="$results_dir/${test_func}.result"
    local output_file="$results_dir/${test_func}.output"

    # Run test in subshell to isolate exit calls
    local exit_code=0
    (run_test_isolated "$test_func" "$result_file" "$output_file") || exit_code=$?

    # Show output immediately (sequential mode)
    if [ -f "$output_file" ]; then
      cat "$output_file"
    fi

    # Aggregate results
    if [ -f "$result_file" ] && [ -s "$result_file" ]; then
      local p f s
      p=$(grep "^passed=" "$result_file" | cut -d= -f2)
      f=$(grep "^failed=" "$result_file" | cut -d= -f2)
      s=$(grep "^skipped=" "$result_file" | cut -d= -f2)
      total_passed=$((total_passed + p))
      total_failed=$((total_failed + f))
      total_skipped=$((total_skipped + s))

      while IFS= read -r line; do
        all_failed_tests+=("${line#failed_test=}")
      done < <(grep "^failed_test=" "$result_file" || true)
    elif [ "$exit_code" -ne 0 ]; then
      # Test subprocess crashed before writing results
      total_failed=$((total_failed + 1))
      all_failed_tests+=("$test_func: CRASHED (exit code $exit_code)")
      echo -e "  ${RED:-}CRASH${NC:-}: $test_func (subprocess exited with code $exit_code)"
    fi
  done

  # Clean up
  rm -rf "$results_dir"

  # Summary
  print_test_summary "$total_passed" "$total_failed" "$total_skipped" "${all_failed_tests[@]}"

  [ "$total_failed" -eq 0 ]
}

#-----------------------------------------------------------------------------
# Test Summary
#-----------------------------------------------------------------------------

# Print test summary
# Usage: print_test_summary <passed> <failed> <skipped> [failed_tests...]
print_test_summary() {
  local passed="$1"
  local failed="$2"
  local skipped="$3"
  shift 3
  local failed_tests=("$@")

  echo ""
  echo "=========================================="
  echo "  Test Summary"
  echo "=========================================="
  echo -e "  ${GREEN}Passed:${NC}  $passed"
  echo -e "  ${RED}Failed:${NC}  $failed"
  echo -e "  ${YELLOW}Skipped:${NC} $skipped"
  echo ""

  if [ "$failed" -gt 0 ]; then
    echo -e "${RED}Failed tests:${NC}"
    for t in "${failed_tests[@]}"; do
      echo "  - $t"
    done
    echo ""
  else
    echo -e "${GREEN}All tests passed!${NC}"
  fi
}

#-----------------------------------------------------------------------------
# Prerequisite Checks
#-----------------------------------------------------------------------------

# Check test prerequisites
# Usage: check_prerequisites <mock_claude_path> <scenarios_dir>
check_prerequisites() {
  local mock_claude="$1"
  local scenarios_dir="$2"

  local failed=0

  # Check bd command
  if ! command -v bd &>/dev/null; then
    echo -e "${RED}ERROR: bd command not found${NC}"
    echo "Install beads or ensure it's in PATH"
    failed=1
  fi

  # Check ralph-step command
  if ! command -v ralph-step &>/dev/null; then
    echo -e "${RED}ERROR: ralph-step command not found${NC}"
    echo "Build and install ralph first"
    failed=1
  fi

  # Check mock-claude
  if [ ! -x "$mock_claude" ]; then
    echo -e "${RED}ERROR: mock-claude not found or not executable${NC}"
    echo "Expected at: $mock_claude"
    failed=1
  fi

  # Check scenarios directory
  if [ ! -d "$scenarios_dir" ]; then
    echo -e "${RED}ERROR: scenarios directory not found${NC}"
    echo "Expected at: $scenarios_dir"
    failed=1
  fi

  if [ "$failed" -eq 0 ]; then
    echo "Prerequisites OK"
    return 0
  else
    return 1
  fi
}

#-----------------------------------------------------------------------------
# Main Runner
#-----------------------------------------------------------------------------

# Run all tests with mode selection
# Usage: run_tests <test_array_name> [--sequential]
run_tests() {
  local test_array_name="$1"
  local mode="${2:-parallel}"

  echo "=========================================="
  echo "  Ralph Integration Tests"
  echo "=========================================="
  echo ""
  echo "Test directory: ${SCRIPT_DIR:-$(pwd)}"
  echo "Repo root: ${REPO_ROOT:-unknown}"
  echo ""

  # Check for --sequential flag or RALPH_TEST_SEQUENTIAL env var
  if [ "$mode" = "--sequential" ] || [ "${RALPH_TEST_SEQUENTIAL:-}" = "1" ]; then
    echo "Mode: Sequential"
    echo ""
    run_tests_sequential "$test_array_name"
  else
    echo "Mode: Parallel"
    echo ""
    run_tests_parallel "$test_array_name"
  fi
}
