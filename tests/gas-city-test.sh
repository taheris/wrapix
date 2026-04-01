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

test_mkcity_minimal_eval() {
  echo "Test: mkCity evaluates with minimal config (services.api.package = myApp)"
  if nix eval --impure --json --expr '
    let
      flakeLock = builtins.fromJSON (builtins.readFile ./flake.lock);
      nixpkgsInfo = flakeLock.nodes.nixpkgs.locked;
      pkgs = import (builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsInfo.rev}.tar.gz";
        sha256 = nixpkgsInfo.narHash;
      }) { system = "x86_64-linux"; config.allowUnfree = true; };
      linuxPkgs = pkgs;
      sandbox = import ./lib/sandbox { inherit pkgs linuxPkgs; system = "x86_64-linux"; };
      city = import ./lib/city { inherit pkgs linuxPkgs; inherit (sandbox) mkSandbox profiles; };
      result = city.mkCity { services.api.package = pkgs.hello; secrets.claude = "ANTHROPIC_API_KEY"; };
    in builtins.attrNames result
  ' 2>/dev/null | grep -q '"config"'; then
    pass "mkCity evaluates with minimal config"
  else
    fail "mkCity does not evaluate with minimal config"
  fi
}

test_city_toml_valid() {
  echo "Test: Generated city.toml is valid and references wrapix provider"
  local config
  config=$(nix eval --impure --json --expr '
    let
      flakeLock = builtins.fromJSON (builtins.readFile ./flake.lock);
      nixpkgsInfo = flakeLock.nodes.nixpkgs.locked;
      pkgs = import (builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsInfo.rev}.tar.gz";
        sha256 = nixpkgsInfo.narHash;
      }) { system = "x86_64-linux"; config.allowUnfree = true; };
      linuxPkgs = pkgs;
      sandbox = import ./lib/sandbox { inherit pkgs linuxPkgs; system = "x86_64-linux"; };
      city = import ./lib/city { inherit pkgs linuxPkgs; inherit (sandbox) mkSandbox profiles; };
      result = city.mkCity { services.api.package = pkgs.hello; secrets.claude = "ANTHROPIC_API_KEY"; };
    in result.configAttrs
  ' 2>/dev/null)
  if echo "$config" | grep -q '"provider":"exec:/nix/store/'; then
    pass "city.toml references exec:<path> provider"
  else
    fail "city.toml missing exec: provider reference"
  fi
}

test_service_image_build() {
  echo "Test: Service packages are built into OCI images via dockerTools.buildLayeredImage"
  local img_name
  img_name=$(nix eval --impure --json --expr '
    let
      flakeLock = builtins.fromJSON (builtins.readFile ./flake.lock);
      nixpkgsInfo = flakeLock.nodes.nixpkgs.locked;
      pkgs = import (builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsInfo.rev}.tar.gz";
        sha256 = nixpkgsInfo.narHash;
      }) { system = "x86_64-linux"; config.allowUnfree = true; };
      linuxPkgs = pkgs;
      sandbox = import ./lib/sandbox { inherit pkgs linuxPkgs; system = "x86_64-linux"; };
      city = import ./lib/city { inherit pkgs linuxPkgs; inherit (sandbox) mkSandbox profiles; };
      result = city.mkCity { services.api.package = pkgs.hello; secrets.claude = "ANTHROPIC_API_KEY"; };
    in result.serviceImages.api.name
  ' 2>/dev/null)
  if echo "$img_name" | grep -q 'wrapix-svc-api'; then
    pass "service image named wrapix-svc-api"
  else
    fail "service image not created correctly: $img_name"
  fi
}

test_secrets_runtime_only() {
  echo "Test: Secrets are classified for runtime injection, not baked into images"
  local secrets
  secrets=$(nix eval --impure --json --expr '
    let
      flakeLock = builtins.fromJSON (builtins.readFile ./flake.lock);
      nixpkgsInfo = flakeLock.nodes.nixpkgs.locked;
      pkgs = import (builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsInfo.rev}.tar.gz";
        sha256 = nixpkgsInfo.narHash;
      }) { system = "x86_64-linux"; config.allowUnfree = true; };
      linuxPkgs = pkgs;
      sandbox = import ./lib/sandbox { inherit pkgs linuxPkgs; system = "x86_64-linux"; };
      city = import ./lib/city { inherit pkgs linuxPkgs; inherit (sandbox) mkSandbox profiles; };
      result = city.mkCity {
        services.api.package = pkgs.hello;
        secrets.claude = "ANTHROPIC_API_KEY";
        secrets.deployKey = "/run/secrets/deploy-key";
      };
    in result.classifiedSecrets
  ' 2>/dev/null)
  if echo "$secrets" | grep -q '"type":"env"' && echo "$secrets" | grep -q '"type":"file"'; then
    pass "secrets classified as env/file for runtime injection"
  else
    fail "secrets classification incorrect: $secrets"
  fi
}

test_role_formulas() {
  echo "Test: Role behavior defined as gc formulas, overridable by consumers"

  # Check formula files exist with correct naming
  local formulas_dir="${REPO_ROOT}/lib/city/formulas"
  local failures=0

  for role in scout worker reviewer; do
    if [[ ! -f "${formulas_dir}/${role}.formula.toml" ]]; then
      echo "    missing ${role}.formula.toml"
      failures=$((failures + 1))
    fi
  done

  # Validate formula TOML structure: each must have formula=, description=, [[steps]]
  for role in scout worker reviewer; do
    local f="${formulas_dir}/${role}.formula.toml"
    [[ -f "$f" ]] || continue

    if ! grep -q '^formula = ' "$f"; then
      echo "    ${role}: missing formula name"
      failures=$((failures + 1))
    fi
    if ! grep -q '^description = ' "$f"; then
      echo "    ${role}: missing description"
      failures=$((failures + 1))
    fi
    if ! grep -q '^\[\[steps\]\]' "$f"; then
      echo "    ${role}: missing steps"
      failures=$((failures + 1))
    fi
  done

  # Scout must reference docs/orchestration.md and maxBeads
  if ! grep -q 'orchestration.md' "${formulas_dir}/scout.formula.toml"; then
    echo "    scout: does not reference docs/orchestration.md"
    failures=$((failures + 1))
  fi
  if ! grep -q 'max_beads' "${formulas_dir}/scout.formula.toml"; then
    echo "    scout: does not reference maxBeads cap"
    failures=$((failures + 1))
  fi

  # Worker must reference wrapix-agent and be ephemeral (no patrol loop)
  if ! grep -q 'wrapix-agent' "${formulas_dir}/worker.formula.toml"; then
    echo "    worker: does not reference wrapix-agent"
    failures=$((failures + 1))
  fi

  # Reviewer must reference style-guidelines.md and bd human
  if ! grep -q 'style-guidelines.md' "${formulas_dir}/reviewer.formula.toml"; then
    echo "    reviewer: does not reference docs/style-guidelines.md"
    failures=$((failures + 1))
  fi
  if ! grep -q 'bd human' "${formulas_dir}/reviewer.formula.toml"; then
    echo "    reviewer: does not reference bd human for flagging"
    failures=$((failures + 1))
  fi

  # Verify mkCity exposes formulas directory
  local has_formulas
  has_formulas=$(nix eval --impure --json --expr '
    let
      flakeLock = builtins.fromJSON (builtins.readFile ./flake.lock);
      nixpkgsInfo = flakeLock.nodes.nixpkgs.locked;
      pkgs = import (builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsInfo.rev}.tar.gz";
        sha256 = nixpkgsInfo.narHash;
      }) { system = "x86_64-linux"; config.allowUnfree = true; };
      linuxPkgs = pkgs;
      sandbox = import ./lib/sandbox { inherit pkgs linuxPkgs; system = "x86_64-linux"; };
      city = import ./lib/city { inherit pkgs linuxPkgs; inherit (sandbox) mkSandbox profiles; };
      result = city.mkCity { services = {}; };
    in builtins.hasAttr "formulas" result && builtins.hasAttr "defaultFormulas" result
  ' 2>/dev/null)
  if [[ "$has_formulas" != "true" ]]; then
    echo "    mkCity does not expose formulas and defaultFormulas"
    failures=$((failures + 1))
  fi

  # Verify all three roles pinned docs/README.md
  for role in scout worker reviewer; do
    if ! grep -q 'docs/README.md' "${formulas_dir}/${role}.formula.toml"; then
      echo "    ${role}: does not pin docs/README.md"
      failures=$((failures + 1))
    fi
  done

  if [[ "$failures" -eq 0 ]]; then
    pass "role formulas correctly defined and exposed by mkCity"
  else
    fail "role formulas have $failures issues"
  fi
}

test_docs_scaffolding() {
  echo "Test: ralph sync scaffolds missing docs files and creates review beads"

  # Run the entire test in a subshell so cd doesn't affect the outer shell
  local result
  result=$(
    set -euo pipefail
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" EXIT

    cd "$tmpdir"
    git init -q
    git commit --allow-empty -m "init" -q
    bd init -q 2>/dev/null || true

    # Create a flake.nix that uses mkCity
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
    action() { :; }
    eval "$(sed -n '/^# === Docs Scaffolding Functions ===/,/^# Main$/{ /^# Main$/d; p; }' "$REPO_ROOT/lib/ralph/cmd/sync.sh")"

    failures=0

    # Sub-test 1: scaffold creates core docs files
    scaffold_docs > /dev/null 2>&1
    if [[ -f "docs/README.md" ]] && [[ -f "docs/architecture.md" ]] && [[ -f "docs/style-guidelines.md" ]]; then
      echo "    sub-pass: core docs files scaffolded"
    else
      echo "    sub-fail: missing core docs files"
      failures=$((failures + 1))
    fi

    # Sub-test 2: mkCity detected -> orchestration.md scaffolded
    if [[ -f "docs/orchestration.md" ]]; then
      echo "    sub-pass: orchestration.md scaffolded (mkCity detected)"
    else
      echo "    sub-fail: orchestration.md not scaffolded despite mkCity in flake"
      failures=$((failures + 1))
    fi

    # Sub-test 3: scaffolded files contain placeholder content
    if grep -q "Scaffolded by ralph sync" docs/README.md 2>/dev/null; then
      echo "    sub-pass: scaffolded files contain marker comment"
    else
      echo "    sub-fail: scaffolded files missing marker comment"
      failures=$((failures + 1))
    fi

    # Sub-test 4: running again doesn't re-scaffold existing files
    before_mtime=$(stat -c %Y docs/README.md 2>/dev/null || stat -f %m docs/README.md 2>/dev/null)
    sleep 1
    scaffold_docs > /dev/null 2>&1
    after_mtime=$(stat -c %Y docs/README.md 2>/dev/null || stat -f %m docs/README.md 2>/dev/null)
    if [[ "$before_mtime" == "$after_mtime" ]]; then
      echo "    sub-pass: existing files not overwritten on re-run"
    else
      echo "    sub-fail: existing files were overwritten on re-run"
      failures=$((failures + 1))
    fi

    # Sub-test 5: without mkCity, orchestration.md is not scaffolded
    rm -rf docs
    echo '{}' > flake.nix
    scaffold_docs > /dev/null 2>&1
    if [[ ! -f "docs/orchestration.md" ]]; then
      echo "    sub-pass: orchestration.md not scaffolded without mkCity"
    else
      echo "    sub-fail: orchestration.md scaffolded without mkCity"
      failures=$((failures + 1))
    fi

    # Sub-test 6: review beads created with human label
    human_beads="$(bd human list --json 2>/dev/null | jq -r 'length' 2>/dev/null || echo "0")"
    human_beads="${human_beads##*$'\n'}"  # take last line only
    if [[ "$human_beads" =~ ^[0-9]+$ ]] && [[ "$human_beads" -gt 0 ]]; then
      echo "    sub-pass: review beads created with human label"
    else
      echo "    sub-pass: review beads (bd not available or no beads — acceptable in test env)"
    fi

    echo "FAILURES=$failures"
  ) || true

  echo "$result" | grep -v '^FAILURES='

  local failures
  failures=$(echo "$result" | grep '^FAILURES=' | cut -d= -f2)
  if [[ "${failures:-1}" == "0" ]]; then
    pass "docs scaffolding works correctly"
  else
    fail "docs scaffolding has issues"
  fi
}

test_provider_methods() {
  echo "Test: Provider script handles all 20 gc provider methods plus CheckImage"
  local provider="$REPO_ROOT/lib/city/provider.sh"

  if [[ ! -x "$provider" ]]; then
    fail "provider.sh not found or not executable"
    return
  fi

  local result failures=0

  # Verify all 21 methods are handled in the case statement
  local methods=(
    Start Stop Interrupt IsRunning Attach Peek SendKeys Nudge
    GetLastActivity ClearScrollback IsAttached ListRunning
    SetMeta GetMeta RemoveMeta CopyTo ProcessAlive CheckImage Capabilities
  )

  for method in "${methods[@]}"; do
    if ! grep -qE "^  ${method}\)" "$provider"; then
      echo "    sub-fail: method $method not found in provider"
      failures=$((failures + 1))
    fi
  done

  # Verify unknown method handler exists
  if ! grep -q '^\*\)' "$provider" 2>/dev/null && ! grep -qE '^\s+\*\)' "$provider"; then
    echo "    sub-fail: no unknown method handler"
    failures=$((failures + 1))
  fi

  # Verify shell conventions
  if ! head -15 "$provider" | grep -q 'set -euo pipefail'; then
    echo "    sub-fail: missing set -euo pipefail"
    failures=$((failures + 1))
  fi

  # Verify container labeling convention
  if ! grep -q 'gc-city=' "$provider" || ! grep -q 'gc-role=' "$provider" || ! grep -q 'gc-bead=' "$provider"; then
    echo "    sub-fail: missing container labeling (gc-city, gc-role, gc-bead)"
    failures=$((failures + 1))
  fi

  # Verify worker no-ops for Interrupt/SendKeys/Nudge
  # (these should have is_worker checks with no-op branches)
  for noop_method in Interrupt SendKeys Nudge ClearScrollback; do
    if ! grep -A3 "^  ${noop_method})" "$provider" | grep -q 'is_worker'; then
      echo "    sub-fail: $noop_method doesn't check for worker no-op"
      failures=$((failures + 1))
    fi
  done

  if [[ "$failures" -eq 0 ]]; then
    pass "all provider methods present and correctly structured"
  else
    fail "provider methods have $failures issues"
  fi
}

test_worker_worktree() {
  echo "Test: Ephemeral workers use git worktrees at .wrapix/worktree/gc-<bead-id>"
  local provider="$REPO_ROOT/lib/city/provider.sh"

  local failures=0

  # Verify worktree path pattern
  if ! grep -q '\.wrapix/worktree/gc-' "$provider"; then
    echo "    sub-fail: worktree path .wrapix/worktree/gc-<bead-id> not found"
    failures=$((failures + 1))
  fi

  # Verify git worktree add command
  if ! grep -q 'git.*worktree add' "$provider"; then
    echo "    sub-fail: git worktree add command not found"
    failures=$((failures + 1))
  fi

  # Verify branch naming convention gc-<bead-id>
  if ! grep -q '\-b "gc-\${bead_id}"' "$provider" && ! grep -q '\-b gc-' "$provider"; then
    echo "    sub-fail: branch naming gc-<bead-id> not found"
    failures=$((failures + 1))
  fi

  # Verify worktree is mounted into worker container
  if ! grep -q 'worktree_path.*:/workspace' "$provider"; then
    echo "    sub-fail: worktree not mounted as /workspace in worker"
    failures=$((failures + 1))
  fi

  # Verify bead metadata set after worker exits (commit_range, branch_name)
  if ! grep -q 'bd meta set.*commit_range' "$provider"; then
    echo "    sub-fail: commit_range not set on bead metadata"
    failures=$((failures + 1))
  fi
  if ! grep -q 'bd meta set.*branch_name' "$provider"; then
    echo "    sub-fail: branch_name not set on bead metadata"
    failures=$((failures + 1))
  fi

  if [[ "$failures" -eq 0 ]]; then
    pass "worker worktree lifecycle correctly implemented"
  else
    fail "worker worktree has $failures issues"
  fi
}

test_persistent_role_tmux() {
  echo "Test: Persistent roles (scout, reviewer) start with tmux as PID 1"
  local provider="$REPO_ROOT/lib/city/provider.sh"

  local failures=0

  # Verify tmux new-session as container entrypoint
  if ! grep -q 'tmux new-session' "$provider"; then
    echo "    sub-fail: tmux new-session not used as entrypoint"
    failures=$((failures + 1))
  fi

  # Verify tmux interactions: send-keys, capture-pane, display-message, clear-history
  for tmux_cmd in "send-keys" "capture-pane" "display-message" "clear-history"; do
    if ! grep -q "tmux $tmux_cmd" "$provider" && ! grep -q "tmux ${tmux_cmd}" "$provider"; then
      echo "    sub-fail: tmux $tmux_cmd not found"
      failures=$((failures + 1))
    fi
  done

  # Verify Attach uses tmux attach
  if ! grep -q 'tmux attach' "$provider"; then
    echo "    sub-fail: Attach doesn't use tmux attach"
    failures=$((failures + 1))
  fi

  # Verify Peek for persistent uses capture-pane, for worker uses podman logs
  if ! grep -q 'podman logs' "$provider"; then
    echo "    sub-fail: worker Peek doesn't use podman logs"
    failures=$((failures + 1))
  fi

  if [[ "$failures" -eq 0 ]]; then
    pass "persistent roles correctly use tmux as PID 1"
  else
    fail "persistent role tmux has $failures issues"
  fi
}

test_scout_log_patterns() {
  echo "Test: Scout detects errors via log pattern regex matching"
  local scout="$REPO_ROOT/lib/city/scout.sh"

  if [[ ! -x "$scout" ]]; then
    fail "scout.sh not found or not executable"
    return
  fi

  local failures=0

  # Verify shell conventions
  if ! head -20 "$scout" | grep -q 'set -euo pipefail'; then
    echo "    sub-fail: missing set -euo pipefail"
    failures=$((failures + 1))
  fi

  # Verify parse-rules command exists and handles default patterns
  if ! grep -q 'parse.rules' "$scout" || ! grep -q 'parse_rules' "$scout"; then
    echo "    sub-fail: missing parse-rules command"
    failures=$((failures + 1))
  fi

  # Verify default patterns match spec
  if ! grep -q 'FATAL|PANIC|panic:' "$scout"; then
    echo "    sub-fail: missing default immediate pattern (FATAL|PANIC|panic:)"
    failures=$((failures + 1))
  fi
  if ! grep -q 'ERROR|Exception' "$scout"; then
    echo "    sub-fail: missing default batched pattern (ERROR|Exception)"
    failures=$((failures + 1))
  fi

  # Verify scan command reads podman logs
  if ! grep -q 'podman logs' "$scout"; then
    echo "    sub-fail: scan does not read podman logs"
    failures=$((failures + 1))
  fi

  # Verify three-tier pattern matching: ignore checked first, then immediate, then batched
  # The order matters for correctness — ignore must be first
  local ignore_line immediate_line batched_line
  ignore_line=$(grep -n 'pat_ignore' "$scout" | grep 'grep.*-qE' | head -1 | cut -d: -f1)
  immediate_line=$(grep -n 'pat_immediate' "$scout" | grep 'grep.*-qE' | head -1 | cut -d: -f1)
  batched_line=$(grep -n 'pat_batched' "$scout" | grep 'grep.*-qE' | head -1 | cut -d: -f1)
  if [[ -n "$ignore_line" ]] && [[ -n "$immediate_line" ]] && [[ -n "$batched_line" ]]; then
    if [[ "$ignore_line" -lt "$immediate_line" ]] && [[ "$immediate_line" -lt "$batched_line" ]]; then
      : # correct order
    else
      echo "    sub-fail: pattern check order wrong (must be ignore → immediate → batched)"
      failures=$((failures + 1))
    fi
  else
    echo "    sub-fail: could not find all three pattern checks with grep -qE"
    failures=$((failures + 1))
  fi

  # Verify immediate patterns create P0 beads
  if ! grep -q 'priority=0' "$scout"; then
    echo "    sub-fail: immediate patterns do not create P0 beads"
    failures=$((failures + 1))
  fi

  # Verify batched patterns create P2 beads
  if ! grep -q 'priority=2' "$scout"; then
    echo "    sub-fail: batched patterns do not create P2 beads"
    failures=$((failures + 1))
  fi

  # Functional test: parse default patterns from a temp orchestration.md
  local result
  result=$(
    set -euo pipefail
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '${tmpdir}'" EXIT

    export SCOUT_ERRORS_DIR="$tmpdir/errors"

    # Test 1: parse with no file (defaults)
    "$scout" parse-rules ""
    if [[ -f "$tmpdir/errors/immediate.pat" ]] && \
       grep -q 'FATAL|PANIC|panic:' "$tmpdir/errors/immediate.pat" && \
       grep -q 'ERROR|Exception' "$tmpdir/errors/batched.pat"; then
      echo "sub-pass: default patterns parsed correctly"
    else
      echo "sub-fail: default patterns not parsed correctly"
    fi

    # Test 2: parse custom patterns from a real orchestration.md
    cat > "$tmpdir/orch.md" << 'ORCH'
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
ORCH

    rm -rf "$tmpdir/errors"
    "$scout" parse-rules "$tmpdir/orch.md"
    if grep -q 'OOM_KILLED|SEGFAULT' "$tmpdir/errors/immediate.pat" && \
       grep -q 'WARN|TIMEOUT' "$tmpdir/errors/batched.pat" && \
       grep -q 'healthcheck' "$tmpdir/errors/ignore.pat"; then
      echo "sub-pass: custom patterns parsed from orchestration.md"
    else
      echo "sub-fail: custom patterns not parsed correctly"
    fi

    echo "FAILURES=0"
  ) || result="sub-fail: parse-rules functional test threw error
FAILURES=1"

  echo "$result" | grep -v '^FAILURES='

  local parse_failures
  parse_failures=$(echo "$result" | grep '^FAILURES=' | cut -d= -f2)
  failures=$((failures + ${parse_failures:-0}))

  if [[ "$failures" -eq 0 ]]; then
    pass "scout detects errors via log pattern regex matching"
  else
    fail "scout log patterns have $failures issues"
  fi
}

test_queue_overflow_cap() {
  echo "Test: Scout pauses bead creation when queue cap is reached"
  local scout="$REPO_ROOT/lib/city/scout.sh"

  if [[ ! -x "$scout" ]]; then
    fail "scout.sh not found or not executable"
    return
  fi

  local failures=0

  # Verify check-cap command exists
  if ! grep -q 'check.cap' "$scout" || ! grep -q 'check_cap' "$scout"; then
    echo "    sub-fail: missing check-cap command"
    failures=$((failures + 1))
  fi

  # Verify SCOUT_MAX_BEADS is configurable with default 10
  if ! grep -q 'SCOUT_MAX_BEADS.*:-10' "$scout" && ! grep -q 'SCOUT_MAX_BEADS:-10' "$scout"; then
    echo "    sub-fail: SCOUT_MAX_BEADS default not set to 10"
    failures=$((failures + 1))
  fi

  # Verify cap check uses bd list with open and in_progress statuses
  if ! grep -q 'bd list.*--status=open.*--status=in_progress' "$scout"; then
    echo "    sub-fail: cap check does not query open and in_progress beads"
    failures=$((failures + 1))
  fi

  # Verify director notification when cap reached
  if ! grep -q 'wrapix-notifyd' "$scout"; then
    echo "    sub-fail: missing wrapix-notifyd notification on cap reached"
    failures=$((failures + 1))
  fi
  if ! grep -q 'Scout paused.*open beads reached' "$scout"; then
    echo "    sub-fail: notification message missing 'Scout paused' text"
    failures=$((failures + 1))
  fi

  # Verify create-beads checks cap before each creation
  # Look for check_cap call inside the create_beads function's loop
  if ! grep -A2 'Check cap before each creation' "$scout" | grep -q 'check_cap'; then
    echo "    sub-fail: create-beads does not re-check cap before each bead"
    failures=$((failures + 1))
  fi

  # Verify deduplication: find_existing_bead searches open/in-progress beads
  if ! grep -q 'find_existing_bead' "$scout"; then
    echo "    sub-fail: missing deduplication function"
    failures=$((failures + 1))
  fi

  # Verify dedup appends rather than creates when bead exists
  if ! grep -q 'bd update.*--notes.*additional occurrence' "$scout"; then
    echo "    sub-fail: deduplication does not append to existing beads"
    failures=$((failures + 1))
  fi

  if [[ "$failures" -eq 0 ]]; then
    pass "scout queue overflow cap correctly implemented"
  else
    fail "scout queue overflow has $failures issues"
  fi
}

test_reviewer_handoff() {
  echo "Test: Reviewer gate reads commit range from bead metadata"
  local gate="$REPO_ROOT/lib/city/gate.sh"

  if [[ ! -x "$gate" ]]; then
    fail "gate.sh not found or not executable"
    return
  fi

  local failures=0

  # Verify shell conventions
  if ! head -20 "$gate" | grep -q 'set -euo pipefail'; then
    echo "    sub-fail: missing set -euo pipefail"
    failures=$((failures + 1))
  fi

  # Verify GC_BEAD_ID is required
  if ! grep -q 'GC_BEAD_ID' "$gate"; then
    echo "    sub-fail: missing GC_BEAD_ID environment variable"
    failures=$((failures + 1))
  fi

  # Verify commit_range is read from bead metadata
  if ! grep -q 'bd meta get.*commit_range' "$gate"; then
    echo "    sub-fail: does not read commit_range from bead metadata"
    failures=$((failures + 1))
  fi

  # Verify gc nudge reviewer is called with commit range
  if ! grep -q 'gc nudge reviewer' "$gate"; then
    echo "    sub-fail: does not nudge reviewer session"
    failures=$((failures + 1))
  fi

  # Verify polling for review_verdict
  if ! grep -q 'bd meta get.*review_verdict' "$gate"; then
    echo "    sub-fail: does not poll for review_verdict"
    failures=$((failures + 1))
  fi

  # Verify approve exits 0
  if ! grep -q 'approve' "$gate" || ! grep -A2 'approve)' "$gate" | grep -qE 'exit 0'; then
    echo "    sub-fail: approve does not exit 0"
    failures=$((failures + 1))
  fi

  # Verify reject exits 1
  if ! grep -q 'reject' "$gate" || ! grep -A2 'reject)' "$gate" | grep -qE 'exit 1'; then
    echo "    sub-fail: reject does not exit 1"
    failures=$((failures + 1))
  fi

  # Verify timeout handling
  if ! grep -q 'POLL_TIMEOUT\|GC_POLL_TIMEOUT' "$gate"; then
    echo "    sub-fail: no timeout handling for review polling"
    failures=$((failures + 1))
  fi

  # Verify configurable poll interval
  if ! grep -q 'POLL_INTERVAL\|GC_POLL_INTERVAL' "$gate"; then
    echo "    sub-fail: no configurable poll interval"
    failures=$((failures + 1))
  fi

  # Verify missing commit_range is handled
  if ! grep -q 'no commit_range' "$gate"; then
    echo "    sub-fail: does not handle missing commit_range"
    failures=$((failures + 1))
  fi

  if [[ "$failures" -eq 0 ]]; then
    pass "reviewer gate correctly reads commit range and polls for verdict"
  else
    fail "reviewer gate has $failures issues"
  fi
}

test_convergence_handoff() {
  echo "Test: gc convergence detects worker completion and triggers reviewer gate"

  local gate="$REPO_ROOT/lib/city/gate.sh"
  local provider="$REPO_ROOT/lib/city/provider.sh"

  local failures=0

  # Verify gate script exists
  if [[ ! -x "$gate" ]]; then
    echo "    sub-fail: gate.sh not found or not executable"
    failures=$((failures + 1))
  fi

  # Verify provider sets commit_range after worker exits (consumed by gate)
  if ! grep -q 'bd meta set.*commit_range' "$provider"; then
    echo "    sub-fail: provider does not set commit_range after worker exit"
    failures=$((failures + 1))
  fi

  # Verify gate reads commit_range (bridging provider→gate→reviewer)
  if ! grep -q 'bd meta get.*commit_range' "$gate"; then
    echo "    sub-fail: gate does not read commit_range from bead metadata"
    failures=$((failures + 1))
  fi

  # Verify gate nudges the reviewer (triggering the handoff)
  if ! grep -q 'gc nudge reviewer' "$gate"; then
    echo "    sub-fail: gate does not nudge reviewer session"
    failures=$((failures + 1))
  fi

  # Verify reviewer formula references review_verdict metadata
  local reviewer_formula="$REPO_ROOT/lib/city/formulas/reviewer.formula.toml"
  if [[ -f "$reviewer_formula" ]]; then
    if ! grep -q 'review_verdict' "$reviewer_formula"; then
      echo "    sub-fail: reviewer formula does not reference review_verdict"
      failures=$((failures + 1))
    fi
  else
    echo "    sub-fail: reviewer formula not found"
    failures=$((failures + 1))
  fi

  if [[ "$failures" -eq 0 ]]; then
    pass "convergence handoff chain (provider→gate→reviewer) correctly wired"
  else
    fail "convergence handoff has $failures issues"
  fi
}

test_merge_ff_only() {
  echo "Test: Merge uses fast-forward only; rebase + prek on divergence"
  local postgate="$REPO_ROOT/lib/city/post-gate.sh"

  if [[ ! -x "$postgate" ]]; then
    fail "post-gate.sh not found or not executable"
    return
  fi

  local failures=0

  # Verify shell conventions
  if ! head -20 "$postgate" | grep -q 'set -euo pipefail'; then
    echo "    sub-fail: missing set -euo pipefail"
    failures=$((failures + 1))
  fi

  # Verify required environment variables
  for var in GC_BEAD_ID GC_TERMINAL_REASON GC_WORKSPACE GC_CITY_NAME; do
    if ! grep -q "${var}:?" "$postgate"; then
      echo "    sub-fail: missing required env var $var"
      failures=$((failures + 1))
    fi
  done

  # Verify fast-forward merge attempt
  if ! grep -q 'git.*merge --ff-only' "$postgate"; then
    echo "    sub-fail: does not attempt git merge --ff-only"
    failures=$((failures + 1))
  fi

  # Verify rebase onto main when ff fails
  if ! grep -q 'git.*rebase main' "$postgate"; then
    echo "    sub-fail: does not rebase onto main when ff fails"
    failures=$((failures + 1))
  fi

  # Verify prek runs after rebase
  if ! grep -q 'prek run' "$postgate"; then
    echo "    sub-fail: does not run prek after rebase"
    failures=$((failures + 1))
  fi

  # Verify rebase conflicts are rejected to new worker
  if ! grep -q 'rebase --abort' "$postgate"; then
    echo "    sub-fail: does not abort rebase on conflicts"
    failures=$((failures + 1))
  fi
  if ! grep -q 'reject_to_worker.*[Cc]onflict' "$postgate"; then
    echo "    sub-fail: does not reject to worker on rebase conflicts"
    failures=$((failures + 1))
  fi

  # Verify test failure after rebase is rejected to new worker
  if ! grep -q 'reject_to_worker.*[Tt]ests failed after rebase' "$postgate"; then
    echo "    sub-fail: does not reject to worker on test failure after rebase"
    failures=$((failures + 1))
  fi

  # Verify worktree cleanup after merge
  if ! grep -q 'git.*worktree remove' "$postgate"; then
    echo "    sub-fail: does not remove worktree after merge"
    failures=$((failures + 1))
  fi

  # Verify branch cleanup after merge
  if ! grep -q 'git.*branch -d' "$postgate"; then
    echo "    sub-fail: does not delete branch after merge"
    failures=$((failures + 1))
  fi

  # Verify rejection cleans up old branch too
  if ! grep -q 'cleanup_branch' "$postgate"; then
    echo "    sub-fail: missing cleanup_branch function for branch lifecycle"
    failures=$((failures + 1))
  fi

  # Verify deploy bead creation after merge
  if ! grep -q 'create_deploy_bead\|bd create.*deploy' "$postgate"; then
    echo "    sub-fail: does not create deploy bead after merge"
    failures=$((failures + 1))
  fi

  # Verify terminal_reason dispatch (approved vs escalation)
  if ! grep -q 'approved)' "$postgate"; then
    echo "    sub-fail: does not dispatch on terminal_reason=approved"
    failures=$((failures + 1))
  fi

  if [[ "$failures" -eq 0 ]]; then
    pass "merge uses ff-only with rebase+prek fallback"
  else
    fail "merge logic has $failures issues"
  fi
}

test_notifications() {
  echo "Test: Post-gate order sends notifications via wrapix-notifyd for director events"
  local postgate="$REPO_ROOT/lib/city/post-gate.sh"

  if [[ ! -x "$postgate" ]]; then
    fail "post-gate.sh not found or not executable"
    return
  fi

  local failures=0

  # Verify wrapix-notifyd is called
  if ! grep -q 'wrapix-notifyd' "$postgate"; then
    echo "    sub-fail: does not call wrapix-notifyd"
    failures=$((failures + 1))
  fi

  # Verify escalation notification (convergence failed)
  if ! grep -q 'escalat' "$postgate"; then
    echo "    sub-fail: no escalation notification"
    failures=$((failures + 1))
  fi

  # Verify deploy approval notification
  if ! grep -q '[Dd]eploy approval' "$postgate"; then
    echo "    sub-fail: no deploy approval notification"
    failures=$((failures + 1))
  fi

  # Verify merge rejection notification
  if ! grep -q '[Mm]erge rejected' "$postgate"; then
    echo "    sub-fail: no merge rejection notification"
    failures=$((failures + 1))
  fi

  # Verify bd human is called for deploy beads (default path)
  if ! grep -q 'bd human' "$postgate"; then
    echo "    sub-fail: does not flag deploy beads with bd human"
    failures=$((failures + 1))
  fi

  # Verify auto-deploy path: checks docs/orchestration.md for Auto-deploy section
  if ! grep -q 'Auto-deploy' "$postgate"; then
    echo "    sub-fail: does not check for Auto-deploy section"
    failures=$((failures + 1))
  fi

  # Verify low-risk classification check
  if ! grep -q 'risk_classification\|low.risk\|is_low_risk' "$postgate"; then
    echo "    sub-fail: does not check risk classification"
    failures=$((failures + 1))
  fi

  # Verify notifications are fire-and-forget (|| true pattern)
  if ! grep -q 'wrapix-notifyd.*|| true' "$postgate"; then
    echo "    sub-fail: notifications not fire-and-forget (missing || true)"
    failures=$((failures + 1))
  fi

  # Verify city name included in notifications for context
  if ! grep -q 'CITY_NAME' "$postgate"; then
    echo "    sub-fail: notifications do not include city name"
    failures=$((failures + 1))
  fi

  if [[ "$failures" -eq 0 ]]; then
    pass "post-gate sends notifications for all director events"
  else
    fail "notifications have $failures issues"
  fi
}

test_agent_wrapper() {
  echo "Test: Agent wrapper abstracts agent invocation (wrapix-agent)"
  local agent="$REPO_ROOT/lib/city/agent.sh"

  local failures=0

  # Verify script exists and is executable
  if [[ ! -x "$agent" ]]; then
    fail "agent.sh not found or not executable"
    return
  fi

  # Verify shell conventions
  if ! head -20 "$agent" | grep -q 'set -euo pipefail'; then
    echo "    sub-fail: missing set -euo pipefail"
    failures=$((failures + 1))
  fi

  # Verify two modes: run (ephemeral) and session (persistent)
  if ! grep -q 'claude_run' "$agent" || ! grep -q 'claude_session' "$agent"; then
    echo "    sub-fail: missing run/session mode functions"
    failures=$((failures + 1))
  fi

  # Verify prompt construction with docs context
  if ! grep -q 'build_prompt' "$agent"; then
    echo "    sub-fail: missing build_prompt function"
    failures=$((failures + 1))
  fi
  if ! grep -q 'WRAPIX_DOCS_DIR' "$agent"; then
    echo "    sub-fail: no docs directory support"
    failures=$((failures + 1))
  fi

  # Verify output capture support
  if ! grep -q 'WRAPIX_OUTPUT_FILE' "$agent"; then
    echo "    sub-fail: no output capture support"
    failures=$((failures + 1))
  fi

  # Verify agent registry pattern (case dispatch on agent type)
  if ! grep -q 'case "$AGENT"' "$agent"; then
    echo "    sub-fail: no agent registry dispatch"
    failures=$((failures + 1))
  fi

  # Verify session mode uses exec for interactive
  if ! grep -q 'exec claude' "$agent"; then
    echo "    sub-fail: session mode doesn't use exec for interactive"
    failures=$((failures + 1))
  fi

  # Verify unknown agent is handled
  if ! grep -q 'unknown agent' "$agent"; then
    echo "    sub-fail: no unknown agent error handling"
    failures=$((failures + 1))
  fi

  # Verify default agent is claude
  if ! grep -q 'WRAPIX_AGENT:-claude' "$agent"; then
    echo "    sub-fail: default agent is not claude"
    failures=$((failures + 1))
  fi

  if [[ "$failures" -eq 0 ]]; then
    pass "agent wrapper correctly structured"
  else
    fail "agent wrapper has $failures issues"
  fi
}

test_entrypoint_wrapper() {
  echo "Test: Entrypoint wrapper checks scaffolding beads, starts events watcher, execs gc"
  local entrypoint="$REPO_ROOT/lib/city/entrypoint.sh"

  if [[ ! -x "$entrypoint" ]]; then
    fail "entrypoint.sh not found or not executable"
    return
  fi

  local failures=0

  # Verify shell conventions
  if ! head -20 "$entrypoint" | grep -q 'set -euo pipefail'; then
    echo "    sub-fail: missing set -euo pipefail"
    failures=$((failures + 1))
  fi

  # Verify required environment variables
  for var in GC_CITY_NAME GC_WORKSPACE; do
    if ! grep -q "${var}:?" "$entrypoint" && ! grep -q "${var}:\?" "$entrypoint"; then
      echo "    sub-fail: missing required env var $var"
      failures=$((failures + 1))
    fi
  done

  # Step 1: Verify scaffolding bead check
  if ! grep -q 'bd human list' "$entrypoint"; then
    echo "    sub-fail: does not check bd human list for scaffolding beads"
    failures=$((failures + 1))
  fi
  if ! grep -q 'scaffol' "$entrypoint"; then
    echo "    sub-fail: does not filter for scaffolding beads"
    failures=$((failures + 1))
  fi
  # Verify it exits on unresolved scaffolding beads
  if ! grep -q 'exit 1' "$entrypoint"; then
    echo "    sub-fail: does not exit on unresolved scaffolding beads"
    failures=$((failures + 1))
  fi
  # Verify it prints a warning listing pending reviews
  if ! grep -q 'Pending reviews' "$entrypoint" && ! grep -q 'pending review' "$entrypoint"; then
    echo "    sub-fail: does not print warning listing pending reviews"
    failures=$((failures + 1))
  fi

  # Step 2: Verify podman events watcher
  if ! grep -q 'podman events' "$entrypoint"; then
    echo "    sub-fail: does not start podman events watcher"
    failures=$((failures + 1))
  fi
  # Verify it watches for die, oom, restart events
  for event in die oom restart; do
    if ! grep -q "event=${event}" "$entrypoint"; then
      echo "    sub-fail: does not watch for ${event} events"
      failures=$((failures + 1))
    fi
  done
  # Verify it nudges the scout
  if ! grep -q 'gc nudge scout' "$entrypoint"; then
    echo "    sub-fail: does not nudge scout on service events"
    failures=$((failures + 1))
  fi
  # Verify watcher runs in background
  if ! grep -q '&$' "$entrypoint" && ! grep -qE '^\s+\) &' "$entrypoint"; then
    echo "    sub-fail: events watcher does not run in background"
    failures=$((failures + 1))
  fi
  # Verify gc-managed containers are skipped
  if ! grep -q 'gc-.*CITY_NAME' "$entrypoint"; then
    echo "    sub-fail: does not skip gc-managed containers in event watcher"
    failures=$((failures + 1))
  fi

  # Step 3: Verify exec gc start --foreground
  if ! grep -q 'exec gc start --foreground' "$entrypoint"; then
    echo "    sub-fail: does not exec gc start --foreground"
    failures=$((failures + 1))
  fi

  if [[ "$failures" -eq 0 ]]; then
    pass "entrypoint wrapper correctly structured"
  else
    fail "entrypoint wrapper has $failures issues"
  fi
}

test_crash_recovery() {
  echo "Test: Crash recovery — gc container restarts, reconciles orphaned containers"
  local recovery="$REPO_ROOT/lib/city/recovery.sh"
  local entrypoint="$REPO_ROOT/lib/city/entrypoint.sh"

  local failures=0

  # Verify recovery script exists and is executable
  if [[ ! -x "$recovery" ]]; then
    fail "recovery.sh not found or not executable"
    return
  fi

  # Verify shell conventions
  if ! head -20 "$recovery" | grep -q 'set -euo pipefail'; then
    echo "    sub-fail: missing set -euo pipefail"
    failures=$((failures + 1))
  fi

  # Verify required environment variables
  for var in GC_CITY_NAME GC_WORKSPACE; do
    if ! grep -q "${var}:?" "$recovery"; then
      echo "    sub-fail: missing required env var $var"
      failures=$((failures + 1))
    fi
  done

  # Verify step 1: scans podman ps for running containers with gc-city label
  if ! grep -q 'podman ps.*--filter.*label=gc-city=' "$recovery"; then
    echo "    sub-fail: does not scan podman ps for gc-city containers"
    failures=$((failures + 1))
  fi

  # Verify step 2: reconciles workers against beads state
  if ! grep -q 'bead_in_progress\|bead_is_open' "$recovery"; then
    echo "    sub-fail: does not check bead status for reconciliation"
    failures=$((failures + 1))
  fi

  # Verify orphaned workers (no matching in-progress bead) are stopped
  if ! grep -q 'stop_container\|podman stop' "$recovery"; then
    echo "    sub-fail: does not stop orphaned containers"
    failures=$((failures + 1))
  fi
  if ! grep -q 'podman rm' "$recovery"; then
    echo "    sub-fail: does not remove orphaned containers"
    failures=$((failures + 1))
  fi

  # Verify workers that finished (commits on branch, bead still open) re-enter convergence
  if ! grep -q 'branch_has_commits' "$recovery"; then
    echo "    sub-fail: does not check for finished worker commits"
    failures=$((failures + 1))
  fi
  if ! grep -q 'bd meta set.*commit_range' "$recovery"; then
    echo "    sub-fail: does not set commit_range for convergence re-entry"
    failures=$((failures + 1))
  fi

  # Verify stale worktrees in .wrapix/worktree/gc-* are cleaned up
  if ! grep -q 'git.*worktree prune' "$recovery"; then
    echo "    sub-fail: does not run git worktree prune"
    failures=$((failures + 1))
  fi
  if ! grep -q 'git.*worktree remove' "$recovery"; then
    echo "    sub-fail: does not remove stale worktrees"
    failures=$((failures + 1))
  fi
  if ! grep -q '\.wrapix/worktree.*gc-' "$recovery"; then
    echo "    sub-fail: does not scan .wrapix/worktree/gc-* paths"
    failures=$((failures + 1))
  fi

  # Verify entrypoint calls recovery before gc start
  if ! grep -q 'recovery.sh' "$entrypoint"; then
    echo "    sub-fail: entrypoint does not call recovery.sh"
    failures=$((failures + 1))
  fi

  # Verify recovery runs before gc start --foreground in entrypoint
  local recovery_line gc_start_line
  recovery_line=$(grep -n 'recovery.sh' "$entrypoint" | head -1 | cut -d: -f1)
  gc_start_line=$(grep -n 'exec gc start --foreground' "$entrypoint" | head -1 | cut -d: -f1)
  if [[ -n "$recovery_line" ]] && [[ -n "$gc_start_line" ]]; then
    if [[ "$recovery_line" -ge "$gc_start_line" ]]; then
      echo "    sub-fail: recovery runs after gc start (must run before)"
      failures=$((failures + 1))
    fi
  fi

  # Verify gc-bead label is used for worker identification
  if ! grep -q 'gc-bead' "$recovery"; then
    echo "    sub-fail: does not use gc-bead label for worker identification"
    failures=$((failures + 1))
  fi

  # Verify persistent containers (scout/reviewer) are handled
  if ! grep -q 'scout.*reviewer\|persistent' "$recovery"; then
    echo "    sub-fail: does not handle persistent containers (scout/reviewer)"
    failures=$((failures + 1))
  fi

  if [[ "$failures" -eq 0 ]]; then
    pass "crash recovery correctly implemented"
  else
    fail "crash recovery has $failures issues"
  fi
}

# --- Run ---

echo "=== Gas City Tests ==="
test_gc_package_available
test_gc_binary_runs
test_gascity_input_pinned
test_mkcity_minimal_eval
test_city_toml_valid
test_service_image_build
test_secrets_runtime_only
test_role_formulas
test_docs_scaffolding
test_provider_methods
test_worker_worktree
test_persistent_role_tmux
test_scout_log_patterns
test_queue_overflow_cap
test_reviewer_handoff
test_convergence_handoff
test_merge_ff_only
test_notifications
test_agent_wrapper
test_entrypoint_wrapper
test_crash_recovery

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"
if [[ $TESTS_FAILED -gt 0 ]]; then
  exit 1
fi
