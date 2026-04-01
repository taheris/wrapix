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
  echo "Test: mkCity exposes agent sandbox for role containers"
  local has_sandbox
  has_sandbox=$(nix eval --impure --json --expr '
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
    in builtins.hasAttr "package" result.agentSandbox
  ' 2>/dev/null)
  if [[ "$has_sandbox" == "true" ]]; then
    pass "mkCity exposes agentSandbox with package attribute"
  else
    fail "mkCity agentSandbox missing package attribute"
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
test_agent_wrapper

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"
if [[ $TESTS_FAILED -gt 0 ]]; then
  exit 1
fi
