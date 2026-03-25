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
# test_parallel_dispatch
#
# Verifies that ralph run accepts -p N / --parallel N flag and reads
# loop.parallel from config as fallback.
#-----------------------------------------------------------------------------
test_parallel_dispatch() {
  echo "--- test_parallel_dispatch ---"

  local run_sh="$REPO_ROOT/lib/ralph/cmd/run.sh"

  # 1. run.sh must accept --parallel/-p flag
  if grep -qE -- '--parallel|\-p' "$run_sh"; then
    pass "run.sh accepts --parallel/-p flag"
  else
    fail "run.sh does not accept --parallel/-p flag"
    return 1
  fi

  # 2. run.sh must read loop.parallel from config as fallback
  if grep -q 'loop.parallel' "$run_sh"; then
    pass "run.sh reads loop.parallel from config"
  else
    fail "run.sh does not read loop.parallel from config"
    return 1
  fi

  # 3. run.sh must have a PARALLEL variable
  if grep -q 'PARALLEL=' "$run_sh"; then
    pass "run.sh defines PARALLEL variable"
  else
    fail "run.sh does not define PARALLEL variable"
    return 1
  fi

  # 4. run.sh must validate parallel is a positive integer
  if grep -q 'Invalid parallel value' "$run_sh"; then
    pass "run.sh validates parallel value"
  else
    fail "run.sh does not validate parallel value"
    return 1
  fi

  # 5. run.sh must use run_parallel_batch when parallel > 1
  if grep -q 'run_parallel_batch' "$run_sh"; then
    pass "run.sh uses run_parallel_batch for parallel dispatch"
  else
    fail "run.sh does not use run_parallel_batch"
    return 1
  fi

  # 6. run.sh must preserve --parallel flag in container re-exec args
  if grep -q 'PARALLEL_FLAG' "$run_sh" && grep -q -- '--parallel.*PARALLEL_FLAG' "$run_sh"; then
    pass "run.sh preserves --parallel flag in container re-exec"
  else
    fail "run.sh does not preserve --parallel flag in container re-exec"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_parallel_worktrees
#
# Verifies that util.sh defines worktree helper functions for parallel
# dispatch: create_worktree, merge_worktree, cleanup_worktree.
#-----------------------------------------------------------------------------
test_parallel_worktrees() {
  echo "--- test_parallel_worktrees ---"

  local util_sh="$REPO_ROOT/lib/ralph/cmd/util.sh"

  # 1. util.sh must define create_worktree
  if grep -q '^create_worktree()' "$util_sh"; then
    pass "util.sh defines create_worktree"
  else
    fail "util.sh does not define create_worktree"
    return 1
  fi

  # 2. create_worktree must use ralph/<label>/<bead-id> branch naming
  # shellcheck disable=SC2016
  if grep -A 10 '^create_worktree()' "$util_sh" | grep -q 'ralph/${label}/${bead_id}'; then
    pass "create_worktree uses ralph/<label>/<bead-id> branch naming"
  else
    fail "create_worktree does not use correct branch naming"
    return 1
  fi

  # 3. create_worktree must use git worktree add
  if grep -A 15 '^create_worktree()' "$util_sh" | grep -q 'git worktree add'; then
    pass "create_worktree uses git worktree add"
  else
    fail "create_worktree does not use git worktree add"
    return 1
  fi

  # 4. util.sh must define cleanup_worktree
  if grep -q '^cleanup_worktree()' "$util_sh"; then
    pass "util.sh defines cleanup_worktree"
  else
    fail "util.sh does not define cleanup_worktree"
    return 1
  fi

  # 5. cleanup_worktree must force-remove
  if grep -A 10 '^cleanup_worktree()' "$util_sh" | grep -q 'worktree remove --force'; then
    pass "cleanup_worktree force-removes worktree"
  else
    fail "cleanup_worktree does not force-remove"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_worktree_merge
#
# Verifies that merge_worktree merges the worktree branch back and cleans up.
#-----------------------------------------------------------------------------
test_worktree_merge() {
  echo "--- test_worktree_merge ---"

  local util_sh="$REPO_ROOT/lib/ralph/cmd/util.sh"

  # 1. util.sh must define merge_worktree
  if grep -q '^merge_worktree()' "$util_sh"; then
    pass "util.sh defines merge_worktree"
  else
    fail "util.sh does not define merge_worktree"
    return 1
  fi

  # 2. merge_worktree must call git merge
  if grep -A 20 '^merge_worktree()' "$util_sh" | grep -q 'git merge'; then
    pass "merge_worktree calls git merge"
  else
    fail "merge_worktree does not call git merge"
    return 1
  fi

  # 3. merge_worktree must clean up worktree on success
  if grep -A 30 '^merge_worktree()' "$util_sh" | grep -q 'worktree remove'; then
    pass "merge_worktree cleans up worktree on success"
  else
    fail "merge_worktree does not clean up worktree on success"
    return 1
  fi

  # 4. merge_worktree must delete branch on success
  if grep -A 30 '^merge_worktree()' "$util_sh" | grep -q 'git branch -d'; then
    pass "merge_worktree deletes branch on success"
  else
    fail "merge_worktree does not delete branch on success"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_merge_conflict_handling
#
# Verifies that merge conflicts reopen the bead with conflict details and
# add the ralph:clarify label.
#-----------------------------------------------------------------------------
test_merge_conflict_handling() {
  echo "--- test_merge_conflict_handling ---"

  local util_sh="$REPO_ROOT/lib/ralph/cmd/util.sh"

  # 1. merge_worktree must abort merge on conflict
  if grep -A 40 '^merge_worktree()' "$util_sh" | grep -q 'merge --abort'; then
    pass "merge_worktree aborts merge on conflict"
  else
    fail "merge_worktree does not abort merge on conflict"
    return 1
  fi

  # 2. merge_worktree must reopen the bead (status=open)
  if grep -A 40 '^merge_worktree()' "$util_sh" | grep -q 'status=open'; then
    pass "merge_worktree reopens bead on conflict"
  else
    fail "merge_worktree does not reopen bead on conflict"
    return 1
  fi

  # 3. merge_worktree must add ralph:clarify label on conflict
  if grep -A 40 '^merge_worktree()' "$util_sh" | grep -q 'ralph:clarify'; then
    pass "merge_worktree adds ralph:clarify on conflict"
  else
    fail "merge_worktree does not add ralph:clarify on conflict"
    return 1
  fi

  # 4. merge_worktree must add conflict details to notes
  if grep -A 40 '^merge_worktree()' "$util_sh" | grep -q 'Merge conflict'; then
    pass "merge_worktree adds conflict details to notes"
  else
    fail "merge_worktree does not add conflict details to notes"
    return 1
  fi

  # 5. merge_worktree must clean up worktree even on conflict
  if grep -A 45 '^merge_worktree()' "$util_sh" | grep -q 'cleanup_worktree'; then
    pass "merge_worktree cleans up worktree on conflict"
  else
    fail "merge_worktree does not clean up worktree on conflict"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_watch_creates_beads
#
# Verifies that watch.sh exists, accepts -s flag, spawns poll loop, renders
# watch template, and uses run_claude_stream for each cycle.
#-----------------------------------------------------------------------------
test_watch_creates_beads() {
  echo "--- test_watch_creates_beads ---"

  local watch_sh="$REPO_ROOT/lib/ralph/cmd/watch.sh"

  # 1. watch.sh must exist
  if [ ! -f "$watch_sh" ]; then
    fail "watch.sh does not exist"
    return 1
  fi
  pass "watch.sh exists"

  # 2. watch.sh must accept -s/--spec flag
  if grep -q '\-s|--spec' "$watch_sh" || grep -qE -- '--spec\|-s' "$watch_sh"; then
    pass "watch.sh accepts -s/--spec flag"
  else
    fail "watch.sh does not accept -s/--spec flag"
    return 1
  fi

  # 3. watch.sh must render watch template
  if grep -q 'render_template watch' "$watch_sh"; then
    pass "watch.sh renders watch template"
  else
    fail "watch.sh does not render watch template"
    return 1
  fi

  # 4. watch.sh must use run_claude_stream
  if grep -q 'run_claude_stream' "$watch_sh"; then
    pass "watch.sh uses run_claude_stream for claude sessions"
  else
    fail "watch.sh does not use run_claude_stream"
    return 1
  fi

  # 5. watch.sh must source util.sh
  if grep -q 'source.*util.sh' "$watch_sh"; then
    pass "watch.sh sources util.sh"
  else
    fail "watch.sh does not source util.sh"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_watch_deduplication
#
# Verifies that the watch template instructs the agent to deduplicate against
# existing beads and known issues in watch state.
#-----------------------------------------------------------------------------
test_watch_deduplication() {
  echo "--- test_watch_deduplication ---"

  local watch_md="$REPO_ROOT/lib/ralph/template/watch.md"

  # 1. watch.md must instruct deduplication
  if grep -qi 'deduplic' "$watch_md"; then
    pass "watch.md instructs deduplication"
  else
    fail "watch.md does not instruct deduplication"
    return 1
  fi

  # 2. watch.md must reference bd list for checking existing beads
  if grep -q 'bd list' "$watch_md"; then
    pass "watch.md references bd list for existing beads check"
  else
    fail "watch.md does not reference bd list for existing beads"
    return 1
  fi

  # 3. watch.md must reference watch state for known issues
  if grep -q 'watch.md' "$watch_md" || grep -q 'watch state' "$watch_md"; then
    pass "watch.md references watch state for known issues"
  else
    fail "watch.md does not reference watch state"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_watch_max_issues
#
# Verifies that watch.sh reads max-issues from config and checks bead count
# before spawning new sessions.
#-----------------------------------------------------------------------------
test_watch_max_issues() {
  echo "--- test_watch_max_issues ---"

  local watch_sh="$REPO_ROOT/lib/ralph/cmd/watch.sh"

  # 1. watch.sh must read max-issues from config
  if grep -q 'max-issues' "$watch_sh"; then
    pass "watch.sh reads max-issues from config"
  else
    fail "watch.sh does not read max-issues from config"
    return 1
  fi

  # 2. watch.sh must check bead count against max
  if grep -q 'MAX_ISSUES' "$watch_sh"; then
    pass "watch.sh checks bead count against MAX_ISSUES"
  else
    fail "watch.sh does not check MAX_ISSUES limit"
    return 1
  fi

  # 3. watch.sh must count source:watch beads
  if grep -q 'source:watch' "$watch_sh"; then
    pass "watch.sh counts source:watch beads"
  else
    fail "watch.sh does not count source:watch beads"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_watch_bead_labels
#
# Verifies that watch-created beads use the source:watch label in the template.
#-----------------------------------------------------------------------------
test_watch_bead_labels() {
  echo "--- test_watch_bead_labels ---"

  local watch_md="$REPO_ROOT/lib/ralph/template/watch.md"

  # 1. watch.md must instruct agent to label beads with source:watch
  if grep -q 'source:watch' "$watch_md"; then
    pass "watch.md includes source:watch label in bead creation"
  else
    fail "watch.md does not include source:watch label"
    return 1
  fi

  # 2. watch.md must instruct agent to label with spec-<label>
  if grep -q 'spec-{{LABEL}}' "$watch_md"; then
    pass "watch.md includes spec-<label> in bead creation"
  else
    fail "watch.md does not include spec-<label> label"
    return 1
  fi

  # 3. watch.md must instruct agent to bond to molecule
  if grep -q 'bd mol bond' "$watch_md"; then
    pass "watch.md instructs bonding to molecule"
  else
    fail "watch.md does not instruct molecule bonding"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_watch_dispatcher
#
# Verifies that ralph.sh dispatcher routes the watch command.
#-----------------------------------------------------------------------------
test_watch_dispatcher() {
  echo "--- test_watch_dispatcher ---"

  local ralph_sh="$REPO_ROOT/lib/ralph/cmd/ralph.sh"

  # 1. ralph.sh must have watch case
  if grep -q 'watch)' "$ralph_sh"; then
    pass "ralph.sh dispatches watch command"
  else
    fail "ralph.sh does not dispatch watch command"
    return 1
  fi

  # 2. ralph.sh must exec ralph-watch
  if grep -q 'ralph-watch' "$ralph_sh"; then
    pass "ralph.sh execs ralph-watch"
  else
    fail "ralph.sh does not exec ralph-watch"
    return 1
  fi

  # 3. ralph.sh help must mention watch
  if grep -q 'watch' "$ralph_sh"; then
    pass "ralph.sh help mentions watch"
  else
    fail "ralph.sh help does not mention watch"
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
test_parallel_dispatch
test_parallel_worktrees
test_worktree_merge
test_merge_conflict_handling
test_watch_creates_beads
test_watch_deduplication
test_watch_max_issues
test_watch_bead_labels
test_watch_dispatcher

echo ""
echo "=== Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed ==="

[ "$TESTS_FAILED" -eq 0 ]
