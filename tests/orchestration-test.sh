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
# test_config_orchestration_keys
#
# Verifies that config.nix contains all orchestration settings with correct
# defaults: loop.parallel, loop.max-retries, loop.max-reviews, model.*,
# watch.poll-interval, watch.max-issues, watch.ignore-patterns.
#-----------------------------------------------------------------------------
test_config_orchestration_keys() {
  echo "--- test_config_orchestration_keys ---"

  local config_nix="$REPO_ROOT/lib/ralph/template/config.nix"

  # Parse config.nix to JSON for reliable value checking
  local config_json
  config_json=$(nix eval --impure --expr "import $config_nix" --json 2>/dev/null) || {
    fail "config.nix failed to parse"
    return 1
  }
  pass "config.nix parses successfully"

  # --- loop settings ---
  local parallel max_retries max_reviews
  parallel=$(echo "$config_json" | jq '.loop.parallel')
  max_retries=$(echo "$config_json" | jq '.loop."max-retries"')
  max_reviews=$(echo "$config_json" | jq '.loop."max-reviews"')

  if [ "$parallel" = "1" ]; then
    pass "loop.parallel defaults to 1 (sequential)"
  else
    fail "loop.parallel is $parallel, expected 1"
    return 1
  fi

  if [ "$max_retries" = "2" ]; then
    pass "loop.max-retries defaults to 2"
  else
    fail "loop.max-retries is $max_retries, expected 2"
    return 1
  fi

  if [ "$max_reviews" = "2" ]; then
    pass "loop.max-reviews defaults to 2"
  else
    fail "loop.max-reviews is $max_reviews, expected 2"
    return 1
  fi

  # --- model settings (all null) ---
  local model_phases=("run" "check" "plan" "todo" "watch")
  for phase in "${model_phases[@]}"; do
    local val
    val=$(echo "$config_json" | jq ".model.\"$phase\"")
    if [ "$val" = "null" ]; then
      pass "model.$phase defaults to null"
    else
      fail "model.$phase is $val, expected null"
      return 1
    fi
  done

  # --- watch settings ---
  local poll_interval max_issues ignore_patterns
  poll_interval=$(echo "$config_json" | jq '.watch."poll-interval"')
  max_issues=$(echo "$config_json" | jq '.watch."max-issues"')
  ignore_patterns=$(echo "$config_json" | jq '.watch."ignore-patterns"')

  if [ "$poll_interval" = "30" ]; then
    pass "watch.poll-interval defaults to 30"
  else
    fail "watch.poll-interval is $poll_interval, expected 30"
    return 1
  fi

  if [ "$max_issues" = "10" ]; then
    pass "watch.max-issues defaults to 10"
  else
    fail "watch.max-issues is $max_issues, expected 10"
    return 1
  fi

  if [ "$ignore_patterns" = "[]" ]; then
    pass "watch.ignore-patterns defaults to []"
  else
    fail "watch.ignore-patterns is $ignore_patterns, expected []"
    return 1
  fi

  # --- backward compatibility: existing keys still present ---
  local max_iterations pause_on_failure
  max_iterations=$(echo "$config_json" | jq '.loop."max-iterations"')
  pause_on_failure=$(echo "$config_json" | jq '.loop."pause-on-failure"')

  if [ "$max_iterations" = "0" ] && [ "$pause_on_failure" = "true" ]; then
    pass "existing loop keys preserved (backward compatible)"
  else
    fail "existing loop keys changed: max-iterations=$max_iterations, pause-on-failure=$pause_on_failure"
    return 1
  fi

  return 0
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
# test_msg_list
#
# Verifies that ralph msg (list mode) queries beads with ralph:clarify label
# and displays a table with ID, spec, source, question columns.
#-----------------------------------------------------------------------------
test_msg_list() {
  echo "--- test_msg_list ---"

  local msg_sh="$REPO_ROOT/lib/ralph/cmd/msg.sh"

  # 1. msg.sh must exist
  if [ ! -f "$msg_sh" ]; then
    fail "msg.sh does not exist"
    return 1
  fi
  pass "msg.sh exists"

  # 2. msg.sh must query beads with ralph:clarify label
  if grep -q 'ralph:clarify' "$msg_sh"; then
    pass "msg.sh queries ralph:clarify label"
  else
    fail "msg.sh does not query ralph:clarify label"
    return 1
  fi

  # 3. msg.sh must display table headers: ID, SPEC, SOURCE, QUESTION
  if grep -q 'ID' "$msg_sh" && grep -q 'SPEC' "$msg_sh" && grep -q 'SOURCE' "$msg_sh" && grep -q 'QUESTION' "$msg_sh"; then
    pass "msg.sh displays table with required columns"
  else
    fail "msg.sh missing table columns (ID, SPEC, SOURCE, QUESTION)"
    return 1
  fi

  # 4. msg.sh must source util.sh for shared helpers
  if grep -q 'source.*util.sh' "$msg_sh"; then
    pass "msg.sh sources util.sh"
  else
    fail "msg.sh does not source util.sh"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_msg_list_by_spec
#
# Verifies that ralph msg -s <label> filters by spec label.
#-----------------------------------------------------------------------------
test_msg_list_by_spec() {
  echo "--- test_msg_list_by_spec ---"

  local msg_sh="$REPO_ROOT/lib/ralph/cmd/msg.sh"

  # 1. msg.sh must accept -s / --spec flag
  if grep -q '\-s|--spec' "$msg_sh"; then
    pass "msg.sh accepts -s/--spec flag"
  else
    fail "msg.sh does not accept -s/--spec flag"
    return 1
  fi

  # 2. msg.sh must use spec filter to add spec-<label> to bd query
  # shellcheck disable=SC2016
  if grep -q 'spec-\$SPEC_FILTER' "$msg_sh" || grep -q 'spec-${SPEC_FILTER}' "$msg_sh"; then
    pass "msg.sh adds spec-<label> filter to bd query"
  else
    fail "msg.sh does not add spec-<label> filter to bd query"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_msg_reply
#
# Verifies that ralph msg -i <id> "answer" stores reply and removes label.
#-----------------------------------------------------------------------------
test_msg_reply() {
  echo "--- test_msg_reply ---"

  local msg_sh="$REPO_ROOT/lib/ralph/cmd/msg.sh"

  # 1. msg.sh must accept -i / --id flag
  if grep -q '\-i|--id' "$msg_sh"; then
    pass "msg.sh accepts -i/--id flag"
  else
    fail "msg.sh does not accept -i/--id flag"
    return 1
  fi

  # 2. msg.sh must store answer via bd update --append-notes
  if grep -q 'append-notes.*Answer' "$msg_sh"; then
    pass "msg.sh stores answer in bead notes"
  else
    fail "msg.sh does not store answer in bead notes"
    return 1
  fi

  # 3. msg.sh must call remove_clarify_label after reply
  if grep -q 'remove_clarify_label' "$msg_sh"; then
    pass "msg.sh removes ralph:clarify label on reply"
  else
    fail "msg.sh does not remove ralph:clarify label on reply"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_msg_dismiss
#
# Verifies that ralph msg -i <id> -d dismisses without answering.
#-----------------------------------------------------------------------------
test_msg_dismiss() {
  echo "--- test_msg_dismiss ---"

  local msg_sh="$REPO_ROOT/lib/ralph/cmd/msg.sh"

  # 1. msg.sh must accept -d / --dismiss flag
  if grep -q '\-d|--dismiss' "$msg_sh"; then
    pass "msg.sh accepts -d/--dismiss flag"
  else
    fail "msg.sh does not accept -d/--dismiss flag"
    return 1
  fi

  # 2. msg.sh must store dismissal note
  if grep -q 'Dismissed' "$msg_sh" && grep -q 'append-notes' "$msg_sh"; then
    pass "msg.sh stores dismissal note in bead"
  else
    fail "msg.sh does not store dismissal note"
    return 1
  fi

  # 3. msg.sh must call remove_clarify_label on dismiss
  if grep -A 10 'DISMISS.*true' "$msg_sh" | grep -q 'remove_clarify_label'; then
    pass "msg.sh removes ralph:clarify label on dismiss"
  else
    fail "msg.sh does not remove ralph:clarify label on dismiss"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_retry_with_context
#
# Verifies that the run.md template includes the PREVIOUS_FAILURE variable
# and that default.nix registers it as a computed variable with empty default.
#-----------------------------------------------------------------------------
test_retry_with_context() {
  echo "--- test_retry_with_context ---"

  local run_md="$REPO_ROOT/lib/ralph/template/run.md"
  local default_nix="$REPO_ROOT/lib/ralph/template/default.nix"

  # 1. run.md must contain {{PREVIOUS_FAILURE}} placeholder
  if grep -q '{{PREVIOUS_FAILURE}}' "$run_md"; then
    pass "run.md contains {{PREVIOUS_FAILURE}} placeholder"
  else
    fail "run.md does not contain {{PREVIOUS_FAILURE}} placeholder"
    return 1
  fi

  # 2. default.nix must define PREVIOUS_FAILURE variable
  if grep -q 'PREVIOUS_FAILURE' "$default_nix"; then
    pass "default.nix defines PREVIOUS_FAILURE variable"
  else
    fail "default.nix does not define PREVIOUS_FAILURE variable"
    return 1
  fi

  # 3. PREVIOUS_FAILURE must have empty string default
  if grep -A 5 'PREVIOUS_FAILURE' "$default_nix" | grep -q 'default = ""'; then
    pass "PREVIOUS_FAILURE has empty string default"
  else
    fail "PREVIOUS_FAILURE does not have empty string default"
    return 1
  fi

  # 4. PREVIOUS_FAILURE must be in the run template's variable list
  if grep -A 15 'run = mkTemplate' "$default_nix" | grep -q '"PREVIOUS_FAILURE"'; then
    pass "PREVIOUS_FAILURE is in run template variable list"
  else
    fail "PREVIOUS_FAILURE is not in run template variable list"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# Main
#-----------------------------------------------------------------------------
echo "=== Orchestration Tests ==="
echo ""

test_config_orchestration_keys
test_clarify_label
test_msg_list
test_msg_list_by_spec
test_msg_reply
test_msg_dismiss
test_retry_with_context

echo ""
echo "=== Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed ==="

[ "$TESTS_FAILED" -eq 0 ]
