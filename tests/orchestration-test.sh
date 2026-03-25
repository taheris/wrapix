#!/usr/bin/env bash
# Orchestration tests — verifies orchestration spec success criteria
# Run: bash tests/orchestration-test.sh
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

#-----------------------------------------------------------------------------
# test_clarify_label
#
# Verifies that ralph:clarify label replaces awaiting:input in the run loop:
#   - run.sh filters out beads with ralph:clarify (not awaiting:input)
#   - RALPH_CLARIFY handler adds ralph:clarify label
#   - User instructions reference ralph msg (not manual bd update)
#   - util.sh has add_clarify_label and remove_clarify_label helpers
#-----------------------------------------------------------------------------
test_clarify_label() {
  echo "--- test_clarify_label ---"

  local run_sh="$REPO_ROOT/lib/ralph/cmd/run.sh"
  local util_sh="$REPO_ROOT/lib/ralph/cmd/util.sh"

  # 1. run.sh must NOT reference awaiting:input anywhere
  if grep -q 'awaiting:input' "$run_sh"; then
    fail "run.sh still references awaiting:input"
    return 1
  else
    pass "run.sh does not reference awaiting:input"
  fi

  # 2. run.sh must filter on ralph:clarify in the jq work-item filter
  if grep -q 'ralph:clarify' "$run_sh"; then
    pass "run.sh filters on ralph:clarify label"
  else
    fail "run.sh does not filter on ralph:clarify label"
    return 1
  fi

  # 3. RALPH_CLARIFY handler must call add_clarify_label (not raw bd update)
  if grep -q 'add_clarify_label' "$run_sh"; then
    pass "run.sh uses add_clarify_label helper"
  else
    fail "run.sh does not use add_clarify_label helper"
    return 1
  fi

  # 4. User instructions must reference ralph msg
  if grep -q 'ralph msg' "$run_sh"; then
    pass "run.sh user instructions reference ralph msg"
  else
    fail "run.sh user instructions do not reference ralph msg"
    return 1
  fi

  # 5. util.sh must define add_clarify_label function
  if grep -q '^add_clarify_label()' "$util_sh"; then
    pass "util.sh defines add_clarify_label"
  else
    fail "util.sh does not define add_clarify_label"
    return 1
  fi

  # 6. util.sh must define remove_clarify_label function
  if grep -q '^remove_clarify_label()' "$util_sh"; then
    pass "util.sh defines remove_clarify_label"
  else
    fail "util.sh does not define remove_clarify_label"
    return 1
  fi

  # 7. add_clarify_label must emit notification via wrapix-notify
  if grep -A 20 '^add_clarify_label()' "$util_sh" | grep -q 'wrapix-notify'; then
    pass "add_clarify_label emits notification"
  else
    fail "add_clarify_label does not emit notification"
    return 1
  fi

  # 8. util.sh must NOT reference awaiting:input
  if grep -q 'awaiting:input' "$util_sh"; then
    fail "util.sh still references awaiting:input"
    return 1
  else
    pass "util.sh does not reference awaiting:input"
  fi

  return 0
}

#-----------------------------------------------------------------------------
# Main
#-----------------------------------------------------------------------------
echo "=== Orchestration Tests ==="
echo ""

test_clarify_label

echo ""
echo "=== Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed ==="

[ "$TESTS_FAILED" -eq 0 ]
