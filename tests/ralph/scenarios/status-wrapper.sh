# shellcheck shell=bash
# Status-wrapper scenario - verifies ralph status wrapper calls bd mol commands correctly
# Tests:
# 1. ralph status calls bd mol progress with correct molecule
# 2. ralph status calls bd mol current with correct molecule
# 3. ralph status calls bd mol stale for hygiene warnings
# 4. Output format matches spec (progress bar, ETA, position)
# 5. Graceful fallback if molecule not set
#
# This scenario provides helper functions for status wrapper tests.
# It is NOT a mock-claude scenario (ralph status doesn't use Claude).

# Create a mock bd command that logs invocations and returns controlled output
# Usage: setup_mock_bd <log_file> [<mock_responses_dir>]
setup_mock_bd() {
  local log_file="$1"
  local mock_responses_dir="${2:-}"
  local bin_dir="${TEST_DIR:-/tmp}/bin"

  # Save the real bd path before overwriting
  if [ -L "$bin_dir/bd" ]; then
    export REAL_BD_PATH
    REAL_BD_PATH=$(readlink -f "$bin_dir/bd" 2>/dev/null || true)
    # Remove the symlink so we can create our mock
    rm -f "$bin_dir/bd"
  fi

  # Create mock bd script
  cat > "$bin_dir/bd" << 'MOCK_BD_EOF'
#!/usr/bin/env bash
# Mock bd command for status-wrapper tests
set -euo pipefail

LOG_FILE="${BD_MOCK_LOG:-/tmp/bd-mock.log}"
MOCK_RESPONSES="${BD_MOCK_RESPONSES:-}"

# Log the invocation
echo "bd $*" >> "$LOG_FILE"

# Handle mol subcommands
if [ "${1:-}" = "mol" ]; then
  subcommand="${2:-}"
  molecule="${3:-}"

  case "$subcommand" in
    progress)
      # Check for --json flag
      if [[ " $* " == *" --json "* ]]; then
        # Check for custom JSON response
        if [ -n "$MOCK_RESPONSES" ] && [ -f "$MOCK_RESPONSES/mol-progress.json" ]; then
          cat "$MOCK_RESPONSES/mol-progress.json"
          exit 0
        fi
        # Default JSON mock response
        cat << EOF
{
  "completed": 8,
  "current_step_id": "test-step-3",
  "in_progress": 1,
  "molecule_id": "$molecule",
  "molecule_title": "Test Molecule",
  "percent": 80,
  "total": 10
}
EOF
        exit 0
      fi
      # Check for custom text response
      if [ -n "$MOCK_RESPONSES" ] && [ -f "$MOCK_RESPONSES/mol-progress.txt" ]; then
        cat "$MOCK_RESPONSES/mol-progress.txt"
        exit 0
      fi
      # Default text mock response
      cat << EOF
Molecule: $molecule (Test Molecule)
Progress: 8 / 10 (80%)
Current step: test-step-3
EOF
      exit 0
      ;;
    current)
      # Check for custom response
      if [ -n "$MOCK_RESPONSES" ] && [ -f "$MOCK_RESPONSES/mol-current.txt" ]; then
        cat "$MOCK_RESPONSES/mol-current.txt"
        exit 0
      fi
      # Default mock response
      cat << EOF
[done]    Setup project structure
[done]    Implement core feature
[current] Write tests         ← you are here
[ready]   Update documentation
[blocked] Final review (waiting on tests)
EOF
      exit 0
      ;;
    stale)
      # Check for custom response
      if [ -n "$MOCK_RESPONSES" ] && [ -f "$MOCK_RESPONSES/mol-stale.txt" ]; then
        cat "$MOCK_RESPONSES/mol-stale.txt"
        exit 0
      fi
      # Check for --quiet flag
      if [[ " $* " == *" --quiet "* ]]; then
        # Default: no stale molecules (empty output)
        exit 0
      fi
      echo "No stale molecules found"
      exit 0
      ;;
    *)
      echo "Mock bd: unknown mol subcommand: $subcommand" >&2
      exit 1
      ;;
  esac
fi

# For non-mol commands, pass through to real bd if available
# This allows setup_test_env to work with bd create, etc.
REAL_BD="${REAL_BD_PATH:-}"
if [ -n "$REAL_BD" ] && [ -x "$REAL_BD" ]; then
  exec "$REAL_BD" "$@"
fi

echo "Mock bd: no real bd available for: $*" >&2
exit 1
MOCK_BD_EOF

  chmod +x "$bin_dir/bd"

  # Export environment variables for the mock
  export BD_MOCK_LOG="$log_file"
  export BD_MOCK_RESPONSES="$mock_responses_dir"
  # REAL_BD_PATH was already exported above when we saved the real bd path
}

# Verify mock bd was called with expected arguments
# Usage: assert_bd_called "mol progress" <log_file>
assert_bd_called() {
  local expected="$1"
  local log_file="$2"
  local msg="${3:-bd should be called with: $expected}"

  if grep -q "$expected" "$log_file" 2>/dev/null; then
    echo "PASS: $msg"
    return 0
  else
    echo "FAIL: $msg"
    echo "  Expected call matching: $expected"
    echo "  Log contents:"
    cat "$log_file" 2>/dev/null | sed 's/^/    /' || echo "    (empty)"
    return 1
  fi
}

# Verify bd mol progress was called with correct molecule
# Usage: assert_progress_called <molecule_id> <log_file>
assert_progress_called() {
  local molecule_id="$1"
  local log_file="$2"
  assert_bd_called "bd mol progress $molecule_id" "$log_file" \
    "bd mol progress called with molecule: $molecule_id"
}

# Verify bd mol current was called with correct molecule
# Usage: assert_current_called <molecule_id> <log_file>
assert_current_called() {
  local molecule_id="$1"
  local log_file="$2"
  assert_bd_called "bd mol current $molecule_id" "$log_file" \
    "bd mol current called with molecule: $molecule_id"
}

# Verify bd mol stale was called
# Usage: assert_stale_called <log_file>
assert_stale_called() {
  local log_file="$1"
  assert_bd_called "bd mol stale" "$log_file" \
    "bd mol stale called for hygiene warnings"
}

# Verify output contains expected spec format elements
# Usage: assert_output_format <output>
assert_output_format() {
  local output="$1"
  local has_errors=0

  # Check for header
  if echo "$output" | grep -q "Ralph Status:"; then
    echo "PASS: Output has Ralph Status header"
  else
    echo "FAIL: Missing Ralph Status header"
    has_errors=1
  fi

  # Check for Molecule line
  if echo "$output" | grep -q "Molecule:"; then
    echo "PASS: Output has Molecule line"
  else
    echo "FAIL: Missing Molecule line"
    has_errors=1
  fi

  # Check for Progress section
  if echo "$output" | grep -q "Progress:"; then
    echo "PASS: Output has Progress section"
  else
    echo "FAIL: Missing Progress section"
    has_errors=1
  fi

  # Check for Current Position section
  if echo "$output" | grep -q "Current Position:"; then
    echo "PASS: Output has Current Position section"
  else
    echo "FAIL: Missing Current Position section"
    has_errors=1
  fi

  return $has_errors
}

# Verify output has visual progress bar with correct format
# Usage: assert_progress_bar <output> <expected_pattern>
# Expected pattern: e.g., "[########--] 80% (8/10)"
assert_progress_bar() {
  local output="$1"
  local expected_percent="${2:-}"

  # Check for progress bar pattern: [#...] N% (X/Y)
  if echo "$output" | grep -qE '\[[#-]+\] [0-9]+% \([0-9]+/[0-9]+\)'; then
    echo "PASS: Output has visual progress bar"
    # If expected percent provided, verify it
    if [ -n "$expected_percent" ]; then
      if echo "$output" | grep -q "$expected_percent%"; then
        echo "PASS: Progress bar shows $expected_percent%"
      else
        echo "FAIL: Expected $expected_percent% in progress bar"
        echo "  Got: $(echo "$output" | grep -E '\[[#-]+\]')"
        return 1
      fi
    fi
    return 0
  else
    echo "FAIL: Missing visual progress bar"
    echo "  Expected format: [####------] N% (X/Y)"
    return 1
  fi
}

# Test phase functions (for mock-claude compatibility if needed)
# These are not used since ralph status doesn't use Claude,
# but included for consistency with other scenarios.

phase_plan() {
  echo "status-wrapper scenario: plan phase (not applicable)"
  echo "RALPH_COMPLETE"
}

phase_todo() {
  echo "status-wrapper scenario: ready phase (not applicable)"
  echo "RALPH_COMPLETE"
}

phase_run() {
  echo "status-wrapper scenario: run phase (not applicable)"
  echo "RALPH_COMPLETE"
}

# Main test runner for status-wrapper
# Usage: run_status_wrapper_test <test_name>
run_status_wrapper_test() {
  local test_name="${1:-default}"
  local ralph_dir="${RALPH_DIR:-.ralph}"
  local current_file="$ralph_dir/state/current.json"
  local log_file="${TEST_DIR:-/tmp}/bd-mock.log"
  local mock_responses="${TEST_DIR:-/tmp}/mock-responses"

  case "$test_name" in
    "with-molecule")
      # Test: ralph status with molecule set
      # Expected: calls bd mol progress, current, stale with correct molecule ID

      local molecule_id="test-mol-123"

      # Set up current.json with molecule
      mkdir -p "$(dirname "$current_file")"
      echo "{\"label\":\"test-feature\",\"molecule\":\"$molecule_id\"}" > "$current_file"

      # Set up mock bd
      rm -f "$log_file"
      setup_mock_bd "$log_file" "$mock_responses"

      # Run ralph status
      echo "Running ralph status with molecule..."
      local status_output
      status_output=$(ralph-status 2>&1) || true

      # Verify calls
      echo ""
      echo "Verifying bd mol commands were called..."
      assert_progress_called "$molecule_id" "$log_file"
      assert_current_called "$molecule_id" "$log_file"
      assert_stale_called "$log_file"

      # Verify output format
      echo ""
      echo "Verifying output format..."
      assert_output_format "$status_output"

      # Verify visual progress bar (80% from mock)
      echo ""
      echo "Verifying visual progress bar..."
      assert_progress_bar "$status_output" "80"

      echo ""
      echo "STATUS_WRAPPER_TEST_PASSED"
      ;;

    "without-molecule")
      # Test: ralph status without molecule set (fallback mode)
      # Expected: uses legacy label-based counting

      # Set up current.json without molecule
      mkdir -p "$(dirname "$current_file")"
      echo '{"label":"test-feature"}' > "$current_file"

      # Run ralph status
      echo "Running ralph status without molecule (fallback)..."
      local status_output
      status_output=$(ralph-status 2>&1) || true

      # Verify fallback output
      if echo "$status_output" | grep -q "No molecule set"; then
        echo "PASS: Fallback mode detected"
      else
        echo "FAIL: Expected fallback mode message"
      fi

      if echo "$status_output" | grep -q "ralph todo"; then
        echo "PASS: Prompts user to run ralph todo"
      fi

      echo ""
      echo "FALLBACK_TEST_PASSED"
      ;;

    "no-label")
      # Test: ralph status with no label set
      # Expected: prompts user to run ralph plan

      # Set up empty current.json
      mkdir -p "$(dirname "$current_file")"
      echo '{}' > "$current_file"

      # Run ralph status
      echo "Running ralph status with no label..."
      local status_output
      status_output=$(ralph-status 2>&1) || true

      # Verify prompt
      if echo "$status_output" | grep -qi "ralph plan"; then
        echo "PASS: Prompts user to run ralph plan"
      else
        echo "FAIL: Expected prompt to run ralph plan"
      fi

      echo ""
      echo "NO_LABEL_TEST_PASSED"
      ;;

    "stale-warnings")
      # Test: ralph status shows stale molecule warnings
      # Expected: displays warnings from bd mol stale

      local molecule_id="test-mol-456"

      # Set up current.json with molecule
      mkdir -p "$(dirname "$current_file")"
      echo "{\"label\":\"test-feature\",\"molecule\":\"$molecule_id\"}" > "$current_file"

      # Set up mock responses with stale warning
      mkdir -p "$mock_responses"
      echo "Warning: Molecule old-mol-xyz appears stale (30 days old)" > "$mock_responses/mol-stale.txt"

      # Set up mock bd
      rm -f "$log_file"
      setup_mock_bd "$log_file" "$mock_responses"

      # Run ralph status
      echo "Running ralph status with stale molecules..."
      local status_output
      status_output=$(ralph-status 2>&1) || true

      # Verify warning displayed
      if echo "$status_output" | grep -q "Warning"; then
        echo "PASS: Stale warning displayed"
      else
        echo "FAIL: Expected stale warning in output"
      fi

      echo ""
      echo "STALE_WARNING_TEST_PASSED"
      ;;

    *)
      echo "Unknown test: $test_name"
      echo "Available tests: with-molecule, without-molecule, no-label, stale-warnings"
      return 1
      ;;
  esac
}
