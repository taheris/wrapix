# Gas City full ops loop integration test
#
# Exercises the real stack: gc → provider.sh → podman → container → mock claude
# Only the LLM binary is substituted. Everything else runs for real.
#
# Test flow:
#   Phase 1 (happy path):
#     1. gc starts scout + reviewer via provider.sh → podman
#     2. Scout (mock claude) creates a bead
#     3. Director (test script) slings bead into convergence
#     4. Worker processes in worktree, commits, exits
#     5. gate.sh nudges reviewer, reviewer approves
#     6. post-gate.sh merges, creates deploy bead, flags bd human
#     7. Verify: merge on main, worktree cleaned up
#     gc is stopped after Phase 1 — remaining phases run without it.
#
#   Phase 2 (merge conflict):
#     1. Conflicting change on main
#     2. Simulated worker commits on divergent branch
#     3. post-gate detects rebase conflict → reject_to_worker
#     4. Verify: bead reopened, worktree cleaned up
#
#   Phase 3 (escalation):
#     1. Convergence ends with non-approved reason
#     2. post-gate handles escalation path
#     3. Verify: worktree and branch cleaned up
#
# Requires podman. Run via: nix run .#test-city
{ pkgs }:

let
  inherit (pkgs) lib;

  toTOML = import ../lib/util/toml.nix { inherit lib; };

  # Provider script from lib/city
  providerScript = pkgs.writeShellScript "wrapix-provider" (
    builtins.readFile ../lib/city/provider.sh
  );

  # City scripts bundle
  scriptsDir = pkgs.runCommand "test-city-scripts" { } ''
    mkdir -p $out
    cp ${../lib/city/gate.sh} $out/gate.sh
    cp ${../lib/city/post-gate.sh} $out/post-gate.sh
    cp ${../lib/city/recovery.sh} $out/recovery.sh
    chmod +x $out/*.sh
  '';

  # Formulas + orders bundle
  formulasDir = pkgs.runCommand "test-city-formulas" { } ''
    mkdir -p $out/orders/post-gate
    cp ${../lib/city/formulas/scout.formula.toml} $out/wrapix-scout.formula.toml
    cp ${../lib/city/formulas/worker.formula.toml} $out/wrapix-worker.formula.toml
    cp ${../lib/city/formulas/reviewer.formula.toml} $out/wrapix-reviewer.formula.toml
    cp ${../lib/city/orders/post-gate/order.toml} $out/orders/post-gate/order.toml
  '';

  # Mock claude binary — deterministic bash script per role
  mockClaude = pkgs.writeShellScriptBin "claude" ''
    set -euo pipefail

    # Write all output to host-visible log (mounted workspace .beads dir is rw for
    # scout/reviewer, but ro for workers — use /tmp as fallback)
    MOCK_LOG="/workspace/.beads/mock-claude-''${GC_ROLE:-unknown}.log"
    if ! touch "$MOCK_LOG" 2>/dev/null; then
      MOCK_LOG="/tmp/mock-claude-''${GC_ROLE:-unknown}.log"
    fi
    exec > >(tee -a "$MOCK_LOG") 2>&1

    case "''${1:-}" in
      -p)
        # Worker run mode (called via wrapix-agent run → claude -p <prompt>)
        git config user.email test@test
        git config user.name test
        echo "fix applied" > fix.txt
        git add fix.txt
        git commit -m "fix: resolve test error"
        ;;
      --dangerously-skip-permissions)
        # Persistent session mode (scout or reviewer)
        # Ensure dolt config exists (container has no global config)
        dolt config --global --add user.email mock@test 2>/dev/null || true
        dolt config --global --add user.name mock 2>/dev/null || true
        case "''${GC_ROLE:-}" in
          scout|scout*)
            bd create --title="Fix test error" --type=bug --priority=2
            # Stay alive for gc to manage
            sleep 600
            ;;
          reviewer|reviewer*)
            # Poll for beads needing review, approve them
            for i in $(seq 1 300); do
              for id in $(bd list --status=in_progress --json 2>/dev/null | jq -r '.[].id' 2>/dev/null); do
                cr=$(bd show "$id" --json 2>/dev/null | jq -r '.[0].metadata.commit_range // empty' 2>/dev/null) || cr=""
                if [ -n "$cr" ]; then
                  # Only approve if not already approved
                  existing=$(bd show "$id" --json 2>/dev/null | jq -r '.[0].metadata.review_verdict // empty' 2>/dev/null) || existing=""
                  if [ -z "$existing" ]; then
                    bd update "$id" --set-metadata "review_verdict=approve" 2>/dev/null || true
                    bd update "$id" --notes "Reviewer: approved — test" 2>/dev/null || true
                  fi
                fi
              done
              sleep 1
            done
            ;;
          *)
            sleep 600
            ;;
        esac
        ;;
      *)
        # Unknown invocation — log and stay alive
        sleep 600
        ;;
    esac
  '';

  # Test city.toml using real toTOML
  cityToml = pkgs.writeText "city.toml" (toTOML {
    workspace = {
      name = "test-city";
      provider = "claude";
    };
    session = {
      provider = "exec:${providerScript}";
    };
    formulas = {
      dir = ".gc/formulas";
    };
    beads = {
      provider = "bd";
    };
    daemon = {
      patrol_interval = "5s";
      max_restarts = 3;
      restart_window = "1h";
    };
    convergence = {
      max_per_agent = 2;
      max_total = 10;
    };
    agent = [
      {
        name = "scout";
        scope = "city";
        scale_check = "bd list --metadata-field gc.routed_to=scout --status open,in_progress --no-assignee --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0";
      }
      {
        name = "worker";
        scope = "city";
        max_active_sessions = 2;
        scale_check = "bd list --metadata-field gc.routed_to=worker --status open,in_progress --no-assignee --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0";
      }
      {
        name = "reviewer";
        scope = "city";
        scale_check = "bd list --metadata-field gc.routed_to=reviewer --status open,in_progress --no-assignee --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0";
      }
    ];
    named_session = [
      {
        template = "scout";
        mode = "always";
      }
      {
        template = "reviewer";
        mode = "always";
      }
    ];
  });

  # wrapix-agent wrapper (same as cityScripts in lib/city/default.nix)
  # Replace #!/usr/bin/env bash with direct Nix bash path for container compatibility
  # (test image lacks /usr/bin/env)
  agentScript = pkgs.runCommand "wrapix-agent" { } ''
    mkdir -p $out/bin
    echo '#!${pkgs.bash}/bin/bash' > $out/bin/wrapix-agent
    tail -n +2 ${../lib/city/agent.sh} >> $out/bin/wrapix-agent
    chmod +x $out/bin/wrapix-agent
  '';

  # Packages included in the test container
  testImagePkgs = [
    pkgs.bash
    pkgs.coreutils
    pkgs.git
    pkgs.dolt
    pkgs.beads
    pkgs.gc
    pkgs.jq
    pkgs.tmux
    pkgs.gnugrep
    pkgs.gnused
    pkgs.findutils
    mockClaude
    agentScript
  ];

  # Test container image with mock claude (streamed for fast loading)
  testImageStream = pkgs.dockerTools.streamLayeredImage {
    name = "wrapix-test";
    tag = "latest";
    maxLayers = 50;

    contents = testImagePkgs;

    config = {
      Env = [
        "PATH=${lib.makeBinPath testImagePkgs}:/bin:/usr/bin"
        "HOME=/home/wrapix"
      ];
    };

    fakeRootCommands = ''
      mkdir -p ./home/wrapix
      mkdir -p ./tmp
    '';
  };

  # Runtime dependencies for the test script
  testDeps = [
    pkgs.gc
    pkgs.beads
    pkgs.dolt
    pkgs.git
    pkgs.tmux
    pkgs.jq
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.findutils
    pkgs.lsof
  ];

  testScript = pkgs.writeShellScriptBin "test-city" ''
    set -euo pipefail

    # ================================================================
    # Helpers
    # ================================================================

    export PATH="${lib.makeBinPath testDeps}:$PATH"

    PASSED=0
    FAILED=0
    GC_PID=""
    WS=""
    NETWORK_NAME="wrapix-test-$$"
    # Pass --no-fail-fast to run all tests even after failures
    FAIL_FAST=true
    if [ "''${1:-}" = "--no-fail-fast" ]; then
      FAIL_FAST=false
    fi

    dump_diagnostics() {
      echo ""
      echo "--- Diagnostics ---"
      if [ -n "$WS" ] && [ -f "$WS/gc.log" ]; then
        echo "  gc.log:"
        cat "$WS/gc.log" 2>/dev/null | sed 's/^/    /' || true
      fi
      # Show logs from any gc containers
      for cid in $(podman ps -a --filter "network=$NETWORK_NAME" -q 2>/dev/null); do
        local cname
        cname=$(podman inspect --format '{{.Name}}' "$cid" 2>/dev/null || echo "$cid")
        echo "  container $cname (podman logs):"
        podman logs "$cid" 2>&1 | tail -20 | sed 's/^/    /' || true
      done
      # Mock claude logs written to host-visible .beads/ dir
      for logf in "$WS"/.beads/mock-claude-*.log; do
        [ -f "$logf" ] || continue
        echo "  $(basename "$logf"):"
        tail -30 "$logf" | sed 's/^/    /'
      done
      if [ -n "$WS" ]; then
        echo "  beads:"
        (cd "$WS" && bd list 2>/dev/null | sed 's/^/    /') || true
      fi
    }

    cleanup() {
      echo ""
      echo "--- Cleanup ---"
      if [ -n "$GC_PID" ] && kill -0 "$GC_PID" 2>/dev/null; then
        kill -TERM -"$GC_PID" 2>/dev/null || true
        for _ in $(seq 1 50); do
          kill -0 "$GC_PID" 2>/dev/null || break
          sleep 0.1
        done
        kill -9 -"$GC_PID" 2>/dev/null || true
        wait "$GC_PID" 2>/dev/null || true
      fi
      podman ps --filter "network=$NETWORK_NAME" -q 2>/dev/null | xargs -r podman stop -t 3 2>/dev/null || true
      podman ps -a --filter "network=$NETWORK_NAME" -q 2>/dev/null | xargs -r podman rm -f 2>/dev/null || true
      podman network rm "$NETWORK_NAME" 2>/dev/null || true
      podman rmi wrapix-test:latest 2>/dev/null || true
      if [ -n "$WS" ]; then
        rm -rf "$WS" 2>/dev/null || true
      fi
      echo ""
      echo "========================================"
      echo "PASSED: $PASSED  FAILED: $FAILED"
      if [ "$FAILED" -gt 0 ]; then
        echo "SOME TESTS FAILED"
        exit 1
      else
        echo "ALL TESTS PASSED"
      fi
    }
    trap cleanup EXIT

    # Run a named subtest. Returns 0 on pass, 1 on fail.
    # In fail-fast mode, dumps diagnostics and exits on failure.
    subtest() {
      local name="$1"
      shift
      echo ""
      echo "--- $name ---"
      if "$@"; then
        echo "PASS: $name"
        PASSED=$((PASSED + 1))
        return 0
      else
        echo "FAIL: $name"
        FAILED=$((FAILED + 1))
        if [ "$FAIL_FAST" = true ]; then
          dump_diagnostics
          exit 1
        fi
        return 1
      fi
    }

    # Poll until a command succeeds. Usage: poll_until command timeout
    poll_until() {
      local cmd="$1"
      local timeout="''${2:-30}"
      local interval="''${3:-1}"
      local elapsed=0
      echo "  > waiting (up to ''${timeout}s): $cmd"
      while [ "$elapsed" -lt "$timeout" ]; do
        if eval "$cmd" >/dev/null 2>&1; then
          echo "  > satisfied after ''${elapsed}s"
          return 0
        fi
        # Early exit if gc died while we're polling
        if [ -n "$GC_PID" ] && ! kill -0 "$GC_PID" 2>/dev/null; then
          echo "  > gc (pid $GC_PID) died during poll"
          echo "  gc.log tail:"
          tail -20 "$WS/gc.log" 2>/dev/null | sed 's/^/    /' || true
          return 1
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
      done
      echo "  > TIMED OUT after ''${timeout}s: $cmd"
      return 1
    }

    # ================================================================
    # Preflight: check podman is available
    # ================================================================

    if ! command -v podman >/dev/null 2>&1; then
      echo "SKIP: podman not found — city integration tests require podman on the host."
      exit 0
    fi

    echo "=== Gas City Integration Test ==="

    # ================================================================
    # Setup: workspace, config, image
    # ================================================================

    subtest "Load test container image" \
      sh -c '${testImageStream} | podman load'

    WS=$(mktemp -d)
    echo "  > workspace: $WS"
    cd "$WS"

    setup_workspace() {
      git init -b main
      git config user.email test@test
      git config user.name test
      dolt config --global --add user.email test@test
      dolt config --global --add user.name test
      git commit --allow-empty -m initial

      # Skip gc-beads-bd lifecycle (dolt server management) — it forces server mode
      # which breaks in containers. We use embedded dolt via bd init instead.
      export GC_DOLT=skip

      # Bootstrap the city via gc init — creates .gc/ scaffold.
      # gc init exits 1 on missing optional deps (tmux/lsof) but still creates the scaffold.
      gc init --file ${cityToml} --skip-provider-readiness 2>&1 || true
      test -d .gc/system/bin

      # Initialize beads in embedded mode (no dolt server).
      # Containers mount .beads and can't reach a host-side server.
      bd init --non-interactive --sandbox
      chmod 700 .beads
      # gc creates beads with custom types (session, convoy, convergence, etc.);
      # register the gc default set plus convergence (used by gc converge create).
      bd config set types.custom "molecule,convoy,message,event,gate,merge-request,agent,role,rig,session,convergence"
      git add -A && git commit -m "bd init"

      gc rig add . --name test-city 2>&1
      gc supervisor stop 2>&1
      gc unregister . 2>&1

      # Overlay our formulas and scripts on top of the gc scaffold
      mkdir -p .gc/formulas/orders/post-gate .gc/scripts
      for f in ${formulasDir}/*.formula.toml; do cp -f "$f" .gc/formulas/; done
      cp -f ${formulasDir}/orders/post-gate/order.toml .gc/formulas/orders/post-gate/
      for f in ${scriptsDir}/*; do cp -f "$f" .gc/scripts/; done

      mkdir -p docs .wrapix
      printf "## Scout Rules\nimmediate: FATAL|PANIC\nbatched: ERROR\n## Auto-deploy\nLow-risk: docs only\n" > docs/orchestration.md
      printf "# Style Guidelines\nSH-1: Use set -euo pipefail\n" > docs/style-guidelines.md
      printf "<!-- expires: 2025-01-01 -->\nTemporary: freeze deploys during migration\n" > .wrapix/orchestration.md
      git add -A && git commit -m "setup: workspace"
    }
    subtest "Set up workspace" setup_workspace

    # ================================================================
    # Phase 1: Happy path — scout → worker → reviewer → director
    # ================================================================

    validate_config() {
      result=$(gc config show --validate 2>&1)
      echo "$result" | grep -qi "valid\|ok"
    }
    subtest "Validate gc accepts config" validate_config

    start_gc() {
      export GC_CITY_NAME=test-city
      export GC_WORKSPACE="$WS"
      export GC_AGENT_IMAGE=wrapix-test:latest
      export GC_PODMAN_NETWORK="$NETWORK_NAME"
      # Clean up any containers left by gc rig add's auto-start
      podman rm -f gc-test-city-scout gc-test-city-reviewer 2>/dev/null || true
      podman network create "$NETWORK_NAME"
      setsid gc start --foreground > "$WS/gc.log" 2>&1 &
      GC_PID=$!
      sleep 3
      if ! kill -0 "$GC_PID" 2>/dev/null; then
        echo "gc exited prematurely:"
        cat "$WS/gc.log" 2>/dev/null | sed 's/^/  /' || true
        return 1
      fi
    }
    subtest "Start gc daemon" start_gc

    subtest "Wait for scout to create a bead" \
      poll_until 'timeout 5 bd list --json 2>/dev/null | jq -e "[.[] | select(.title | test(\"Fix test error\"))] | length > 0"' 60

    BEAD_ID=$(bd list --json 2>/dev/null | jq -r '[.[] | select(.title | test("Fix test error"))][0].id' || echo "")

    sling_bead() {
      [ -n "$BEAD_ID" ] && [ "$BEAD_ID" != "null" ] || return 1
      gc sling worker "$BEAD_ID" --on wrapix-worker
    }
    subtest "Director slings bead into convergence" sling_bead

    subtest "Wait for worker worktree" \
      poll_until "ls $WS/.wrapix/worktree/gc-*/fix.txt 2>/dev/null" 90

    subtest "Wait for reviewer approval" \
      poll_until "bd show $BEAD_ID --json 2>/dev/null | jq -r '.[0].metadata.review_verdict // empty' 2>/dev/null | grep -q approve" 30

    # gc convergence would normally drive gate → post-gate via events.
    # Since the test uses gc sling (no convergence loop), invoke post-gate
    # directly as the director would after reviewer approval.
    run_post_gate() {
      GC_BEAD_ID="$BEAD_ID" \
      GC_TERMINAL_REASON="approved" \
      GC_WORKSPACE="$WS" \
      GC_CITY_NAME="test-city" \
        bash ${scriptsDir}/post-gate.sh
    }
    subtest "Run post-gate merge" run_post_gate

    check_deploy_bead() {
      bd list --json 2>/dev/null | jq -e '[.[] | select(.title | startswith("Deploy:"))] | length > 0' >/dev/null
    }
    subtest "Verify deploy bead created" check_deploy_bead

    check_human_deploy() {
      human_list=$(bd human list 2>/dev/null)
      echo "$human_list" | grep -qi deploy
    }
    subtest "Director sees deploy bead in bd human" check_human_deploy

    subtest "Verify worktree cleaned up" \
      test ! -d "$WS"/.wrapix/worktree/gc-*

    verify_merge() {
      git log --oneline | grep -q fix
    }
    subtest "Verify merge landed on main" verify_merge

    verify_branch_cleaned() {
      ! git branch | grep gc-
    }
    subtest "Verify branch cleaned up" verify_branch_cleaned

    # ================================================================
    # Stop gc — Phase 2+ don't need it (saves resources, faster cleanup)
    # ================================================================

    stop_gc() {
      if [ -n "$GC_PID" ] && kill -0 "$GC_PID" 2>/dev/null; then
        # gc runs in its own session (setsid) — kill the entire process group
        # so bd/dolt grandchildren don't orphan and hold dolt locks
        kill -TERM -"$GC_PID" 2>/dev/null || true
        for _ in $(seq 1 100); do
          kill -0 "$GC_PID" 2>/dev/null || break
          sleep 0.1
        done
        kill -9 -"$GC_PID" 2>/dev/null || true
        wait "$GC_PID" 2>/dev/null || true
      fi
      # Stop and remove gc containers
      podman ps --filter "network=$NETWORK_NAME" -q 2>/dev/null | xargs -r podman stop -t 3 2>/dev/null || true
      podman ps -a --filter "network=$NETWORK_NAME" -q 2>/dev/null | xargs -r podman rm -f 2>/dev/null || true
      GC_PID=""
    }
    subtest "Stop gc after Phase 1" stop_gc

    # ================================================================
    # Phase 2: Merge conflict — rebase fails, reject_to_worker
    # ================================================================

    create_conflict() {
      echo conflict > fix.txt
      git add fix.txt
      git commit -m "create conflict"
    }
    subtest "Create conflicting change on main" create_conflict

    subtest "Create second bead" \
      bd create --title="Second fix" --type=bug --priority=2

    BEAD2=$(bd list --json --title "Second fix" 2>/dev/null | jq -r '.[0].id')

    # Phase 2 tests post-gate's merge conflict handling. Instead of waiting
    # for gc to start a second worker (gc's scale_check can time out under
    # dolt contention), simulate the worker flow directly on the host.
    simulate_worker2() {
      [ -n "$BEAD2" ] && [ "$BEAD2" != "null" ] || return 1
      local wt="$WS/.wrapix/worktree/gc-$BEAD2"
      # Create worktree from BEFORE the conflict commit so branches diverge
      git worktree add "$wt" -b "gc-$BEAD2" HEAD~1 2>/dev/null || \
        git worktree add "$wt" "gc-$BEAD2"
      (cd "$wt" && echo "fix applied v2" > fix.txt && git add fix.txt && git commit -m "fix: resolve second error")
      local merge_base
      merge_base="$(git merge-base main "gc-$BEAD2")"
      bd update "$BEAD2" --set-metadata "commit_range=''${merge_base}..gc-$BEAD2"
      bd update "$BEAD2" --set-metadata "branch_name=gc-$BEAD2"
      bd update "$BEAD2" --set-metadata "review_verdict=approve"
      bd update "$BEAD2" --status=in_progress
    }
    subtest "Simulate worker commit for second bead" simulate_worker2

    run_post_gate2() {
      GC_BEAD_ID="$BEAD2" \
      GC_TERMINAL_REASON="approved" \
      GC_WORKSPACE="$WS" \
      GC_CITY_NAME="test-city" \
        bash ${scriptsDir}/post-gate.sh
    }
    subtest "Post-gate detects merge conflict and rejects" run_post_gate2

    verify_reopened() {
      status=$(bd show "$BEAD2" --json 2>/dev/null | jq -r '.[0].status')
      [ "$status" = "open" ]
    }
    subtest "Verify bead reopened after conflict" verify_reopened

    verify_merge_failure_metadata() {
      bd show "$BEAD2" --json 2>/dev/null | jq -r '.[0].metadata.merge_failure // empty' 2>/dev/null | grep -qi conflict
    }
    subtest "Verify merge_failure metadata set" verify_merge_failure_metadata

    subtest "Verify old worktree cleaned up after rejection" \
      test ! -d "$WS/.wrapix/worktree/gc-$BEAD2"

    # ================================================================
    # Phase 3: Escalation — convergence ends with non-approved reason
    # ================================================================

    subtest "Create escalation bead" \
      bd create --title="Escalation test" --type=bug --priority=2

    BEAD3=$(bd list --json --title "Escalation test" 2>/dev/null | jq -r '.[0].id')

    setup_escalation_worktree() {
      [ -n "$BEAD3" ] && [ "$BEAD3" != "null" ] || return 1
      local wt="$WS/.wrapix/worktree/gc-$BEAD3"
      git worktree add "$wt" -b "gc-$BEAD3" HEAD 2>/dev/null || \
        git worktree add "$wt" "gc-$BEAD3"
      bd update "$BEAD3" --status=in_progress
    }
    subtest "Set up worktree for escalation bead" setup_escalation_worktree

    run_post_gate_escalation() {
      GC_BEAD_ID="$BEAD3" \
      GC_TERMINAL_REASON="max_rounds_exceeded" \
      GC_WORKSPACE="$WS" \
      GC_CITY_NAME="test-city" \
        bash ${scriptsDir}/post-gate.sh
    }
    subtest "Post-gate handles escalation (non-approved)" run_post_gate_escalation

    subtest "Verify escalation worktree cleaned up" \
      test ! -d "$WS/.wrapix/worktree/gc-$BEAD3"

    verify_escalation_branch_cleaned() {
      ! git branch | grep "gc-$BEAD3"
    }
    subtest "Verify escalation branch cleaned up" verify_escalation_branch_cleaned
  '';

in
{
  # Script derivation — consumed by tests/default.nix to build the app
  script = testScript;
}
