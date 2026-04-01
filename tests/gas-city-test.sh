#!/usr/bin/env bash
# Gas City functional tests — executes scripts with mocked dependencies.
#
# Tests actually run provider.sh, scout.sh, gate.sh, post-gate.sh, agent.sh,
# entrypoint.sh, recovery.sh, and sync.sh scaffolding against mock tools,
# verifying real outputs and side effects — not just grep for keywords.
#
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

# ============================================================================
# Mock infrastructure
# ============================================================================

# Create a temp directory for the entire test suite
SUITE_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$SUITE_TMPDIR"' EXIT

# Create mock bin directory — prepended to PATH so scripts call mocks
MOCK_BIN="$SUITE_TMPDIR/mock-bin"
mkdir -p "$MOCK_BIN"

# Create a call log for a mock command. Each invocation appends args.
# Usage: create_mock <name> [exit_code] [stdout]
create_mock() {
  local name="$1"
  local exit_code="${2:-0}"
  local stdout="${3:-}"
  local log="$SUITE_TMPDIR/calls/${name}.log"

  mkdir -p "$SUITE_TMPDIR/calls"
  : > "$log"

  cat > "$MOCK_BIN/$name" << MOCK
#!/usr/bin/env bash
echo "\$@" >> "$log"
if [[ -n "$stdout" ]]; then
  echo "$stdout"
fi
exit $exit_code
MOCK
  chmod +x "$MOCK_BIN/$name"
}

# Create a mock that dispatches on first arg (subcommand).
# Usage: create_dispatch_mock <name> <subcommand> <exit_code> <stdout>
# Call multiple times for different subcommands.
create_dispatch_mock() {
  local name="$1"
  local subcmd="$2"
  local exit_code="$3"
  local stdout="${4:-}"
  local script="$MOCK_BIN/$name"
  local log="$SUITE_TMPDIR/calls/${name}.log"

  mkdir -p "$SUITE_TMPDIR/calls"
  [[ -f "$log" ]] || : > "$log"

  # If the mock doesn't exist yet, create the skeleton
  if [[ ! -f "$script" ]]; then
    cat > "$script" << 'SKEL'
#!/usr/bin/env bash
SKEL
    chmod +x "$script"
  fi

  # Append a case for this subcommand (before the fallback)
  # We build the dispatch incrementally by using a dispatch dir
  local dispatch_dir="$SUITE_TMPDIR/dispatch/${name}"
  mkdir -p "$dispatch_dir"

  cat > "$dispatch_dir/${subcmd}.sh" << HANDLER
echo "\$@" >> "$log"
echo "$stdout"
exit $exit_code
HANDLER

  # Rebuild the dispatch script
  cat > "$script" << 'HEAD'
#!/usr/bin/env bash
HEAD

  echo "LOG=\"$log\"" >> "$script"
  echo 'CMD="$1"; shift 2>/dev/null || true' >> "$script"
  echo 'ALLARGS="$CMD $*"' >> "$script"

  # Add cases
  echo 'case "$CMD" in' >> "$script"
  for handler in "$dispatch_dir"/*.sh; do
    [[ -f "$handler" ]] || continue
    local sub
    sub="$(basename "$handler" .sh)"
    echo "  ${sub})" >> "$script"
    cat "$handler" >> "$script"
    echo "    ;;" >> "$script"
  done
  echo '  *)' >> "$script"
  echo '    echo "$ALLARGS" >> "$LOG"' >> "$script"
  echo '    ;;' >> "$script"
  echo 'esac' >> "$script"

  chmod +x "$script"
}

# Get calls logged by a mock.
# Usage: get_calls <name>
get_calls() {
  local log="$SUITE_TMPDIR/calls/${1}.log"
  [[ -f "$log" ]] && cat "$log" || true
}

# Assert a mock was called with args matching a pattern.
# Usage: assert_called <name> <grep-pattern>
assert_called() {
  local name="$1" pattern="$2"
  if get_calls "$name" | grep -qE "$pattern"; then
    return 0
  fi
  echo "    expected $name to be called with pattern: $pattern" >&2
  echo "    actual calls:" >&2
  get_calls "$name" | sed 's/^/      /' >&2
  return 1
}

# Assert a mock was NOT called with args matching a pattern.
assert_not_called() {
  local name="$1" pattern="$2"
  if ! get_calls "$name" | grep -qE "$pattern"; then
    return 0
  fi
  return 1
}

# Reset all mock call logs
reset_mocks() {
  rm -rf "$SUITE_TMPDIR/calls"
  mkdir -p "$SUITE_TMPDIR/calls"
}

# ============================================================================
# Test: scout.sh parse-rules
# ============================================================================

test_scout_parse_rules_defaults() {
  echo "Test: scout.sh parse-rules uses defaults when no doc file exists"
  local tmpdir
  tmpdir="$(mktemp -d "$SUITE_TMPDIR/scout-XXXX")"

  SCOUT_ERRORS_DIR="$tmpdir/errors" "$REPO_ROOT/lib/city/scout.sh" parse-rules ""

  local immediate batched ignore
  immediate="$(cat "$tmpdir/errors/immediate.pat")"
  batched="$(cat "$tmpdir/errors/batched.pat")"
  ignore="$(cat "$tmpdir/errors/ignore.pat")"

  if [[ "$immediate" == "FATAL|PANIC|panic:" ]] &&
     [[ "$batched" == "ERROR|Exception" ]] &&
     [[ -z "$ignore" ]]; then
    pass "defaults applied when no doc file"
  else
    fail "wrong defaults: immediate='$immediate' batched='$batched' ignore='$ignore'"
  fi
}

test_scout_parse_rules_custom() {
  echo "Test: scout.sh parse-rules reads custom patterns from orchestration.md"
  local tmpdir
  tmpdir="$(mktemp -d "$SUITE_TMPDIR/scout-XXXX")"

  cat > "$tmpdir/orch.md" << 'DOC'
# Orchestration

## Scout Rules

### Immediate (P0 bead)

```
OOM_KILLED|SEGFAULT
```

### Batched (collected over one poll cycle)

```
WARN|TIMEOUT
```

### Ignore

```
healthcheck
```

## Auto-deploy
DOC

  SCOUT_ERRORS_DIR="$tmpdir/errors" "$REPO_ROOT/lib/city/scout.sh" parse-rules "$tmpdir/orch.md"

  local immediate batched ignore
  immediate="$(cat "$tmpdir/errors/immediate.pat")"
  batched="$(cat "$tmpdir/errors/batched.pat")"
  ignore="$(cat "$tmpdir/errors/ignore.pat")"

  if [[ "$immediate" == "OOM_KILLED|SEGFAULT" ]] &&
     [[ "$batched" == "WARN|TIMEOUT" ]] &&
     [[ "$ignore" == "healthcheck" ]]; then
    pass "custom patterns parsed from orchestration.md"
  else
    fail "wrong patterns: immediate='$immediate' batched='$batched' ignore='$ignore'"
  fi
}

# ============================================================================
# Test: scout.sh scan (with mock podman)
# ============================================================================

test_scout_scan_classifies_logs() {
  echo "Test: scout.sh scan classifies log lines by pattern tier"
  local tmpdir
  tmpdir="$(mktemp -d "$SUITE_TMPDIR/scout-scan-XXXX")"
  local mock_bin="$tmpdir/bin"
  mkdir -p "$mock_bin" "$tmpdir/errors"

  # Write default patterns
  echo "FATAL|PANIC|panic:" > "$tmpdir/errors/immediate.pat"
  echo "ERROR|Exception" > "$tmpdir/errors/batched.pat"
  echo "healthcheck" > "$tmpdir/errors/ignore.pat"

  # Mock podman that returns mixed logs
  cat > "$mock_bin/podman" << 'MOCK'
#!/usr/bin/env bash
cat << 'LOGS'
2026-04-01 INFO: service started
2026-04-01 ERROR: connection refused to db
2026-04-01 healthcheck passed
2026-04-01 FATAL: out of memory
2026-04-01 WARN: slow query (not an error pattern)
2026-04-01 Exception in thread main
LOGS
MOCK
  chmod +x "$mock_bin/podman"

  PATH="$mock_bin:$PATH" SCOUT_ERRORS_DIR="$tmpdir/errors" \
    "$REPO_ROOT/lib/city/scout.sh" scan "my-api" --since=5m

  local failures=0

  # FATAL line should be in immediate
  if ! grep -q "FATAL: out of memory" "$tmpdir/errors/my-api/immediate.log"; then
    echo "    FATAL line missing from immediate.log"
    failures=$((failures + 1))
  fi

  # ERROR and Exception lines should be in batched
  if ! grep -q "ERROR: connection refused" "$tmpdir/errors/my-api/batched.log"; then
    echo "    ERROR line missing from batched.log"
    failures=$((failures + 1))
  fi
  if ! grep -q "Exception in thread" "$tmpdir/errors/my-api/batched.log"; then
    echo "    Exception line missing from batched.log"
    failures=$((failures + 1))
  fi

  # healthcheck line should NOT be in any output (ignored)
  if grep -q "healthcheck" "$tmpdir/errors/my-api/immediate.log" "$tmpdir/errors/my-api/batched.log" 2>/dev/null; then
    echo "    healthcheck line was not ignored"
    failures=$((failures + 1))
  fi

  # INFO and WARN (not in any pattern) should not appear
  if grep -q "INFO:" "$tmpdir/errors/my-api/immediate.log" "$tmpdir/errors/my-api/batched.log" 2>/dev/null; then
    echo "    INFO line leaked into error logs"
    failures=$((failures + 1))
  fi

  if [[ "$failures" -eq 0 ]]; then
    pass "log lines correctly classified by tier"
  else
    fail "scan classification has $failures issues"
  fi
}

# ============================================================================
# Test: gate.sh (with mock bd and gc)
# ============================================================================

test_gate_approve_exits_0() {
  echo "Test: gate.sh exits 0 when reviewer approves"
  local tmpdir
  tmpdir="$(mktemp -d "$SUITE_TMPDIR/gate-XXXX")"
  local mock_bin="$tmpdir/bin"
  mkdir -p "$mock_bin"

  # Mock bd: meta get returns commit_range, then review_verdict=approve
  cat > "$mock_bin/bd" << 'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "meta" ]] && [[ "$2" == "get" ]]; then
  case "$4" in
    commit_range) echo "abc123..def456" ;;
    review_verdict) echo "approve" ;;
  esac
fi
MOCK
  chmod +x "$mock_bin/bd"

  # Mock gc nudge (no-op)
  cat > "$mock_bin/gc" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$mock_bin/gc"

  local exit_code=0
  PATH="$mock_bin:$PATH" GC_BEAD_ID="test-bead-1" GC_POLL_INTERVAL=0 GC_POLL_TIMEOUT=5 \
    "$REPO_ROOT/lib/city/gate.sh" > "$tmpdir/out" 2>&1 || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    pass "gate exits 0 on approve"
  else
    fail "gate exited $exit_code on approve (expected 0)"
    cat "$tmpdir/out" | sed 's/^/    /'
  fi
}

test_gate_reject_exits_1() {
  echo "Test: gate.sh exits 1 when reviewer rejects"
  local tmpdir
  tmpdir="$(mktemp -d "$SUITE_TMPDIR/gate-XXXX")"
  local mock_bin="$tmpdir/bin"
  mkdir -p "$mock_bin"

  cat > "$mock_bin/bd" << 'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "meta" ]] && [[ "$2" == "get" ]]; then
  case "$4" in
    commit_range) echo "abc123..def456" ;;
    review_verdict) echo "reject" ;;
  esac
fi
MOCK
  chmod +x "$mock_bin/bd"

  cat > "$mock_bin/gc" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$mock_bin/gc"

  local exit_code=0
  PATH="$mock_bin:$PATH" GC_BEAD_ID="test-bead-1" GC_POLL_INTERVAL=0 GC_POLL_TIMEOUT=5 \
    "$REPO_ROOT/lib/city/gate.sh" > "$tmpdir/out" 2>&1 || exit_code=$?

  if [[ "$exit_code" -eq 1 ]]; then
    pass "gate exits 1 on reject"
  else
    fail "gate exited $exit_code on reject (expected 1)"
  fi
}

test_gate_no_commit_range_exits_1() {
  echo "Test: gate.sh exits 1 when commit_range is missing"
  local tmpdir
  tmpdir="$(mktemp -d "$SUITE_TMPDIR/gate-XXXX")"
  local mock_bin="$tmpdir/bin"
  mkdir -p "$mock_bin"

  cat > "$mock_bin/bd" << 'MOCK'
#!/usr/bin/env bash
# Return empty for all meta get calls
echo ""
MOCK
  chmod +x "$mock_bin/bd"

  cat > "$mock_bin/gc" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$mock_bin/gc"

  local exit_code=0
  PATH="$mock_bin:$PATH" GC_BEAD_ID="test-bead-1" GC_POLL_INTERVAL=0 GC_POLL_TIMEOUT=5 \
    "$REPO_ROOT/lib/city/gate.sh" > "$tmpdir/out" 2>&1 || exit_code=$?

  if [[ "$exit_code" -eq 1 ]]; then
    pass "gate exits 1 when commit_range missing"
  else
    fail "gate exited $exit_code when commit_range missing (expected 1)"
  fi
}

test_gate_nudges_reviewer() {
  echo "Test: gate.sh nudges the reviewer with bead ID and commit range"
  local tmpdir
  tmpdir="$(mktemp -d "$SUITE_TMPDIR/gate-XXXX")"
  local mock_bin="$tmpdir/bin"
  mkdir -p "$mock_bin"

  cat > "$mock_bin/bd" << 'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "meta" ]] && [[ "$2" == "get" ]]; then
  case "$4" in
    commit_range) echo "abc123..def456" ;;
    review_verdict) echo "approve" ;;
  esac
fi
MOCK
  chmod +x "$mock_bin/bd"

  # gc mock that records calls
  cat > "$mock_bin/gc" << MOCK
#!/usr/bin/env bash
echo "\$@" >> "$tmpdir/gc.log"
MOCK
  chmod +x "$mock_bin/gc"

  PATH="$mock_bin:$PATH" GC_BEAD_ID="bead-42" GC_POLL_INTERVAL=0 GC_POLL_TIMEOUT=5 \
    "$REPO_ROOT/lib/city/gate.sh" > /dev/null 2>&1 || true

  if grep -q "nudge reviewer.*bead-42" "$tmpdir/gc.log" 2>/dev/null &&
     grep -q "abc123..def456" "$tmpdir/gc.log" 2>/dev/null; then
    pass "gate nudges reviewer with bead ID and commit range"
  else
    fail "gc nudge call missing or wrong args"
    [[ -f "$tmpdir/gc.log" ]] && cat "$tmpdir/gc.log" | sed 's/^/    /'
  fi
}

# ============================================================================
# Test: post-gate.sh merge logic (with mock git, bd, etc.)
# ============================================================================

test_postgate_approved_ff_merge() {
  echo "Test: post-gate.sh fast-forward merges on approved"
  local tmpdir
  tmpdir="$(mktemp -d "$SUITE_TMPDIR/pg-XXXX")"

  # Set up a real git repo so merge commands work
  git -C "$tmpdir" init -q -b main
  git -C "$tmpdir" commit --allow-empty -m "initial" -q
  git -C "$tmpdir" checkout -b gc-test-bead -q
  echo "fix" > "$tmpdir/fix.txt"
  git -C "$tmpdir" add fix.txt
  git -C "$tmpdir" commit -m "fix" -q
  git -C "$tmpdir" checkout main -q

  local mock_bin="$tmpdir/bin"
  mkdir -p "$mock_bin"

  # Mock bd, wrapix-notifyd, prek
  cat > "$mock_bin/bd" << 'MOCK'
#!/usr/bin/env bash
case "$1" in
  show) echo '{"title":"test fix","status":"closed"}' ;;
  create) echo "deploy-bead-1" ;;
  *) ;;
esac
MOCK
  chmod +x "$mock_bin/bd"

  cat > "$mock_bin/wrapix-notifyd" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$mock_bin/wrapix-notifyd"

  # Run post-gate with approved
  local exit_code=0
  PATH="$mock_bin:$PATH" \
    GC_BEAD_ID="test-bead" \
    GC_TERMINAL_REASON="approved" \
    GC_WORKSPACE="$tmpdir" \
    GC_CITY_NAME="test-city" \
    "$REPO_ROOT/lib/city/post-gate.sh" > "$tmpdir/out" 2>&1 || exit_code=$?

  # Verify the fix was merged to main
  if git -C "$tmpdir" log --oneline main | grep -q "fix"; then
    pass "post-gate fast-forward merged the fix to main"
  else
    fail "fix not merged to main (exit=$exit_code)"
    cat "$tmpdir/out" | sed 's/^/    /'
  fi
}

test_postgate_escalation_cleans_up() {
  echo "Test: post-gate.sh handles escalation (cleans up branch/worktree)"
  local tmpdir
  tmpdir="$(mktemp -d "$SUITE_TMPDIR/pg-XXXX")"

  git -C "$tmpdir" init -q -b main
  git -C "$tmpdir" commit --allow-empty -m "initial" -q
  git -C "$tmpdir" checkout -b gc-esc-bead -q
  git -C "$tmpdir" commit --allow-empty -m "wip" -q
  git -C "$tmpdir" checkout main -q

  local mock_bin="$tmpdir/bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/wrapix-notifyd" << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> /tmp/notify-$$.log
MOCK
  chmod +x "$mock_bin/wrapix-notifyd"
  cat > "$mock_bin/bd" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$mock_bin/bd"

  PATH="$mock_bin:$PATH" \
    GC_BEAD_ID="esc-bead" \
    GC_TERMINAL_REASON="max_iterations_exceeded" \
    GC_WORKSPACE="$tmpdir" \
    GC_CITY_NAME="test-city" \
    "$REPO_ROOT/lib/city/post-gate.sh" > "$tmpdir/out" 2>&1 || true

  # Branch should be cleaned up
  if ! git -C "$tmpdir" rev-parse --verify gc-esc-bead >/dev/null 2>&1; then
    pass "escalation cleaned up branch"
  else
    fail "branch gc-esc-bead still exists after escalation"
  fi
}

# ============================================================================
# Test: agent.sh prompt construction
# ============================================================================

test_agent_build_prompt_includes_docs() {
  echo "Test: agent.sh prepends docs/ content to prompt"
  local tmpdir
  tmpdir="$(mktemp -d "$SUITE_TMPDIR/agent-XXXX")"

  # Create docs with real content
  mkdir -p "$tmpdir/docs"
  echo "Project uses Nix for builds." > "$tmpdir/docs/README.md"
  echo "Shell: use set -euo pipefail." > "$tmpdir/docs/style-guidelines.md"

  # Create task file
  echo "Fix the broken auth module." > "$tmpdir/task.md"

  # Mock claude to just print what it receives via -p
  local mock_bin="$tmpdir/bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/claude" << 'MOCK'
#!/usr/bin/env bash
# claude -p "<prompt>"
if [[ "$1" == "-p" ]]; then
  echo "$2"
fi
MOCK
  chmod +x "$mock_bin/claude"

  local output
  output="$(PATH="$mock_bin:$PATH" \
    WRAPIX_AGENT=claude \
    WRAPIX_PROMPT_FILE="$tmpdir/task.md" \
    WRAPIX_DOCS_DIR="$tmpdir/docs" \
    "$REPO_ROOT/lib/city/agent.sh" run 2>&1)"

  local failures=0

  # Prompt should contain docs content
  if ! echo "$output" | grep -q "Project uses Nix"; then
    echo "    docs/README.md content not in prompt"
    failures=$((failures + 1))
  fi
  if ! echo "$output" | grep -q "set -euo pipefail"; then
    echo "    docs/style-guidelines.md content not in prompt"
    failures=$((failures + 1))
  fi
  # Prompt should contain the task
  if ! echo "$output" | grep -q "Fix the broken auth module"; then
    echo "    task file content not in prompt"
    failures=$((failures + 1))
  fi
  # Task should come after docs (docs are context)
  local docs_line task_line
  docs_line="$(echo "$output" | grep -n "Project uses Nix" | head -1 | cut -d: -f1)"
  task_line="$(echo "$output" | grep -n "Fix the broken auth" | head -1 | cut -d: -f1)"
  if [[ -n "$docs_line" ]] && [[ -n "$task_line" ]] && [[ "$docs_line" -ge "$task_line" ]]; then
    echo "    docs context should come before task"
    failures=$((failures + 1))
  fi

  if [[ "$failures" -eq 0 ]]; then
    pass "agent.sh prepends docs context to task prompt"
  else
    fail "prompt construction has $failures issues"
  fi
}

test_agent_missing_prompt_file_fails() {
  echo "Test: agent.sh exits non-zero when WRAPIX_PROMPT_FILE is missing"
  local mock_bin="$SUITE_TMPDIR/agent-nofile/bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/claude" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$mock_bin/claude"

  local exit_code=0
  PATH="$mock_bin:$PATH" WRAPIX_AGENT=claude \
    WRAPIX_PROMPT_FILE="/nonexistent/file.md" \
    "$REPO_ROOT/lib/city/agent.sh" run > /dev/null 2>&1 || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    pass "agent.sh fails when prompt file missing"
  else
    fail "agent.sh should fail when prompt file doesn't exist"
  fi
}

# ============================================================================
# Test: provider.sh worker lifecycle
# ============================================================================

test_provider_worker_creates_worktree() {
  echo "Test: provider.sh Start creates git worktree for worker"
  local tmpdir
  tmpdir="$(mktemp -d "$SUITE_TMPDIR/prov-XXXX")"

  # Set up real git repo
  git -C "$tmpdir" init -q -b main
  git -C "$tmpdir" commit --allow-empty -m "initial" -q

  local mock_bin="$tmpdir/bin"
  mkdir -p "$mock_bin"

  # Mock podman run — record args, succeed
  cat > "$mock_bin/podman" << MOCK
#!/usr/bin/env bash
echo "\$@" >> "$tmpdir/podman.log"
MOCK
  chmod +x "$mock_bin/podman"

  # Mock bd
  cat > "$mock_bin/bd" << MOCK
#!/usr/bin/env bash
echo "\$@" >> "$tmpdir/bd.log"
MOCK
  chmod +x "$mock_bin/bd"

  # Run provider Start for a worker
  PATH="$mock_bin:$PATH" \
    GC_CITY_NAME="test" \
    GC_WORKSPACE="$tmpdir" \
    GC_AGENT_IMAGE="test-image:latest" \
    GC_PODMAN_NETWORK="wrapix-test" \
    GC_BEAD_ID="bead-123" \
    "$REPO_ROOT/lib/city/provider.sh" Start worker-1 > "$tmpdir/out" 2>&1 || true

  local failures=0

  # Worktree should have been created
  if [[ -d "$tmpdir/.wrapix/worktree/gc-bead-123" ]]; then
    : # ok
  else
    echo "    worktree not created at .wrapix/worktree/gc-bead-123"
    failures=$((failures + 1))
  fi

  # Git branch should exist
  if git -C "$tmpdir" rev-parse --verify gc-bead-123 >/dev/null 2>&1; then
    : # ok
  else
    echo "    git branch gc-bead-123 not created"
    failures=$((failures + 1))
  fi

  # Podman should have been called with the worktree mounted
  if grep -q "worktree/gc-bead-123:/workspace" "$tmpdir/podman.log" 2>/dev/null; then
    : # ok
  else
    echo "    podman not called with worktree mount"
    failures=$((failures + 1))
  fi

  if [[ "$failures" -eq 0 ]]; then
    pass "provider creates worktree and mounts it for worker"
  else
    fail "worker worktree lifecycle has $failures issues"
  fi
}

test_provider_worker_sets_task_file() {
  echo "Test: provider.sh creates and mounts task file for worker"
  local tmpdir
  tmpdir="$(mktemp -d "$SUITE_TMPDIR/prov-task-XXXX")"

  git -C "$tmpdir" init -q -b main
  git -C "$tmpdir" commit --allow-empty -m "initial" -q

  local mock_bin="$tmpdir/bin"
  mkdir -p "$mock_bin"

  cat > "$mock_bin/podman" << MOCK
#!/usr/bin/env bash
echo "\$@" >> "$tmpdir/podman.log"
MOCK
  chmod +x "$mock_bin/podman"
  cat > "$mock_bin/bd" << MOCK
#!/usr/bin/env bash
echo "\$@" >> "$tmpdir/bd.log"
MOCK
  chmod +x "$mock_bin/bd"

  PATH="$mock_bin:$PATH" \
    GC_CITY_NAME="test" \
    GC_WORKSPACE="$tmpdir" \
    GC_AGENT_IMAGE="test-image:latest" \
    GC_PODMAN_NETWORK="wrapix-test" \
    GC_BEAD_ID="bead-456" \
    "$REPO_ROOT/lib/city/provider.sh" Start worker-1 > "$tmpdir/out" 2>&1 || true

  # The provider should either:
  # a) Mount a task file at /workspace/.task via -v flag, OR
  # b) Set WRAPIX_PROMPT_FILE env var pointing to a task file
  local has_task_mount=false has_prompt_env=false

  if grep -qE '\.task:/workspace/\.task|/workspace/\.task' "$tmpdir/podman.log" 2>/dev/null; then
    has_task_mount=true
  fi
  if grep -q 'WRAPIX_PROMPT_FILE' "$tmpdir/podman.log" 2>/dev/null; then
    has_prompt_env=true
  fi

  if [[ "$has_task_mount" == "true" ]] || [[ "$has_prompt_env" == "true" ]]; then
    pass "provider sets up task file for worker"
  else
    fail "provider does not create task file or set WRAPIX_PROMPT_FILE"
    echo "    podman calls:" >&2
    cat "$tmpdir/podman.log" 2>/dev/null | sed 's/^/      /' >&2
  fi
}

test_provider_persistent_uses_tmux() {
  echo "Test: provider.sh Start uses tmux as PID 1 for persistent roles"
  local tmpdir
  tmpdir="$(mktemp -d "$SUITE_TMPDIR/prov-tmux-XXXX")"
  local mock_bin="$tmpdir/bin"
  mkdir -p "$mock_bin"

  cat > "$mock_bin/podman" << MOCK
#!/usr/bin/env bash
echo "\$@" >> "$tmpdir/podman.log"
MOCK
  chmod +x "$mock_bin/podman"

  PATH="$mock_bin:$PATH" \
    GC_CITY_NAME="test" \
    GC_WORKSPACE="$tmpdir" \
    GC_AGENT_IMAGE="test-image:latest" \
    GC_PODMAN_NETWORK="wrapix-test" \
    "$REPO_ROOT/lib/city/provider.sh" Start scout > "$tmpdir/out" 2>&1 || true

  if grep -q "tmux new-session" "$tmpdir/podman.log" 2>/dev/null; then
    pass "persistent role starts with tmux"
  else
    fail "persistent role did not use tmux as PID 1"
    cat "$tmpdir/podman.log" 2>/dev/null | sed 's/^/    /'
  fi
}

# ============================================================================
# Test: entrypoint.sh scaffolding check
# ============================================================================

test_entrypoint_blocks_on_scaffolding_beads() {
  echo "Test: entrypoint.sh exits 1 when scaffolding beads are pending"
  local tmpdir
  tmpdir="$(mktemp -d "$SUITE_TMPDIR/entry-XXXX")"
  local mock_bin="$tmpdir/bin"
  mkdir -p "$mock_bin"

  # Mock bd human list returning unresolved scaffolding beads
  cat > "$mock_bin/bd" << 'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "human" ]] && [[ "$2" == "list" ]]; then
  echo '[{"id":"wx-abc","title":"Review scaffolded docs/README.md"}]'
fi
MOCK
  chmod +x "$mock_bin/bd"
  cat > "$mock_bin/jq" << 'MOCK'
#!/usr/bin/env bash
# Minimal jq mock for the entrypoint's needs
input="$(cat)"
case "$1" in
  -r)
    case "$2" in
      '[.[] | select(.title | test("scaffol|docs/|Scaffol"; "i"))]')
        echo "$input"
        ;;
      '.[] | "  - \(.id): \(.title)"')
        echo '  - wx-abc: Review scaffolded docs/README.md'
        ;;
    esac
    ;;
  'length')
    echo "1"
    ;;
esac
MOCK
  chmod +x "$mock_bin/jq"

  local exit_code=0
  PATH="$mock_bin:$PATH" \
    GC_CITY_NAME="test" \
    GC_WORKSPACE="$tmpdir" \
    GC_PODMAN_NETWORK="wrapix-test" \
    "$REPO_ROOT/lib/city/entrypoint.sh" > "$tmpdir/out" 2>&1 || exit_code=$?

  if [[ "$exit_code" -eq 1 ]]; then
    pass "entrypoint blocks when scaffolding beads exist"
  else
    fail "entrypoint exited $exit_code (expected 1 due to pending scaffolding beads)"
    cat "$tmpdir/out" | sed 's/^/    /'
  fi
}

test_entrypoint_proceeds_when_no_scaffolding_beads() {
  echo "Test: entrypoint.sh proceeds past scaffolding check when no beads pending"
  local tmpdir
  tmpdir="$(mktemp -d "$SUITE_TMPDIR/entry-XXXX")"
  local mock_bin="$tmpdir/bin"
  mkdir -p "$mock_bin"

  # Mock bd human list returning empty
  cat > "$mock_bin/bd" << 'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "human" ]] && [[ "$2" == "list" ]]; then
  echo '[]'
fi
MOCK
  chmod +x "$mock_bin/bd"
  cat > "$mock_bin/jq" << 'MOCK'
#!/usr/bin/env bash
input="$(cat)"
case "$1" in
  -r)
    echo '[]'
    ;;
  'length')
    echo "0"
    ;;
esac
MOCK
  chmod +x "$mock_bin/jq"

  # Mock recovery.sh to no-op
  mkdir -p "$tmpdir/city-scripts"
  cat > "$tmpdir/city-scripts/recovery.sh" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$tmpdir/city-scripts/recovery.sh"

  # Mock gc and podman
  cat > "$mock_bin/gc" << 'MOCK'
#!/usr/bin/env bash
echo "gc called: $@"
exit 0
MOCK
  chmod +x "$mock_bin/gc"
  cat > "$mock_bin/podman" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$mock_bin/podman"

  # We can't fully test entrypoint (it execs gc start), but we can verify
  # it gets past the scaffolding check by modifying the script to exit
  # after recovery instead of exec'ing gc.
  # Instead, we just check that it doesn't exit 1 at the scaffolding check.
  # The exec gc will fail (mock gc exits 0 but exec replaces the process).
  local exit_code=0
  PATH="$mock_bin:$PATH" \
    GC_CITY_NAME="test" \
    GC_WORKSPACE="$tmpdir" \
    GC_PODMAN_NETWORK="wrapix-test" \
    timeout 5 bash -c '
      # Override SCRIPT_DIR so recovery.sh points to our mock
      export SCRIPT_DIR="'"$tmpdir/city-scripts"'"
      source <(sed "s|\"\${SCRIPT_DIR}/recovery.sh\"|\"'"$tmpdir/city-scripts/recovery.sh"'\"|" "'"$REPO_ROOT/lib/city/entrypoint.sh"'")
    ' > "$tmpdir/out" 2>&1 || exit_code=$?

  # If it got past the scaffolding check, it should NOT have exited 1
  # with the "unresolved scaffolding" message
  if grep -q "unresolved scaffolding" "$tmpdir/out" 2>/dev/null; then
    fail "entrypoint blocked on scaffolding when no beads pending"
  else
    pass "entrypoint proceeds when no scaffolding beads"
  fi
}

# ============================================================================
# Test: ralph sync scaffolding
# ============================================================================

test_sync_scaffolds_docs_with_content() {
  echo "Test: ralph sync scaffolds docs/ files with real content (not empty)"
  (
    set -euo pipefail
    tmpdir="$(mktemp -d "$SUITE_TMPDIR/sync-XXXX")"

    cd "$tmpdir"
    git init -q -b main
    git commit --allow-empty -m "init" -q

    # Create a flake.nix with mkCity
    cat > flake.nix << 'FLAKE'
{
  outputs = { self, ... }: {
    city = self.lib.mkCity { services.api.package = "hello"; };
  };
}
FLAKE

    # Source helpers and scaffold functions
    source "$REPO_ROOT/lib/ralph/cmd/util.sh"
    export DRY_RUN=false
    export RALPH_DIR=".wrapix/ralph"

    # Override bd to no-op (may not be available)
    bd() { echo "mock-bead-id"; }
    export -f bd

    # Extract and run scaffold functions
    eval "$(sed -n '/^# === Docs Scaffolding Functions ===/,/^# Main$/{ /^# Main$/d; p; }' "$REPO_ROOT/lib/ralph/cmd/sync.sh")"
    scaffold_docs > /dev/null 2>&1

    failures=0

    # Core docs should exist
    for f in docs/README.md docs/architecture.md docs/style-guidelines.md; do
      if [[ ! -f "$f" ]]; then
        echo "    sub-fail: $f not created"
        failures=$((failures + 1))
      fi
    done

    # Orchestration should exist (mkCity detected)
    if [[ ! -f "docs/orchestration.md" ]]; then
      echo "    sub-fail: docs/orchestration.md not scaffolded despite mkCity in flake"
      failures=$((failures + 1))
    fi

    # Files should not be empty
    for f in docs/README.md docs/architecture.md docs/style-guidelines.md docs/orchestration.md; do
      [[ -f "$f" ]] || continue
      if [[ ! -s "$f" ]]; then
        echo "    sub-fail: $f is empty"
        failures=$((failures + 1))
      fi
    done

    # orchestration.md should have Scout Rules with actual patterns
    if [[ -f "docs/orchestration.md" ]]; then
      if ! grep -q 'FATAL|PANIC|panic:' "docs/orchestration.md"; then
        echo "    sub-fail: orchestration.md missing default immediate patterns"
        failures=$((failures + 1))
      fi
    fi

    # Without mkCity, orchestration should not be scaffolded
    rm -rf docs
    echo '{}' > flake.nix
    scaffold_docs > /dev/null 2>&1
    if [[ -f "docs/orchestration.md" ]]; then
      echo "    sub-fail: orchestration.md created without mkCity"
      failures=$((failures + 1))
    fi

    # Idempotent: re-running should not overwrite existing files
    rm -rf docs
    echo '{ outputs = { ... }: { city = lib.mkCity {}; }; }' > flake.nix
    scaffold_docs > /dev/null 2>&1
    local mtime
    mtime="$(stat -c %Y docs/README.md 2>/dev/null || stat -f %m docs/README.md 2>/dev/null)"
    sleep 1
    scaffold_docs > /dev/null 2>&1
    local mtime2
    mtime2="$(stat -c %Y docs/README.md 2>/dev/null || stat -f %m docs/README.md 2>/dev/null)"
    if [[ "$mtime" != "$mtime2" ]]; then
      echo "    sub-fail: scaffold overwrote existing docs/README.md"
      failures=$((failures + 1))
    fi

    echo "FAILURES=$failures"
  ) > "$SUITE_TMPDIR/sync-out" 2>&1

  local result
  result="$(cat "$SUITE_TMPDIR/sync-out")"
  echo "$result" | grep -v '^FAILURES=' | grep "sub-" || true

  local failures
  failures="$(echo "$result" | grep '^FAILURES=' | cut -d= -f2)"
  if [[ "${failures:-1}" == "0" ]]; then
    pass "docs scaffolding creates files with content"
  else
    fail "docs scaffolding has ${failures} issues"
  fi
}

# ============================================================================
# Test: AGENTS.md / CLAUDE.md reference integrity
# ============================================================================

test_agent_instructions_reference_correct_paths() {
  echo "Test: AGENTS.md and CLAUDE.md reference paths that exist"
  local failures=0

  for f in "$REPO_ROOT/AGENTS.md" "$REPO_ROOT/CLAUDE.md"; do
    [[ -f "$f" ]] || continue
    local name
    name="$(basename "$f")"

    # Extract all file paths referenced in the instructions
    # Look for patterns like `specs/foo.md`, `docs/bar.md`, `lib/...`
    while IFS= read -r ref; do
      # Resolve relative to repo root
      if [[ ! -e "$REPO_ROOT/$ref" ]]; then
        echo "    $name references '$ref' which does not exist"
        failures=$((failures + 1))
      fi
    done < <(grep -oE '`(specs|docs|lib)/[^`]+`' "$f" | tr -d '`' | sort -u)
  done

  if [[ "$failures" -eq 0 ]]; then
    pass "agent instruction files reference valid paths"
  else
    fail "agent instructions have $failures broken references"
  fi
}

# ============================================================================
# Test: docs/style-guidelines.md has actionable content
# ============================================================================

test_style_guidelines_has_rules() {
  echo "Test: docs/style-guidelines.md has actual rules (not just placeholder)"
  local sg="$REPO_ROOT/docs/style-guidelines.md"

  if [[ ! -f "$sg" ]]; then
    fail "docs/style-guidelines.md does not exist"
    return
  fi

  # The file should NOT be just a scaffold placeholder — it needs real rules
  # that the reviewer can mechanically enforce.
  local line_count
  line_count="$(wc -l < "$sg")"

  # A placeholder has <15 lines and contains "Describe formatting"
  if [[ "$line_count" -lt 15 ]] && grep -q "Describe formatting" "$sg"; then
    fail "docs/style-guidelines.md is a placeholder with no actual rules (reviewer has nothing to enforce)"
  else
    pass "docs/style-guidelines.md has content beyond placeholder"
  fi
}

# ============================================================================
# Test: NixOS module plumbs env vars to gc container
# ============================================================================

test_nixos_module_passes_agent_image() {
  echo "Test: NixOS module passes GC_AGENT_IMAGE to gc container"
  local module="$REPO_ROOT/modules/city.nix"

  if [[ ! -f "$module" ]]; then
    fail "modules/city.nix not found"
    return
  fi

  # The startScript in the module should set GC_AGENT_IMAGE as an env var
  # so the provider script inside the gc container knows which image to use
  # for agent containers (scout, worker, reviewer).
  if grep -q 'GC_AGENT_IMAGE' "$module"; then
    pass "NixOS module passes GC_AGENT_IMAGE"
  else
    fail "NixOS module does not set GC_AGENT_IMAGE — provider.sh requires it"
  fi
}

test_nixos_module_passes_podman_network() {
  echo "Test: NixOS module passes GC_PODMAN_NETWORK to gc container"
  local module="$REPO_ROOT/modules/city.nix"

  if [[ ! -f "$module" ]]; then
    fail "modules/city.nix not found"
    return
  fi

  if grep -q 'GC_PODMAN_NETWORK' "$module"; then
    pass "NixOS module passes GC_PODMAN_NETWORK"
  else
    fail "NixOS module does not set GC_PODMAN_NETWORK — provider.sh requires it"
  fi
}

# ============================================================================
# Test: recovery.sh functional test with mock podman/bd/git
# ============================================================================

test_recovery_stops_orphaned_workers() {
  echo "Test: recovery.sh stops worker containers with no matching in-progress bead"
  local tmpdir
  tmpdir="$(mktemp -d "$SUITE_TMPDIR/rec-XXXX")"

  # Set up git repo
  git -C "$tmpdir" init -q -b main
  git -C "$tmpdir" commit --allow-empty -m "initial" -q

  local mock_bin="$tmpdir/bin"
  mkdir -p "$mock_bin"

  # Mock podman: ps returns a worker, inspect returns labels
  cat > "$mock_bin/podman" << MOCK
#!/usr/bin/env bash
echo "\$@" >> "$tmpdir/podman.log"
case "\$1" in
  ps)
    echo "gc-test-worker-orphan"
    ;;
  inspect)
    case "\$3" in
      *gc-bead*) echo "orphan-bead" ;;
      *gc-role*) echo "worker" ;;
      *Running*) echo "true" ;;
    esac
    ;;
  stop|rm)
    echo "\$@" >> "$tmpdir/podman-stop.log"
    ;;
esac
MOCK
  chmod +x "$mock_bin/podman"

  # Mock bd: show returns closed status (orphan)
  cat > "$mock_bin/bd" << 'MOCK'
#!/usr/bin/env bash
case "$1" in
  show) echo '{"status":"closed"}' ;;
  *) ;;
esac
MOCK
  chmod +x "$mock_bin/bd"

  PATH="$mock_bin:$PATH" \
    GC_CITY_NAME="test" \
    GC_WORKSPACE="$tmpdir" \
    "$REPO_ROOT/lib/city/recovery.sh" > "$tmpdir/out" 2>&1 || true

  if [[ -f "$tmpdir/podman-stop.log" ]] && grep -q "stop\|rm" "$tmpdir/podman-stop.log"; then
    pass "recovery stops orphaned worker containers"
  else
    fail "recovery did not stop orphaned worker"
    cat "$tmpdir/out" | sed 's/^/    /'
  fi
}

# ============================================================================
# Run all tests
# ============================================================================

echo "=== Gas City Functional Tests ==="
echo ""

echo "--- Scout ---"
test_scout_parse_rules_defaults
test_scout_parse_rules_custom
test_scout_scan_classifies_logs

echo ""
echo "--- Gate ---"
test_gate_approve_exits_0
test_gate_reject_exits_1
test_gate_no_commit_range_exits_1
test_gate_nudges_reviewer

echo ""
echo "--- Post-gate ---"
test_postgate_approved_ff_merge
test_postgate_escalation_cleans_up

echo ""
echo "--- Agent wrapper ---"
test_agent_build_prompt_includes_docs
test_agent_missing_prompt_file_fails

echo ""
echo "--- Provider ---"
test_provider_worker_creates_worktree
test_provider_worker_sets_task_file
test_provider_persistent_uses_tmux

echo ""
echo "--- Entrypoint ---"
test_entrypoint_blocks_on_scaffolding_beads
test_entrypoint_proceeds_when_no_scaffolding_beads

echo ""
echo "--- Scaffolding ---"
test_sync_scaffolds_docs_with_content

echo ""
echo "--- Reference integrity ---"
test_agent_instructions_reference_correct_paths
test_style_guidelines_has_rules

echo ""
echo "--- NixOS module env plumbing ---"
test_nixos_module_passes_agent_image
test_nixos_module_passes_podman_network

echo ""
echo "--- Recovery ---"
test_recovery_stops_orphaned_workers

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"
if [[ $TESTS_FAILED -gt 0 ]]; then
  exit 1
fi
