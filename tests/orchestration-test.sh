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

  # 7. add_clarify_label must emit notification via notify_event
  if grep -A 20 '^add_clarify_label()' "$util_sh" | grep -q 'notify_event'; then
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
# test_retry_max_limit
#
# Verifies that run.sh implements retry logic with max-retries limit and
# ralph:clarify labeling on permanent failure.
#-----------------------------------------------------------------------------
test_retry_max_limit() {
  echo "--- test_retry_max_limit ---"

  local run_sh="$REPO_ROOT/lib/ralph/cmd/run.sh"
  local util_sh="$REPO_ROOT/lib/ralph/cmd/util.sh"

  # 1. run.sh must read loop.max-retries from config
  if grep -q 'max-retries' "$run_sh"; then
    pass "run.sh reads loop.max-retries from config"
  else
    fail "run.sh does not read loop.max-retries from config"
    return 1
  fi

  # 2. run.sh must have a MAX_RETRIES variable
  if grep -q 'MAX_RETRIES' "$run_sh"; then
    pass "run.sh defines MAX_RETRIES variable"
  else
    fail "run.sh does not define MAX_RETRIES variable"
    return 1
  fi

  # 3. run.sh must track attempt count in run_step
  if grep -q 'attempt' "$run_sh"; then
    pass "run.sh tracks retry attempts"
  else
    fail "run.sh does not track retry attempts"
    return 1
  fi

  # 4. run.sh must call add_clarify_label after max retries exceeded
  if grep -A 5 'Max retries' "$run_sh" | grep -q 'add_clarify_label'; then
    pass "run.sh adds ralph:clarify label after max retries"
  else
    fail "run.sh does not add ralph:clarify label after max retries"
    return 1
  fi

  # 5. util.sh must define extract_error_from_log helper
  if grep -q 'extract_error_from_log' "$util_sh"; then
    pass "util.sh defines extract_error_from_log helper"
  else
    fail "util.sh does not define extract_error_from_log helper"
    return 1
  fi

  # 6. run.sh must pass PREVIOUS_FAILURE to render_template
  if grep -q 'PREVIOUS_FAILURE=' "$run_sh"; then
    pass "run.sh passes PREVIOUS_FAILURE to render_template"
  else
    fail "run.sh does not pass PREVIOUS_FAILURE to render_template"
    return 1
  fi

  # 7. In loop mode, failed steps should continue (not exit)
  if grep -q 'Continuing to next bead' "$run_sh"; then
    pass "run.sh continues to next bead after failure in loop mode"
  else
    fail "run.sh does not continue to next bead after failure"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_check_no_flags_prints_help
#
# Verifies that `ralph check` with no flags prints usage help and exits 0.
#-----------------------------------------------------------------------------
test_check_no_flags_prints_help() {
  echo "--- test_check_no_flags_prints_help ---"

  local check_sh="$REPO_ROOT/lib/ralph/cmd/check.sh"

  # 1. check.sh must exist
  if [ ! -f "$check_sh" ]; then
    fail "check.sh does not exist"
    return 1
  fi
  pass "check.sh exists"

  # 2. check.sh must have a no-flags path that prints usage
  if grep -q 'Usage: ralph check' "$check_sh"; then
    pass "check.sh prints usage help"
  else
    fail "check.sh does not print usage help"
    return 1
  fi

  # 3. No-flags path must exit 0
  if grep -B 5 -A 5 'Usage: ralph check' "$check_sh" | grep -q 'exit 0'; then
    pass "check.sh exits 0 on no flags"
  else
    fail "check.sh does not exit 0 on no flags"
    return 1
  fi

  # 4. Usage must mention both -t and -s modes
  if grep -A 20 'Usage: ralph check' "$check_sh" | grep -q '\-t'; then
    pass "check.sh usage mentions -t flag"
  else
    fail "check.sh usage does not mention -t flag"
    return 1
  fi

  if grep -A 20 'Usage: ralph check' "$check_sh" | grep -q '\-s'; then
    pass "check.sh usage mentions -s flag"
  else
    fail "check.sh usage does not mention -s flag"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_check_templates
#
# Verifies that `ralph check -t` validates templates (existing behavior)
# by checking that check.sh accepts the -t/--templates flag and runs the
# template validation logic.
#-----------------------------------------------------------------------------
test_check_templates() {
  echo "--- test_check_templates ---"

  local check_sh="$REPO_ROOT/lib/ralph/cmd/check.sh"

  # 1. check.sh must accept -t/--templates flag
  if grep -q '\-t|--templates' "$check_sh"; then
    pass "check.sh accepts -t/--templates flag"
  else
    fail "check.sh does not accept -t/--templates flag"
    return 1
  fi

  # 2. check.sh must have template validation function
  if grep -q 'run_template_validation' "$check_sh"; then
    pass "check.sh has run_template_validation function"
  else
    fail "check.sh does not have run_template_validation function"
    return 1
  fi

  # 3. Template validation must check partials
  if grep -q 'Checking partials' "$check_sh"; then
    pass "check.sh validates partials"
  else
    fail "check.sh does not validate partials"
    return 1
  fi

  # 4. Template validation must check Nix expressions
  if grep -q 'Checking Nix expressions' "$check_sh"; then
    pass "check.sh validates Nix expressions"
  else
    fail "check.sh does not validate Nix expressions"
    return 1
  fi

  # 5. Template validation must check body files
  if grep -q 'Checking body files' "$check_sh"; then
    pass "check.sh validates body files"
  else
    fail "check.sh does not validate body files"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_check_spec_runs_in_container
#
# Verifies that `ralph check -s <label>` resolves spec, reads state, computes
# beads summary, renders check.md template, and spawns reviewer in container.
#-----------------------------------------------------------------------------
test_check_spec_runs_in_container() {
  echo "--- test_check_spec_runs_in_container ---"

  local check_sh="$REPO_ROOT/lib/ralph/cmd/check.sh"

  # 1. check.sh must accept -s/--spec flag
  if grep -q '\-s|--spec' "$check_sh"; then
    pass "check.sh accepts -s/--spec flag"
  else
    fail "check.sh does not accept -s/--spec flag"
    return 1
  fi

  # 2. check.sh must have spec review function
  if grep -q 'run_spec_review' "$check_sh"; then
    pass "check.sh has run_spec_review function"
  else
    fail "check.sh does not have run_spec_review function"
    return 1
  fi

  # 3. check.sh must resolve spec label
  if grep -q 'resolve_spec_label' "$check_sh"; then
    pass "check.sh resolves spec label"
  else
    fail "check.sh does not resolve spec label"
    return 1
  fi

  # 4. check.sh must read molecule_id from state
  if grep -q 'molecule_id' "$check_sh"; then
    pass "check.sh reads molecule_id from state"
  else
    fail "check.sh does not read molecule_id from state"
    return 1
  fi

  # 5. check.sh must read base_commit from state
  if grep -q 'base_commit' "$check_sh"; then
    pass "check.sh reads base_commit from state"
  else
    fail "check.sh does not read base_commit from state"
    return 1
  fi

  # 6. check.sh must compute BEADS_SUMMARY
  if grep -q 'beads_summary' "$check_sh"; then
    pass "check.sh computes beads summary"
  else
    fail "check.sh does not compute beads summary"
    return 1
  fi

  # 7. check.sh must render check template
  if grep -q 'render_template check' "$check_sh"; then
    pass "check.sh renders check template"
  else
    fail "check.sh does not render check template"
    return 1
  fi

  # 8. check.sh must use run_claude_stream for review
  if grep -q 'run_claude_stream' "$check_sh"; then
    pass "check.sh uses run_claude_stream for reviewer"
  else
    fail "check.sh does not use run_claude_stream"
    return 1
  fi

  # 9. check.sh must container-detect and launch via wrapix
  if grep -q 'wrapix/claude-config.json' "$check_sh" && grep -q 'wrapix' "$check_sh"; then
    pass "check.sh detects container and re-launches via wrapix"
  else
    fail "check.sh does not have container detection"
    return 1
  fi

  # 10. check.sh must compare bead counts before/after review
  if grep -q 'beads_before' "$check_sh" && grep -q 'beads_after' "$check_sh"; then
    pass "check.sh compares bead counts for pass/fail"
  else
    fail "check.sh does not compare bead counts"
    return 1
  fi

  # 11. check.sh must read model.check from config
  if grep -q 'model.check' "$check_sh"; then
    pass "check.sh reads model.check from config"
  else
    fail "check.sh does not read model.check from config"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_run_check_triggers_review
#
# Verifies that ralph run accepts -c/--check flag and triggers ralph check -s
# after molecule reaches 100%.
#-----------------------------------------------------------------------------
test_run_check_triggers_review() {
  echo "--- test_run_check_triggers_review ---"

  local run_sh="$REPO_ROOT/lib/ralph/cmd/run.sh"

  # 1. run.sh must accept --check/-c flag
  if grep -qE -- '--check|\-c' "$run_sh"; then
    pass "run.sh accepts --check/-c flag"
  else
    fail "run.sh does not accept --check/-c flag"
    return 1
  fi

  # 2. run.sh must have a RUN_CHECK variable
  if grep -q 'RUN_CHECK=' "$run_sh"; then
    pass "run.sh defines RUN_CHECK variable"
  else
    fail "run.sh does not define RUN_CHECK variable"
    return 1
  fi

  # 3. run.sh must call check.sh -s when RUN_CHECK is true
  if grep -q 'check.sh.*-s' "$run_sh"; then
    pass "run.sh calls check.sh -s for review"
  else
    fail "run.sh does not call check.sh -s for review"
    return 1
  fi

  # 4. run.sh must preserve --check flag in container re-exec args
  if grep -q 'RUN_CHECK.*true' "$run_sh" && grep -q -- '--check' "$run_sh"; then
    pass "run.sh preserves --check flag in container re-exec"
  else
    fail "run.sh does not preserve --check flag in container re-exec"
    return 1
  fi

  # 5. run.sh must compare bead counts before/after review
  if grep -q 'beads_before' "$run_sh" && grep -q 'beads_after' "$run_sh"; then
    pass "run.sh compares bead counts for review pass/fail"
  else
    fail "run.sh does not compare bead counts"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_review_cycle_loops
#
# Verifies that the review cycle processes follow-up beads then re-reviews:
#   - After review finds new beads, work loop resumes
#   - After work completes, review re-triggers
#   - On review pass (no new beads), cycle ends
#-----------------------------------------------------------------------------
test_review_cycle_loops() {
  echo "--- test_review_cycle_loops ---"

  local run_sh="$REPO_ROOT/lib/ralph/cmd/run.sh"

  # 1. run.sh must have a review cycle loop
  if grep -q 'review_cycle' "$run_sh"; then
    pass "run.sh implements review cycle tracking"
  else
    fail "run.sh does not implement review cycle tracking"
    return 1
  fi

  # 2. run.sh must resume work loop after review finds issues
  if grep -q 'Resuming work loop' "$run_sh"; then
    pass "run.sh resumes work loop after review finds issues"
  else
    fail "run.sh does not resume work loop after review"
    return 1
  fi

  # 3. run.sh must emit notification on review pass
  if grep -q 'Review passed for' "$run_sh"; then
    pass "run.sh emits review pass notification"
  else
    fail "run.sh does not emit review pass notification"
    return 1
  fi

  # 4. run.sh must call run_step or run_parallel_batch in follow-up loop
  if grep -A 30 'review follow-up' "$run_sh" | grep -q 'run_step\|run_parallel_batch'; then
    pass "run.sh processes follow-up beads in review cycle"
  else
    fail "run.sh does not process follow-up beads in review cycle"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_review_cycle_max_limit
#
# Verifies that the review cycle respects max-reviews from config.
#-----------------------------------------------------------------------------
test_review_cycle_max_limit() {
  echo "--- test_review_cycle_max_limit ---"

  local run_sh="$REPO_ROOT/lib/ralph/cmd/run.sh"

  # 1. run.sh must read loop.max-reviews from config
  if grep -q 'max-reviews' "$run_sh"; then
    pass "run.sh reads loop.max-reviews from config"
  else
    fail "run.sh does not read loop.max-reviews from config"
    return 1
  fi

  # 2. run.sh must have a MAX_REVIEWS variable
  if grep -q 'MAX_REVIEWS' "$run_sh"; then
    pass "run.sh defines MAX_REVIEWS variable"
  else
    fail "run.sh does not define MAX_REVIEWS variable"
    return 1
  fi

  # 3. run.sh must stop after max review cycles
  if grep -q 'Review limit reached' "$run_sh"; then
    pass "run.sh stops at review limit"
  else
    fail "run.sh does not stop at review limit"
    return 1
  fi

  # 4. run.sh must emit notification on review limit
  if grep -A 5 'Review limit reached' "$run_sh" | grep -q 'notify_event'; then
    pass "run.sh emits notification on review limit"
  else
    fail "run.sh does not emit notification on review limit"
    return 1
  fi

  # 5. Review cycle must handle RALPH_CLARIFY from reviewer
  if grep -q 'ralph:clarify' "$run_sh" && grep -q 'Pausing review cycle' "$run_sh"; then
    pass "run.sh handles RALPH_CLARIFY in review cycle"
  else
    fail "run.sh does not handle RALPH_CLARIFY in review cycle"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_msg_dispatcher
#
# Verifies that ralph.sh dispatcher routes the msg command and help text
# includes msg, watch, and updated run flags (-c, -p).
#-----------------------------------------------------------------------------
test_msg_dispatcher() {
  echo "--- test_msg_dispatcher ---"

  local ralph_sh="$REPO_ROOT/lib/ralph/cmd/ralph.sh"

  # 1. ralph.sh must have msg case
  if grep -q 'msg)' "$ralph_sh"; then
    pass "ralph.sh dispatches msg command"
  else
    fail "ralph.sh does not dispatch msg command"
    return 1
  fi

  # 2. ralph.sh must exec ralph-msg
  if grep -q 'ralph-msg' "$ralph_sh"; then
    pass "ralph.sh execs ralph-msg"
  else
    fail "ralph.sh does not exec ralph-msg"
    return 1
  fi

  # 3. ralph.sh help must mention msg
  if grep -A 80 'help|--help' "$ralph_sh" | grep -q 'msg'; then
    pass "ralph.sh help mentions msg"
  else
    fail "ralph.sh help does not mention msg"
    return 1
  fi

  # 4. ralph.sh help must mention -c/--check for run
  if grep -A 80 'help|--help' "$ralph_sh" | grep -q '\-c/--check'; then
    pass "ralph.sh help mentions -c/--check for run"
  else
    fail "ralph.sh help does not mention -c/--check for run"
    return 1
  fi

  # 5. ralph.sh help must mention -p/--parallel for run
  if grep -A 80 'help|--help' "$ralph_sh" | grep -q '\-p/--parallel'; then
    pass "ralph.sh help mentions -p/--parallel for run"
  else
    fail "ralph.sh help does not mention -p/--parallel for run"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_model_override
#
# Verifies that config.nix model overrides are passed to container/claude:
#   - util.sh defines resolve_model helper
#   - run_claude_stream accepts optional model parameter
#   - run.sh reads model.run from config
#   - check.sh reads model.check from config
#   - watch.sh reads model.watch from config
#   - sandbox default.nix supports model parameter
#-----------------------------------------------------------------------------
test_model_override() {
  echo "--- test_model_override ---"

  local util_sh="$REPO_ROOT/lib/ralph/cmd/util.sh"
  local run_sh="$REPO_ROOT/lib/ralph/cmd/run.sh"
  local check_sh="$REPO_ROOT/lib/ralph/cmd/check.sh"
  local watch_sh="$REPO_ROOT/lib/ralph/cmd/watch.sh"
  local sandbox_nix="$REPO_ROOT/lib/sandbox/default.nix"

  # 1. util.sh must define resolve_model helper
  if grep -q '^resolve_model()' "$util_sh"; then
    pass "util.sh defines resolve_model helper"
  else
    fail "util.sh does not define resolve_model helper"
    return 1
  fi

  # 2. resolve_model must read model.<phase> from config JSON
  if grep -A 10 '^resolve_model()' "$util_sh" | grep -q 'model'; then
    pass "resolve_model reads model.<phase> from config"
  else
    fail "resolve_model does not read model.<phase>"
    return 1
  fi

  # 3. run_claude_stream must accept optional model parameter
  if grep -A 5 '^run_claude_stream()' "$util_sh" | grep -q 'model'; then
    pass "run_claude_stream accepts model parameter"
  else
    fail "run_claude_stream does not accept model parameter"
    return 1
  fi

  # 4. run_claude_stream must pass --model to claude CLI when model is set
  if grep -A 25 '^run_claude_stream()' "$util_sh" | grep -q '\-\-model'; then
    pass "run_claude_stream passes --model to claude CLI"
  else
    fail "run_claude_stream does not pass --model to claude CLI"
    return 1
  fi

  # 5. run.sh must read model.run via resolve_model
  if grep -q 'resolve_model.*run' "$run_sh"; then
    pass "run.sh reads model.run via resolve_model"
  else
    fail "run.sh does not read model.run"
    return 1
  fi

  # 6. run.sh must pass model to run_claude_stream
  if grep -q 'run_claude_stream.*MODEL_RUN' "$run_sh"; then
    pass "run.sh passes model to run_claude_stream"
  else
    fail "run.sh does not pass model to run_claude_stream"
    return 1
  fi

  # 7. check.sh must read model.check via resolve_model
  if grep -q 'resolve_model.*check' "$check_sh"; then
    pass "check.sh reads model.check via resolve_model"
  else
    fail "check.sh does not read model.check"
    return 1
  fi

  # 8. check.sh must pass model to run_claude_stream
  if grep -q 'run_claude_stream.*model_check' "$check_sh"; then
    pass "check.sh passes model to run_claude_stream"
  else
    fail "check.sh does not pass model to run_claude_stream"
    return 1
  fi

  # 9. watch.sh must read model.watch via resolve_model
  if grep -q 'resolve_model.*watch' "$watch_sh"; then
    pass "watch.sh reads model.watch via resolve_model"
  else
    fail "watch.sh does not read model.watch"
    return 1
  fi

  # 10. watch.sh must pass model to run_claude_stream
  if grep -q 'run_claude_stream.*MODEL_WATCH' "$watch_sh"; then
    pass "watch.sh passes model to run_claude_stream"
  else
    fail "watch.sh does not pass model to run_claude_stream"
    return 1
  fi

  # 11. sandbox default.nix must accept model parameter in mkSandbox
  if grep -q 'model ? null' "$sandbox_nix"; then
    pass "sandbox default.nix accepts model parameter"
  else
    fail "sandbox default.nix does not accept model parameter"
    return 1
  fi

  # 12. sandbox default.nix must override ANTHROPIC_MODEL when model is set
  if grep -q 'ANTHROPIC_MODEL = model' "$sandbox_nix"; then
    pass "sandbox default.nix overrides ANTHROPIC_MODEL per container"
  else
    fail "sandbox default.nix does not override ANTHROPIC_MODEL"
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------
# test_notifications
#
# Verifies that notifications fire for ralph:clarify, review results, and
# watch detections via the notify_event helper.
#   - util.sh defines notify_event helper
#   - notify_event calls wrapix-notify when available, logs otherwise
#   - add_clarify_label uses notify_event
#   - run.sh uses notify_event for review pass / review limit / review follow-up
#   - check.sh uses notify_event for review pass / review follow-up
#   - watch.sh uses notify_event for max-issues and new issue detection
#-----------------------------------------------------------------------------
test_notifications() {
  echo "--- test_notifications ---"

  local util_sh="$REPO_ROOT/lib/ralph/cmd/util.sh"
  local run_sh="$REPO_ROOT/lib/ralph/cmd/run.sh"
  local check_sh="$REPO_ROOT/lib/ralph/cmd/check.sh"
  local watch_sh="$REPO_ROOT/lib/ralph/cmd/watch.sh"

  # 1. util.sh must define notify_event helper
  if grep -q '^notify_event()' "$util_sh"; then
    pass "util.sh defines notify_event helper"
  else
    fail "util.sh does not define notify_event helper"
    return 1
  fi

  # 2. notify_event must call wrapix-notify when available
  if grep -A 10 '^notify_event()' "$util_sh" | grep -q 'wrapix-notify'; then
    pass "notify_event calls wrapix-notify"
  else
    fail "notify_event does not call wrapix-notify"
    return 1
  fi

  # 3. notify_event must be fire-and-forget (|| true or 2>/dev/null)
  if grep -A 10 '^notify_event()' "$util_sh" | grep -q '|| true'; then
    pass "notify_event is fire-and-forget"
  else
    fail "notify_event is not fire-and-forget"
    return 1
  fi

  # 4. notify_event must fall back to stderr when wrapix-notify unavailable
  if grep -A 10 '^notify_event()' "$util_sh" | grep -q 'debug\|echo.*>&2'; then
    pass "notify_event falls back to stderr logging"
  else
    fail "notify_event does not fall back to stderr"
    return 1
  fi

  # 5. add_clarify_label must use notify_event (not inline wrapix-notify)
  if grep -A 20 '^add_clarify_label()' "$util_sh" | grep -q 'notify_event'; then
    pass "add_clarify_label uses notify_event"
  else
    fail "add_clarify_label does not use notify_event"
    return 1
  fi

  # 6. run.sh must use notify_event for review passed
  if grep -q 'notify_event.*Review passed' "$run_sh"; then
    pass "run.sh uses notify_event for review passed"
  else
    fail "run.sh does not use notify_event for review passed"
    return 1
  fi

  # 7. run.sh must use notify_event for review limit
  if grep -q 'notify_event.*Review limit' "$run_sh"; then
    pass "run.sh uses notify_event for review limit"
  else
    fail "run.sh does not use notify_event for review limit"
    return 1
  fi

  # 8. run.sh must use notify_event for review follow-up beads
  if grep -q 'notify_event.*Review found' "$run_sh"; then
    pass "run.sh uses notify_event for review follow-up"
  else
    fail "run.sh does not use notify_event for review follow-up"
    return 1
  fi

  # 9. check.sh must use notify_event for review passed
  if grep -q 'notify_event.*Review passed' "$check_sh"; then
    pass "check.sh uses notify_event for review passed"
  else
    fail "check.sh does not use notify_event for review passed"
    return 1
  fi

  # 10. check.sh must use notify_event for review found issues
  if grep -q 'notify_event.*Review found' "$check_sh"; then
    pass "check.sh uses notify_event for review found issues"
  else
    fail "check.sh does not use notify_event for review found issues"
    return 1
  fi

  # 11. watch.sh must use notify_event for max-issues
  if grep -q 'notify_event.*max issues' "$watch_sh"; then
    pass "watch.sh uses notify_event for max-issues"
  else
    fail "watch.sh does not use notify_event for max-issues"
    return 1
  fi

  # 12. watch.sh must use notify_event for new issue detection
  if grep -q 'notify_event.*New issue detected' "$watch_sh"; then
    pass "watch.sh uses notify_event for new issue detection"
  else
    fail "watch.sh does not use notify_event for new issue detection"
    return 1
  fi

  # 13. No inline wrapix-notify calls remaining in run.sh (all via notify_event)
  if grep -v 'notify_event\|#\|debug\|warn' "$run_sh" | grep -q 'wrapix-notify'; then
    fail "run.sh still has inline wrapix-notify calls"
    return 1
  else
    pass "run.sh has no inline wrapix-notify calls"
  fi

  # 14. No inline wrapix-notify calls remaining in check.sh
  if grep -v 'notify_event\|#\|debug\|warn' "$check_sh" | grep -q 'wrapix-notify'; then
    fail "check.sh still has inline wrapix-notify calls"
    return 1
  else
    pass "check.sh has no inline wrapix-notify calls"
  fi

  # 15. No inline wrapix-notify calls remaining in watch.sh
  if grep -v 'notify_event\|#\|debug\|warn' "$watch_sh" | grep -q 'wrapix-notify'; then
    fail "watch.sh still has inline wrapix-notify calls"
    return 1
  else
    pass "watch.sh has no inline wrapix-notify calls"
  fi

  return 0
}

#-----------------------------------------------------------------------------
# Main
#-----------------------------------------------------------------------------
echo "=== Orchestration Tests ==="
echo ""

test_check_no_flags_prints_help
test_check_templates
test_check_spec_runs_in_container
test_config_orchestration_keys
test_clarify_label
test_msg_list
test_msg_list_by_spec
test_msg_reply
test_msg_dismiss
test_retry_with_context
test_retry_max_limit
test_parallel_dispatch
test_parallel_worktrees
test_worktree_merge
test_merge_conflict_handling
test_watch_creates_beads
test_watch_deduplication
test_watch_max_issues
test_watch_bead_labels
test_watch_dispatcher
test_msg_dispatcher
test_model_override
test_run_check_triggers_review
test_review_cycle_loops
test_review_cycle_max_limit
test_notifications

echo ""
echo "=== Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed ==="

[ "$TESTS_FAILED" -eq 0 ]
