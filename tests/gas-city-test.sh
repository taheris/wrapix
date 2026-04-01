#!/usr/bin/env bash
# Gas City tests — verifies gas-city spec success criteria
# Run: bash tests/gas-city-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Track test results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
  echo "  PASS: $1"
  TESTS_PASSED=$((TESTS_PASSED + 1))
  TESTS_RUN=$((TESTS_RUN + 1))
}

fail() {
  echo "  FAIL: $1"
  TESTS_FAILED=$((TESTS_FAILED + 1))
  TESTS_RUN=$((TESTS_RUN + 1))
}

skip() {
  echo "  SKIP: $1"
  ((TESTS_RUN++))
}

# --- Tests ---

test_gc_package_available() {
  echo "Test: gc package is exposed in flake outputs"
  if nix eval --json .#packages.x86_64-linux.gc.name 2>/dev/null | grep -q '"gc-'; then
    pass "gc package evaluates for x86_64-linux"
  else
    fail "gc package does not evaluate for x86_64-linux"
  fi
}

test_gc_binary_runs() {
  echo "Test: gc binary executes"
  if nix build .#gc --no-link --print-out-paths 2>/dev/null; then
    local gc_path
    gc_path="$(nix build .#gc --no-link --print-out-paths 2>/dev/null)"
    if "$gc_path/bin/gc" version 2>/dev/null | grep -qE '.+'; then
      pass "gc binary runs and reports version"
    else
      fail "gc binary did not return version"
    fi
  else
    fail "gc package failed to build"
  fi
}

test_gascity_input_pinned() {
  echo "Test: gascity input is pinned in flake.lock"
  if [[ -f "$REPO_ROOT/flake.lock" ]] && grep -q '"gascity"' "$REPO_ROOT/flake.lock"; then
    pass "gascity input exists in flake.lock"
  else
    fail "gascity input not found in flake.lock"
  fi
}

# --- Run ---

echo "=== Gas City Tests ==="
test_gc_package_available
test_gc_binary_runs
test_gascity_input_pinned

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"
if [[ $TESTS_FAILED -gt 0 ]]; then
  exit 1
fi
