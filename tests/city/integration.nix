# Gas City full ops loop integration test
#
# Exercises the real stack: gc → provider.sh → podman → container → mock claude
# Only the LLM binary is substituted. Everything else runs for real.
#
# Scenarios:
#   happy-path:
#     gc starts → scout creates bead → sling → worker commits → judge
#     approves → judge-merge.sh (ff) → post-gate (deploy bead, notify)
#     + verify tmux session alive in persistent containers
#   reconciler-sling: gc sling routes bead → scale_check → worker starts
#   merge-conflict-reject: diverged branch → rebase conflicts → reject
#   escalation-non-approved: non-approved convergence → post-gate cleanup
#   recovery-monitor-died: worker committed, monitor died → recovery.sh
#   recovery-empty-branch: empty branch → recovery no-op, gate rejects
#   worker-setup-collect: worker-setup.sh, worker-collect.sh direct tests
#   rebase-success: main advanced, no conflict → rebase + ff-merge
#   gate-approve-reject: gate.sh approve → exit 0, reject → exit 1
#   dispatch-cooldown: dispatch.sh cooldown, P0 bypass, backpressure
#   post-gate-close-bead: approved convergence → work bead closed
#   retry-judge-notes: judge rejection notes appear in .task on retry
#   recovery-orphan-worktree: closed bead → recovery cleans worktree+branch
#   phantom-dog-suppressed: dog agent max_active_sessions=0 (wx-m7a1d)
#   provider-stripped-from-config: workspace.provider removed (wx-y4tx2)
#   provider-worker-name-routing: agent_template detection (wx-aqe4z)
#   provider-extracts-issue: issue field from start JSON (wx-fsqcz)
#   agent-max-sessions: pool agents have max_active_sessions (wx-65bws)
#   config-drift-kills-stale: mutated city.toml → entrypoint kills stale sessions (wx-i42sb)
#
# Requires podman. Run via: nix run .#test-city
{
  pkgs,
  system,
  linuxPkgs,
}:

let
  inherit (pkgs) lib;
  sandbox = import ../../lib/sandbox {
    inherit pkgs system linuxPkgs;
  };
  ralph = import ../../lib/ralph {
    inherit pkgs;
    inherit (sandbox) mkSandbox;
  };
  beadsLib = import ../../lib/beads { inherit pkgs linuxPkgs; };
  cityMod = import ../../lib/city {
    inherit pkgs linuxPkgs;
    beads = beadsLib;
    inherit (sandbox) mkSandbox profiles baseClaudeSettings;
    inherit (ralph) mkRalph;
  };
  wrapixLib = import ../../lib {
    inherit pkgs system linuxPkgs;
  };

  # Name the input profile so liveCity.sandbox.profile ends up as
  # "city-test". The test builds testImage below from liveCity.sandbox.profile
  # and tags it with liveCity.imageName (hash-based) after loading.
  testProfile = sandbox.profiles.base // {
    name = "test";
  };

  liveCity = cityMod.mkCity {
    name = "test-city";
    workers = 2;
    profile = testProfile;
  };

  # Live outputs — no duplication
  inherit (liveCity)
    scripts
    prompts
    configDir
    stageGcLayout
    promoteGcLayout
    ;

  toTOML = import ../../lib/util/toml.nix { inherit lib; };

  # Mock claude binary — deterministic bash script per role
  mockClaude = pkgs.writeShellScriptBin "claude" ''
    set -euo pipefail

    # Write all output to host-visible log (mounted workspace .beads dir is rw for
    # mayor/scout/judge, but ro for workers — use /tmp as fallback)
    MOCK_LOG="/workspace/.beads/mock-claude-''${GC_AGENT:-unknown}.log"
    if ! touch "$MOCK_LOG" 2>/dev/null; then
      MOCK_LOG="/tmp/mock-claude-''${GC_AGENT:-unknown}.log"
    fi
    exec > >(tee -a "$MOCK_LOG") 2>&1

    # Dispatch on GC_SESSION (set by provider.sh), not CLI flags —
    # both workers and persistent roles receive --dangerously-skip-permissions.
    case "''${GC_SESSION:-}" in
      worker)
        # Worker run mode — launched inside tmux by agent.sh
        # Write checks to log file — tmux captures stdout away from podman logs.
        _log=/workspace/mock-claude-worker.log
        _check() { echo "$1"; echo "$1" >> "$_log"; }
        # Verify wx-cswtw: --dangerously-skip-permissions must be passed
        if [[ " $* " == *" --dangerously-skip-permissions "* ]]; then
          _check "AGENT_CHECK: --dangerously-skip-permissions PRESENT"
        else
          _check "AGENT_CHECK: --dangerously-skip-permissions MISSING"
        fi
        # Verify wx-cswtw: claude config must be provisioned before run
        if [[ -f "$HOME/.claude.json" ]]; then
          _check "AGENT_CHECK: claude.json PRESENT"
        else
          _check "AGENT_CHECK: claude.json MISSING"
        fi
        if [[ -f "$HOME/.claude/settings.json" ]]; then
          _check "AGENT_CHECK: settings.json PRESENT"
        else
          _check "AGENT_CHECK: settings.json MISSING"
        fi
        # wx-m5sd6: workers must run inside tmux (not claude -p)
        if [[ -n "''${TMUX:-}" ]]; then
          _check "AGENT_CHECK: tmux PRESENT"
        else
          _check "AGENT_CHECK: tmux MISSING — worker claude must run inside tmux"
        fi
        git config user.email test@test
        git config user.name test
        echo "fix applied" > fix.txt
        git add fix.txt
        git commit -m "fix: resolve test error"
        ;;
      *)
        # Persistent session mode (mayor, scout, or judge)
        # Ensure dolt config exists (container has no global config)
        dolt config --global --add user.email mock@test 2>/dev/null || true
        dolt config --global --add user.name mock 2>/dev/null || true
        case "''${GC_AGENT:-}" in
          mayor|mayor*)
            # Mayor stays alive — responds on attach with briefing
            sleep 600
            ;;
          scout|scout*)
            bd create --title="Fix test error" --type=bug --priority=2
            # Stay alive for gc to manage
            sleep 600
            ;;
          judge|judge*)
            # Poll for beads needing review, approve them
            for i in $(seq 1 300); do
              for id in $(bd list --status=in_progress --json 2>/dev/null | jq -r '.[].id' 2>/dev/null); do
                cr=$(bd show "$id" --json 2>/dev/null | jq -r '.[0].metadata.commit_range // empty' 2>/dev/null) || cr=""
                if [ -n "$cr" ]; then
                  # Only approve if not already approved
                  existing=$(bd show "$id" --json 2>/dev/null | jq -r '.[0].metadata.review_verdict // empty' 2>/dev/null) || existing=""
                  if [ -z "$existing" ]; then
                    bd update "$id" --set-metadata "review_verdict=approve" 2>/dev/null || true
                    bd update "$id" --notes "Judge: approved — test" 2>/dev/null || true
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

  # Test city.toml: live config with test-specific overrides
  # (shorter patrol interval for fast testing).
  # Deliberately inherits [dolt] from live config — if someone removes it
  # from cityConfig, this test will fail with port-0 connection errors.
  cityToml = pkgs.writeText "city.toml" (
    toTOML (
      liveCity.configAttrs
      // {
        daemon = liveCity.configAttrs.daemon // {
          patrol_interval = "5s";
          max_restarts = 3;
        };
      }
    )
  );

  inherit (pkgs.stdenv) isDarwin;

  # Reuse liveCity's computed profile (name = "city-test") so after loading
  # and tagging, the image matches liveCity.imageName.
  testImage = sandbox.mkImage {
    inherit (liveCity.sandbox) profile;
    entrypointSh = ../../lib/sandbox/linux/entrypoint.sh;
    claudePkg = mockClaude;
    asTarball = isDarwin;
  };

  # Host PATH — derived from the SAME mkDevShell the flake uses, plus the
  # consumer extras the flake adds. If a tool is missing here, the test
  # fails — just like live would.
  #
  # Structure mirrors flake.nix devShells.default:
  #   wrapix.mkDevShell {
  #     packages = city.packages ++ [ podman ... ];
  #   };
  #
  # wrapix.mkDevShell (lib/default.nix) provides its own base packages
  # (beads, dolt, prek) on top of city.packages, so we don't duplicate them.
  liveDevShell = wrapixLib.mkDevShell {
    inherit (liveCity) shellHook;
    packages = liveCity.packages ++ [
      pkgs.podman # consumer extra (flake.nix)
    ];
  };

  # The live PATH has three layers:
  #   1. nativeBuildInputs — explicit devShell packages (gc, beads, ralph, ...)
  #   2. stdenv.initialPath — Nix bootstrap (bash, coreutils, sed, grep, ...)
  #   3. System tools — assumed present on the host (git, jq, util-linux)
  #      In nix develop, these come from the user's system PATH. In the test
  #      sandbox we must provide them explicitly.
  systemDeps = [
    pkgs.git
    pkgs.jq
    pkgs.util-linux # flock, setsid
    mockClaude # gc workspace provider check (live: system-installed claude)
  ];
  livePath = lib.makeBinPath (
    liveDevShell.nativeBuildInputs ++ pkgs.stdenv.initialPath ++ systemDeps
  );

  # Test-driver-only extras — used for assertions and diagnostics, NEVER
  # by code under test. If a tool is needed by entrypoint/gc/provider,
  # it belongs in liveDevShell or systemDeps above, not here.
  testOnlyDeps = with pkgs; [
    lsof # diagnostics dump
    tmux # cleanup
  ];
  testOnlyPath = lib.makeBinPath testOnlyDeps;

  testScript = pkgs.writeShellScriptBin "test-city" ''
    set -euo pipefail

    # ================================================================
    # Helpers
    # ================================================================

    # LIVE_PATH = exact devShell PATH. All code under test (entrypoint,
    # city scripts) runs with ONLY this. Test extras are appended for the
    # driver's own assertions/diagnostics but never leak into live code.
    export LIVE_PATH="${livePath}"
    export PATH="${livePath}:${testOnlyPath}"

    # Preflight: check podman before setting up trap/counters so skip
    # doesn't print a misleading "ALL TESTS PASSED" summary.
    if ! command -v podman >/dev/null 2>&1; then
      echo "SKIP: podman not found — city integration tests require podman on the host."
      exit 0
    fi

    # Isolate from the caller's environment. The wrapix devShell shellHook
    # exports BEADS_DOLT_SERVER_* pointing at the host workspace's dolt
    # container; inheriting those sends the test's `bd` calls to the host
    # db and breaks types.custom setup (gc then rejects its own "session"
    # beads with "invalid issue type"). Strip every BEADS_*/BD_* var so
    # the test only sees state it sets itself.
    for _v in ''${!BEADS_@} ''${!BD_@}; do unset "$_v"; done

    PASSED=0
    FAILED=0
    GC_PID=""
    WS=""
    TEST_NETWORK="${liveCity.networkName}"
    DOLT_CONTAINER=""
    DOLT_PORT=""
    # Pass --no-fail-fast to run all tests even after failures
    FAIL_FAST=true
    if [ "''${1:-}" = "--no-fail-fast" ]; then
      FAIL_FAST=false
    fi

    dump_diagnostics() {
      echo ""
      echo "--- Diagnostics ---"
      echo "  dolt server:"
      echo "    container: $(podman inspect --format '{{.State.Status}}' "$DOLT_CONTAINER" 2>/dev/null || echo 'not found')"
      echo "    reachable: $(bash -c "echo > /dev/tcp/127.0.0.1/$DOLT_PORT" 2>/dev/null && echo yes || echo no)"
      echo "    GC_DOLT_PORT=''${GC_DOLT_PORT:-unset}"
      if [ -n "$WS" ] && [ -f "$WS/gc.log" ]; then
        echo "  gc.log (last 40 lines):"
        tail -40 "$WS/gc.log" 2>/dev/null | sed 's/^/    /' || true
      fi
      # Show logs from any gc containers
      for cid in $(podman ps -a --filter "name=gc-test-city-" -q 2>/dev/null); do
        local cname
        cname=$(podman inspect --format '{{.Name}}' "$cid" 2>/dev/null || echo "$cid")
        echo "  container $cname (podman logs):"
        podman logs "$cid" 2>&1 | tail -20 | sed 's/^/    /' || true
      done
      if [[ "''${DEBUG:-}" == "1" ]]; then
        echo "  dolt container logs:"
        podman logs "$DOLT_CONTAINER" 2>&1 | tail -10 | sed 's/^/    /' || true
        if [ -n "$WS" ] && [ -d "$WS/.beads/dolt" ]; then
          echo "  .beads/dolt tree:"
          find "$WS/.beads/dolt" -maxdepth 4 2>/dev/null | sed 's/^/    /'
          echo "  files referencing /tmp/:"
          grep -rl "/tmp/" "$WS/.beads/dolt" 2>/dev/null | while IFS= read -r f; do
            echo "    $f:"
            grep -o "/tmp/[A-Za-z0-9_/.-]*" "$f" 2>/dev/null | sort -u | sed 's/^/      /'
          done
        fi
      fi
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
      if [ -n "$WS" ]; then
        beads-dolt stop "$WS" 2>/dev/null || true
      fi
      podman ps --filter "name=gc-test-city-" -q 2>/dev/null | xargs -r podman stop -t 3 2>/dev/null || true
      podman ps -a --filter "name=gc-test-city-" -q 2>/dev/null | xargs -r podman rm -f 2>/dev/null || true
      podman network rm "$TEST_NETWORK" 2>/dev/null || true
      podman rmi "${liveCity.imageName}" 2>/dev/null || true
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

    # Run a city script via the live .gc/scripts/ symlinks with LIVE_PATH.
    # Every script invocation must go through this to exercise the real
    # invocation path (symlink resolution, live PATH, live env).
    # Written as a real script (not a function) so subtest "..." live ...
    # and VAR=val live ... both work.
    _LIVE_DIR="$(mktemp -d)"
    echo '#!/usr/bin/env bash' > "$_LIVE_DIR/live"
    echo 'exec env PATH="$LIVE_PATH" bash "$WS/.gc/scripts/$1" "''${@:2}"' >> "$_LIVE_DIR/live"
    chmod +x "$_LIVE_DIR/live"
    export PATH="$_LIVE_DIR:$PATH"

    echo "=== Gas City Integration Test ==="

    # ================================================================
    # Pre-cleanup: remove stale state from previous runs
    # ================================================================

    podman ps --filter "name=gc-test-city-" -q 2>/dev/null | xargs -r podman stop -t 3 2>/dev/null || true
    podman ps -a --filter "name=gc-test-city-" -q 2>/dev/null | xargs -r podman rm -f 2>/dev/null || true
    podman network rm "$TEST_NETWORK" 2>/dev/null || true

    # ================================================================
    # Setup: workspace, config, image
    # ================================================================

    subtest "Load test container image" \
      sh -c '${
        if isDarwin then "cat ${testImage}" else "${testImage}"
      } | podman load && podman tag "localhost/wrapix-${liveCity.sandbox.profile.name}:latest" "${liveCity.imageName}"'

    WS=$(mktemp -d -t citytest-XXXXXX)
    # Resolve symlinks (macOS /tmp -> /private/tmp) so podman VM can mount paths
    WS=$(cd "$WS" && pwd -P)
    export WS
    echo "  > workspace: $WS"
    cd "$WS"

    # Isolate dolt global config so tests don't clobber the host's ~/.dolt/
    export HOME="$WS"

    setup_workspace() {
      git init -b main
      git config user.email test@test
      git config user.name test
      git config commit.gpgsign false
      dolt config --global --add user.email test@test
      dolt config --global --add user.name test
      git commit --allow-empty -m initial

      # Directories the provider mounts into containers
      mkdir -p .wrapix .claude docs

      # --- gc init: scaffolds .beads/ and .gc/ ---
      # gc init auto-starts its supervisor and blocks; kill the process group
      # once .beads/metadata.json exists. beads-dolt will then serve the same
      # data dir as a shared podman container.
      setsid env PATH="$LIVE_PATH" gc init --file ${cityToml} --skip-provider-readiness </dev/null &
      _GC_INIT_PID=$!
      for _i in $(seq 1 60); do
        [ -f .beads/metadata.json ] && break
        sleep 0.5
      done
      if [ ! -f .beads/metadata.json ]; then
        echo "FATAL: gc init did not create .beads/metadata.json after 30s"
        return 1
      fi

      bd config set types.custom "molecule,convoy,message,event,gate,merge-request,agent,role,rig,session,convergence"

      kill -TERM -"$_GC_INIT_PID" 2>/dev/null || true
      for _i in $(seq 1 30); do
        kill -0 "$_GC_INIT_PID" 2>/dev/null || break
        sleep 0.2
      done
      kill -9 -"$_GC_INIT_PID" 2>/dev/null || true
      wait "$_GC_INIT_PID" 2>/dev/null || true
      gc supervisor stop 2>&1 || true
      gc unregister "$WS" 2>&1 || true

      # Stop gc's embedded dolt (entrypoint will start beads-dolt on the same dir).
      if [ -f .beads/dolt-server.pid ]; then
        kill "$(cat .beads/dolt-server.pid)" 2>/dev/null || true
      fi
      if [ -f .beads/dolt-server.port ]; then
        _EDOLT_PORT=$(cat .beads/dolt-server.port)
        for _i in $(seq 1 20); do
          bash -c "echo > /dev/tcp/127.0.0.1/$_EDOLT_PORT" 2>/dev/null || break
          sleep 0.2
        done
      fi
      rm -f .beads/dolt-server.pid .beads/dolt-server.lock .beads/dolt-server.port
      # Clean up stale managed dolt state left by gc init's embedded dolt.
      # Without this, currentDoltPort() sees hasManagedDoltState=true, finds
      # no live port, and removes .beads/dolt-server.port — breaking gc sling.
      rm -rf .gc/runtime/packs/*/dolt-state.json 2>/dev/null || true
      chmod 700 .beads

      podman network create "$TEST_NETWORK" >/dev/null 2>&1 || true

      # Copy city.toml to workspace root — entrypoint.sh sed-replaces the
      # dolt port sentinel here, and stage-gc-home.sh copies it into the
      # staged gc home. Matches live (city.app and modules/city.nix).
      cp -f ${cityToml} city.toml
      chmod u+w city.toml

      echo "  > workspace ready"

      git add -A && git commit -m "workspace setup"

      # Place scripts at lib/city/ (in production this is the source tree;
      # in the test sandbox we copy from the Nix store), then call the
      # shared stageGcLayout to stage into .gc/.staged/, then promote to live.
      mkdir -p lib/city
      for f in ${scripts}/*; do cp -f "$f" lib/city/; done
      ${stageGcLayout}
      ${promoteGcLayout}
      mkdir -p .wrapix/city/current/prompts
      cp -f ${configDir}/claude-settings.json .wrapix/city/current/
      cp -f ${configDir}/tmux.conf .wrapix/city/current/
      for f in ${prompts}/*; do cp -f "$f" .wrapix/city/current/prompts/; done

      printf "## Scout Rules\nimmediate: FATAL|PANIC\nbatched: ERROR\n## Auto-deploy\nLow-risk: docs only\n" > docs/orchestration.md
      printf "# Style Guidelines\nSH-1: Use set -euo pipefail\n" > docs/style-guidelines.md
      printf "<!-- expires: 2025-01-01 -->\nTemporary: freeze deploys during migration\n" > .wrapix/orchestration.md
      git add -A && git commit -m "setup: formulas and scripts"
    }
    subtest "Set up workspace" setup_workspace

    # ================================================================
    # happy-path: mayor + scout + judge → worker → judge merge
    # ================================================================

    validate_config() {
      result=$(gc config show --validate 2>&1)
      echo "$result" | grep -qi "valid\|ok"
    }
    subtest "Validate gc accepts config" validate_config

    start_gc() {
      podman rm -f gc-test-city-mayor gc-test-city-scout gc-test-city-judge 2>/dev/null || true

      DOLT_CONTAINER="$(beads-dolt name "$WS")"
      DOLT_PORT="$(beads-dolt port "$WS")"

      export GC_CITY_NAME="test-city"
      export GC_WORKSPACE="$WS"
      export GC_AGENT_IMAGE="${liveCity.imageName}"
      export GC_PODMAN_NETWORK="$TEST_NETWORK"

      # Run entrypoint with ONLY the live PATH — no test extras — so
      # missing-dependency bugs surface here just as they would in prod.
      # GC_NUDGE_IDLE_TIMEOUT=1: provider idle wait is 1s (not 30s) so
      # cross-container nudge tests don't block on the wait-idle loop.
      setsid env PATH="$LIVE_PATH" GC_NUDGE_IDLE_TIMEOUT=1 "$WS/.gc/scripts/entrypoint.sh" >"$WS/gc.log" 2>&1 &
      GC_PID=$!

      for _i in $(seq 1 100); do
        bash -c "echo > /dev/tcp/127.0.0.1/$DOLT_PORT" 2>/dev/null && break
        sleep 0.2
      done

      # Wait for gc daemon to create controller socket (readiness signal)
      # or die (crash detection). Replaces a fixed sleep — deterministic.
      poll_until 'test -S "$WS/.gc/home/.gc/controller.sock" || ! kill -0 "$GC_PID" 2>/dev/null' 15
      if ! kill -0 "$GC_PID" 2>/dev/null; then
        echo "gc daemon died:"
        tail -40 "$WS/gc.log" 2>/dev/null | sed 's/^/  /' || true
        return 1
      fi

      export BEADS_DOLT_SERVER_HOST=127.0.0.1
      export BEADS_DOLT_SERVER_PORT="$DOLT_PORT"
      export BEADS_DOLT_AUTO_START=0
      # gc CLI commands (gc sling, gc status) resolve the dolt port from
      # .beads/dolt-server.port for non-external (localhost) dolt servers.
      echo "$DOLT_PORT" > "$WS/.beads/dolt-server.port"
    }
    subtest "Start gc daemon" start_gc

    # wx-entt5: workspace.provider = "claude" causes gc to auto-inject a
    # phantom "claude" agent with provider = "claude" (HOST tmux management),
    # conflicting with the exec provider. Check the staged gc home that the
    # live entrypoint created — the same config the running gc daemon uses.
    verify_no_phantom_agent() {
      local resolved
      resolved="$(gc config show --city "$WS/.gc/home" 2>&1)"
      if echo "$resolved" | grep -q 'provider = "claude"'; then
        echo "FAIL: gc config contains 'provider = \"claude\"' — phantom agent injected"
        echo "Resolved config:"
        echo "$resolved"
        return 1
      fi
      # 5 agents: mayor, scout, worker, judge, dog (max=0 override)
      local agent_count
      agent_count="$(echo "$resolved" | grep -c '^\[\[agent\]\]')"
      if [ "$agent_count" -ne 5 ]; then
        echo "FAIL: expected 5 agents (4 + dog override), found $agent_count"
        echo "$resolved"
        return 1
      fi
    }
    subtest "No phantom claude agent in resolved config (wx-entt5)" verify_no_phantom_agent

    verify_relative_symlinks() {
      # Controller symlinks must be relative so they resolve inside agent
      # containers where the workspace is bind-mounted at a different path.
      for f in controller.sock controller.lock controller.token; do
        local target
        target="$(readlink "$WS/.gc/$f")"
        case "$target" in
          /*) echo "FAIL: $f symlink is absolute: $target"; return 1 ;;
        esac
      done

      # Script symlinks must be relative and executable (wx-kw0q1).
      for f in "$WS"/.gc/scripts/*.sh; do
        local target
        target="$(readlink "$f")"
        case "$target" in
          /*) echo "FAIL: $(basename "$f") symlink is absolute: $target"; return 1 ;;
        esac
        if [ ! -x "$f" ]; then
          echo "FAIL: $(basename "$f") symlink is not executable"; return 1
        fi
      done
    }
    subtest "Verify controller and script symlinks are relative" verify_relative_symlinks

    subtest "Wait for mayor container to start" \
      poll_until 'podman ps --filter "name=gc-test-city-mayor" -q 2>/dev/null | grep -q .' 30

    verify_mayor_tmux() {
      # Verify the shared tmux socket was created on .wrapix/tmux/ and the
      # session is reachable directly (no podman exec needed).
      poll_until 'test -S "$WS/.wrapix/tmux/mayor.sock"' 10
      tmux -S "$WS/.wrapix/tmux/mayor.sock" has-session -t mayor 2>/dev/null
    }
    subtest "Verify tmux session alive in mayor container" verify_mayor_tmux

    # Wait for scout to start (needed for nudge tests below)
    subtest "Wait for scout container to start" \
      poll_until 'test -S "$WS/.wrapix/tmux/scout.sock"' 30

    # Shared tmux socket: gc session nudge from host via provider.sh → shared socket
    verify_gc_nudge_via_socket() {
      GC_CITY="$WS/.gc/home" gc session nudge --delivery=immediate scout "host-nudge-test"
      poll_until 'tmux -S "$WS/.wrapix/tmux/scout.sock" capture-pane -t scout -p | grep -q "host-nudge-test"' 10
    }
    subtest "gc session nudge uses shared tmux socket from host" verify_gc_nudge_via_socket

    # Cross-container: mayor calls gc session nudge from inside its container.
    # Uses default delivery (wait-idle) — the production path that enqueues
    # to .gc/nudges/ (acquiring state.lock).  For exec providers, queued
    # nudges are drained by Claude Code's session hook (gc nudge drain);
    # we simulate that second half here.
    verify_cross_container_gc_nudge() {
      podman exec gc-test-city-mayor \
        gc session nudge scout "cross-container-nudge-test"
      # Drain from inside the scout container — the live path:
      # Claude Code's session hook runs gc nudge drain inside the agent container.
      local drained
      drained="$(podman exec gc-test-city-scout gc nudge drain scout 2>&1)"
      echo "$drained" | grep -q "cross-container-nudge-test" || {
        echo "FAIL: drained output missing nudge message: $drained"
        return 1
      }
    }
    subtest "gc session nudge works from inside mayor container" verify_cross_container_gc_nudge

    # .gc must be writable from inside containers (wx-9gm3t)
    verify_gc_writable_scout() {
      podman exec gc-test-city-scout \
        touch /workspace/.gc/nudges/write-test-scout
      [ -f "$WS/.gc/nudges/write-test-scout" ]
      rm -f "$WS/.gc/nudges/write-test-scout"
    }
    subtest ".gc is writable from scout container" verify_gc_writable_scout

    verify_gc_writable_mayor() {
      podman exec gc-test-city-mayor \
        touch /workspace/.gc/nudges/write-test-mayor
      [ -f "$WS/.gc/nudges/write-test-mayor" ]
      rm -f "$WS/.gc/nudges/write-test-mayor"
    }
    subtest ".gc is writable from mayor container" verify_gc_writable_mayor

    # gc session peek via shared socket (read path)
    verify_gc_peek_via_socket() {
      local output
      output="$(GC_CITY="$WS/.gc/home" gc session peek scout)"
      [[ -n "$output" ]]
    }
    subtest "gc session peek uses shared tmux socket" verify_gc_peek_via_socket

    subtest "Wait for scout to create a bead" \
      poll_until 'timeout 5 bd list --json 2>/dev/null | jq -e "[.[] | select(.title | test(\"Fix test error\"))] | length > 0"' 60

    BEAD_ID=$(bd list --json 2>/dev/null | jq -r '[.[] | select(.title | test("Fix test error"))][0].id' || echo "")

    sling_bead() {
      [ -n "$BEAD_ID" ] && [ "$BEAD_ID" != "null" ] || return 1
      # Use the gc home already staged by the entrypoint.
      # Do NOT re-run stage-gc-home.sh here — it rm -rf's the directory,
      # which destroys gc's cwd (the running daemon holds the old inode).
      # The provider monitor runs the full pipeline after the worker exits:
      # worker-collect → gate.sh → post-gate.sh (wx-7ttop).
      GC_CITY="$WS/.gc/home" gc sling worker "$BEAD_ID" --on wrapix-worker
    }
    subtest "Director slings bead (worker→judge via monitor pipeline)" sling_bead

    subtest "Wait for worker worktree" \
      poll_until "ls $WS/.wrapix/worktree/gc-*/fix.txt 2>/dev/null" 90

    # wx-cswtw: verify worker's claude invocation had permissions flag and config
    verify_worker_agent_setup() {
      # The mock writes to /workspace/mock-claude-worker.log (the worktree
      # mount). Try host-visible paths first, then podman cp as fallback.
      local logf=""
      for f in "$WS"/.wrapix/worktree/gc-*/mock-claude-worker.log "$WS"/.beads/mock-claude-worker.log "$WS"/.wrapix/worktree/gc-*/.beads/mock-claude-worker.log; do
        [ -f "$f" ] && logf="$f" && break
      done
      if [ -z "$logf" ]; then
        # Container-internal /tmp: use podman cp from the (stopped) worker
        local worker_name
        worker_name="$(podman ps -a --filter "name=gc-test-city-worker" --format '{{.Names}}' 2>/dev/null | head -1)"
        if [ -n "$worker_name" ]; then
          logf="$(mktemp)"
          podman cp "$worker_name:/tmp/mock-claude-worker.log" "$logf" 2>/dev/null || logf=""
        fi
      fi
      if [ -z "$logf" ] || [ ! -f "$logf" ]; then
        # Last resort: check podman logs for the AGENT_CHECK lines
        local worker_name
        worker_name="$(podman ps -a --filter "name=gc-test-city-worker" --format '{{.Names}}' 2>/dev/null | head -1)"
        if [ -n "$worker_name" ]; then
          logf="$(mktemp)"
          podman logs "$worker_name" > "$logf" 2>&1 || true
        fi
      fi
      [ -n "$logf" ] && [ -f "$logf" ] || { echo "FAIL: mock-claude worker log not found"; return 1; }

      grep -q "AGENT_CHECK: --dangerously-skip-permissions PRESENT" "$logf" || {
        echo "FAIL: --dangerously-skip-permissions not passed to worker claude"
        grep "AGENT_CHECK" "$logf" || true
        return 1
      }
      grep -q "AGENT_CHECK: claude.json PRESENT" "$logf" || {
        echo "FAIL: \$HOME/.claude.json not provisioned before worker run"
        grep "AGENT_CHECK" "$logf" || true
        return 1
      }
      grep -q "AGENT_CHECK: settings.json PRESENT" "$logf" || {
        echo "FAIL: \$HOME/.claude/settings.json not provisioned before worker run"
        grep "AGENT_CHECK" "$logf" || true
        return 1
      }
      # wx-m5sd6: worker claude must run inside tmux, not via claude -p
      grep -q "AGENT_CHECK: tmux PRESENT" "$logf" || {
        echo "FAIL: worker claude not running inside tmux (wx-m5sd6)"
        grep "AGENT_CHECK" "$logf" || true
        return 1
      }
    }
    subtest "Worker claude has --dangerously-skip-permissions, config, and tmux (wx-cswtw, wx-m5sd6)" verify_worker_agent_setup

    # Provider monitor runs gate.sh after worker-collect sets commit_range.
    # gate.sh nudges judge → mock judge auto-approves → gate returns 0.
    subtest "Wait for judge approval (via monitor gate pipeline)" \
      poll_until "bd show $BEAD_ID --json 2>/dev/null | jq -r '.[0].metadata.review_verdict // empty' 2>/dev/null | grep -q approve" 120

    # Monitor pipeline: gate approved → post-gate.sh fires → closes bead,
    # creates deploy bead, nudges judge to merge.
    subtest "Wait for post-gate pipeline (deploy bead created)" \
      poll_until 'bd list --json 2>/dev/null | jq -e "[.[] | select(.title | startswith(\"Deploy:\"))] | length > 0"' 120

    # Judge merge — post-gate nudges judge via gc session nudge. Called
    # manually since the mock judge does not handle merge nudges.
    judge_merge_phase1() {
      GC_BEAD_ID="$BEAD_ID" GC_WORKSPACE="$WS" live judge-merge.sh
    }
    subtest "Judge merges approved changes" judge_merge_phase1

    check_human_deploy() {
      human_list=$(bd human list 2>/dev/null)
      echo "$human_list" | grep -qi deploy
    }
    subtest "Director sees deploy bead in bd human" check_human_deploy

    verify_merge() {
      git log --oneline | grep -q fix
    }
    subtest "Verify merge landed on main" verify_merge

    verify_worktree_cleaned() {
      # Judge cleaned up the worktree and branch during merge
      ! test -d "$WS"/.wrapix/worktree/gc-* 2>/dev/null
    }
    subtest "Verify worktree cleaned up" verify_worktree_cleaned

    verify_branch_cleaned() {
      ! git branch | grep gc-
    }
    subtest "Verify branch cleaned up" verify_branch_cleaned

    # ================================================================
    # reconciler-sling: reconciler-driven worker start (wx-y9qco)
    #
    # happy-path uses convergence (gc sling --on) which bypasses
    # scale_check. This scenario exercises the reconciler path: gc sling
    # routes a bead, scale_check (dispatch.sh) detects demand, reconciler
    # starts a worker.
    #
    # post-gate.sh closed the happy-path work bead on approved
    # convergence, so no manual cleanup is needed between scenarios.
    # ================================================================

    subtest "Create reconciler-routed bead" \
      bd create --title="Reconciler worker test" --type=bug --priority=2

    RBEAD=$(bd list --json --title "Reconciler worker test" 2>/dev/null | jq -r '.[0].id')

    subtest "Route bead via gc sling" \
      env GC_CITY="$WS/.gc/home" gc sling worker "$RBEAD" --no-convoy --force

    # The reconciler runs scale_check every patrol_interval (5s in test config).
    # scale_check counts routed open beads; the deficit vs running sessions
    # becomes "new" tier demand → reconciler starts a worker.
    subtest "Reconciler starts worker for routed bead (wx-y9qco)" \
      poll_until "ls $WS/.wrapix/worktree/gc-$RBEAD 2>/dev/null" 60

    # Clean up: stop the worker container and remove worktree so
    # merge-conflict-reject starts clean.
    cleanup_reconciler_test() {
      for cid in $(podman ps -q --filter "name=gc-test-city-worker" 2>/dev/null); do
        podman stop -t 3 "$cid" 2>/dev/null || true
        podman rm -f "$cid" 2>/dev/null || true
      done
      local wt="$WS/.wrapix/worktree/gc-$RBEAD"
      if [[ -d "$wt" ]]; then
        rm -rf "$wt"
        git -C "$WS" worktree prune 2>/dev/null || true
      fi
      git -C "$WS" branch -D "gc-$RBEAD" 2>/dev/null || true
    }
    subtest "Clean up reconciler test" cleanup_reconciler_test

    # ================================================================
    # Stop gc — remaining scenarios don't need it (saves resources)
    # ================================================================

    stop_gc() {
      if [ -n "$GC_PID" ] && kill -0 "$GC_PID" 2>/dev/null; then
        # gc runs in its own session (setsid) — kill the entire process group
        # so bd/dolt grandchildren don't orphan and hold dolt locks.
        # The entrypoint's exit trap also stops the dolt container.
        kill -TERM -"$GC_PID" 2>/dev/null || true
        for _ in $(seq 1 100); do
          kill -0 "$GC_PID" 2>/dev/null || break
          sleep 0.1
        done
        kill -9 -"$GC_PID" 2>/dev/null || true
        wait "$GC_PID" 2>/dev/null || true
      fi
      # Stop and remove all gc containers. The beads-dolt container is
      # shared across scenarios and kept running (entrypoint only disconnects
      # it from the network on exit).
      for cid in $(podman ps -a --filter "name=gc-test-city-" -q 2>/dev/null); do
        podman stop -t 3 "$cid" 2>/dev/null || true
        podman rm -f "$cid" 2>/dev/null || true
      done
      GC_PID=""

      # Remove stale git locks left by killed monitor pipeline processes
      # (e.g. worker-collect.sh's git merge-base holding index.lock when
      # the process group was SIGKILL'd).
      rm -f "$WS/.git/index.lock"

      # Ensure beads-dolt is still running for remaining scenarios
      beads-dolt start "$WS" >/dev/null 2>&1 || true
      for _i in $(seq 1 50); do
        bash -c "echo > /dev/tcp/127.0.0.1/$DOLT_PORT" 2>/dev/null && break
        sleep 0.2
      done
    }
    subtest "Stop gc after happy-path" stop_gc

    # ================================================================
    # merge-conflict-reject: rebase fails, reject_to_worker
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

    # Tests the judge's merge conflict handling. The judge owns merge,
    # so conflict rejection is the judge's responsibility.
    simulate_worker2() {
      [ -n "$BEAD2" ] && [ "$BEAD2" != "null" ] || return 1
      local wt="$WS/.wrapix/worktree/gc-$BEAD2"
      # Create worktree from BEFORE the conflict commit so branches diverge.
      # Can't use worker-setup.sh here — it branches from HEAD, but we need
      # HEAD~1 to produce a merge conflict (main advanced while worker worked).
      git worktree add "$wt" -b "gc-$BEAD2" HEAD~1 2>/dev/null || \
        git worktree add "$wt" "gc-$BEAD2"
      (cd "$wt" && echo "fix applied v2" > fix.txt && git add fix.txt && git commit -m "fix: resolve second error")
      GC_BEAD_ID="$BEAD2" GC_WORKSPACE="$WS" live worker-collect.sh
      bd update "$BEAD2" --set-metadata "review_verdict=approve"
      bd update "$BEAD2" --status=in_progress
    }
    subtest "Simulate worker commit for second bead" simulate_worker2

    # judge-merge.sh exits 1 on rejection (conflicts) — verify that exit code
    judge_merge_conflict() {
      local exit_code=0
      GC_BEAD_ID="$BEAD2" GC_WORKSPACE="$WS" \
        live judge-merge.sh 2>&1 || exit_code=$?
      [ "$exit_code" -eq 1 ] || { echo "FAIL: judge-merge should exit 1 on conflict (got: $exit_code)"; return 1; }
    }
    subtest "Judge detects merge conflict and rejects" judge_merge_conflict

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
    # escalation-non-approved: convergence ends with non-approved reason
    # ================================================================

    subtest "Create escalation bead" \
      bd create --title="Escalation test" --type=bug --priority=2

    BEAD3=$(bd list --json --title "Escalation test" 2>/dev/null | jq -r '.[0].id')

    setup_escalation_worktree() {
      GC_BEAD_ID="$BEAD3" GC_WORKSPACE="$WS" live worker-setup.sh
    }
    subtest "Set up worktree for escalation bead" setup_escalation_worktree

    run_post_gate_escalation() {
      GC_BEAD_ID="$BEAD3" \
      GC_TERMINAL_REASON="max_rounds_exceeded" \
      GC_WORKSPACE="$WS" \
      GC_CITY_NAME="test-city" \
        live post-gate.sh
    }
    subtest "Post-gate handles escalation (non-approved)" run_post_gate_escalation

    subtest "Verify escalation worktree cleaned up" \
      test ! -d "$WS/.wrapix/worktree/gc-$BEAD3"

    verify_escalation_branch_cleaned() {
      ! git branch | grep "gc-$BEAD3"
    }
    subtest "Verify escalation branch cleaned up" verify_escalation_branch_cleaned

    verify_escalation_metadata() {
      local escalated
      escalated="$(bd show "$BEAD3" --json 2>/dev/null | jq -r '.[0].metadata.escalated // empty')"
      [ "$escalated" = "true" ] || { echo "FAIL: escalated metadata not set"; return 1; }
      local reason
      reason="$(bd show "$BEAD3" --json 2>/dev/null | jq -r '.[0].metadata.escalation_reason // empty')"
      [ "$reason" = "max_rounds_exceeded" ] || { echo "FAIL: escalation_reason=$reason"; return 1; }
    }
    subtest "Verify escalation metadata set on bead" verify_escalation_metadata

    verify_escalation_human_label() {
      bd show "$BEAD3" --json 2>/dev/null | jq -r '.[0].labels[]' 2>/dev/null | grep -q "human"
    }
    subtest "Verify escalation bead flagged for human review" verify_escalation_human_label

    # ================================================================
    # recovery-monitor-died: monitor died, verify recovery.sh picks up
    # ================================================================

    subtest "Create recovery bead" \
      bd create --title="Recovery test" --type=bug --priority=2

    BEAD4=$(bd list --json --title "Recovery test" 2>/dev/null | jq -r '.[0].id')

    # Simulate: worker committed to branch, but monitor died before
    # setting metadata. This is the state after a crash.
    setup_crashed_worker() {
      [ -n "$BEAD4" ] && [ "$BEAD4" != "null" ] || return 1
      GC_BEAD_ID="$BEAD4" GC_WORKSPACE="$WS" live worker-setup.sh >/dev/null
      local wt="$WS/.wrapix/worktree/gc-$BEAD4"
      (cd "$wt" && echo "recovery fix" > recovery.txt && git add recovery.txt && git commit -m "fix: recovery test")
      # No worker-collect.sh — simulates monitor crash (no metadata set)

      # Verify: no commit_range metadata (monitor "died")
      local cr
      cr="$(bd show "$BEAD4" --json 2>/dev/null | jq -r '.[0].metadata.commit_range // empty' 2>/dev/null)" || cr=""
      [ -z "$cr" ] || { echo "FAIL: commit_range should not be set yet"; return 1; }
    }
    subtest "Simulate crashed worker (commits but no metadata)" setup_crashed_worker

    run_recovery() {
      GC_CITY_NAME="test-city" GC_WORKSPACE="$WS" live recovery.sh
    }
    subtest "Run recovery.sh" run_recovery

    verify_recovery_metadata() {
      local cr
      cr="$(bd show "$BEAD4" --json 2>/dev/null | jq -r '.[0].metadata.commit_range // empty' 2>/dev/null)" || cr=""
      [ -n "$cr" ] || { echo "FAIL: recovery did not set commit_range"; return 1; }
      echo "  commit_range=$cr"

      local bn
      bn="$(bd show "$BEAD4" --json 2>/dev/null | jq -r '.[0].metadata.branch_name // empty' 2>/dev/null)" || bn=""
      [ "$bn" = "gc-$BEAD4" ] || { echo "FAIL: recovery did not set branch_name (got: $bn)"; return 1; }
    }
    subtest "Verify recovery set commit_range metadata" verify_recovery_metadata

    # Gate should now succeed (metadata exists)
    verify_gate_reads_metadata() {
      local cr
      cr="$(bd show "$BEAD4" --json 2>/dev/null | jq -r '.[0].metadata.commit_range // empty' 2>/dev/null)" || cr=""
      [ -n "$cr" ]
    }
    subtest "Verify gate can find metadata after recovery" verify_gate_reads_metadata

    # Clean up recovery worktree
    cleanup_recovery() {
      local wt="$WS/.wrapix/worktree/gc-$BEAD4"
      rm -rf "$wt"
      git -C "$WS" worktree prune 2>/dev/null || true
      git -C "$WS" branch -D "gc-$BEAD4" 2>/dev/null || true
    }
    subtest "Clean up recovery worktree" cleanup_recovery

    # ================================================================
    # recovery-empty-branch: worker exited without committing
    # ================================================================

    subtest "Create no-op bead" \
      bd create --title="No-op worker test" --type=bug --priority=2

    BEAD5=$(bd list --json --title "No-op worker test" 2>/dev/null | jq -r '.[0].id')

    # Worker started but exited without committing — no commits beyond main.
    setup_noop_worker() {
      GC_BEAD_ID="$BEAD5" GC_WORKSPACE="$WS" live worker-setup.sh
    }
    subtest "Set up no-op worker (no commits)" setup_noop_worker

    # Recovery should NOT set metadata for a branch with no commits
    run_recovery_noop() {
      GC_CITY_NAME="test-city" GC_WORKSPACE="$WS" live recovery.sh
    }
    subtest "Run recovery.sh for no-op worker" run_recovery_noop

    verify_noop_no_metadata() {
      local cr
      cr="$(bd show "$BEAD5" --json 2>/dev/null | jq -r '.[0].metadata.commit_range // empty' 2>/dev/null)" || cr=""
      [ -z "$cr" ] || { echo "FAIL: commit_range should not be set for no-op worker (got: $cr)"; return 1; }
    }
    subtest "Verify no metadata set for no-op worker" verify_noop_no_metadata

    # Gate should return 1 (no commit_range = not ready).
    verify_gate_rejects_noop() {
      local exit_code=0
      GC_BEAD_ID="$BEAD5" GC_POLL_INTERVAL=0 GC_POLL_TIMEOUT=1 \
        live gate.sh > /dev/null 2>&1 || exit_code=$?
      [ "$exit_code" -eq 1 ] || { echo "FAIL: gate should exit 1 for no-op worker (got: $exit_code)"; return 1; }
    }
    subtest "Verify gate rejects no-op worker (exit 1, no stall)" verify_gate_rejects_noop

    # Clean up no-op worktree
    cleanup_noop() {
      local wt="$WS/.wrapix/worktree/gc-$BEAD5"
      rm -rf "$wt"
      git -C "$WS" worktree prune 2>/dev/null || true
      git -C "$WS" branch -D "gc-$BEAD5" 2>/dev/null || true
    }
    subtest "Clean up no-op worktree" cleanup_noop

    # ================================================================
    # worker-setup-collect: worker-setup.sh and worker-collect.sh
    # ================================================================

    subtest "Create worker-setup test bead" \
      bd create --title="Worker setup test" --type=task --priority=2

    BEAD6=$(bd list --json --title "Worker setup test" 2>/dev/null | jq -r '.[0].id')

    verify_worker_setup() {
      [ -n "$BEAD6" ] && [ "$BEAD6" != "null" ] || return 1
      GC_BEAD_ID="$BEAD6" GC_WORKSPACE="$WS" live worker-setup.sh >/dev/null

      local wt="$WS/.wrapix/worktree/gc-$BEAD6"
      [ -d "$wt" ] || { echo "FAIL: worktree not created at $wt"; return 1; }

      local status
      status="$(bd show "$BEAD6" --json 2>/dev/null | jq -r '.[0].status')"
      [ "$status" = "in_progress" ] || { echo "FAIL: status=$status, expected in_progress"; return 1; }

      [ -f "$wt/.task" ] || { echo "FAIL: .task file not created"; return 1; }

      [ -f "$WS/.wrapix/state/last-dispatch" ] || { echo "FAIL: last-dispatch not written"; return 1; }
    }
    subtest "worker-setup.sh creates worktree, claims bead, writes task file" verify_worker_setup

    # worker-collect.sh: happy path — commit on branch, verify metadata
    verify_worker_collect() {
      local wt="$WS/.wrapix/worktree/gc-$BEAD6"
      (cd "$wt" && echo "setup test fix" > setup-fix.txt && git add setup-fix.txt && git commit -m "fix: setup test")
      GC_BEAD_ID="$BEAD6" GC_WORKSPACE="$WS" live worker-collect.sh

      local cr
      cr="$(bd show "$BEAD6" --json 2>/dev/null | jq -r '.[0].metadata.commit_range // empty')"
      [ -n "$cr" ] || { echo "FAIL: commit_range not set"; return 1; }
      echo "  commit_range=$cr"

      local bn
      bn="$(bd show "$BEAD6" --json 2>/dev/null | jq -r '.[0].metadata.branch_name // empty')"
      [ "$bn" = "gc-$BEAD6" ] || { echo "FAIL: branch_name=$bn, expected gc-$BEAD6"; return 1; }
    }
    subtest "worker-collect.sh sets commit_range and branch_name" verify_worker_collect

    # worker-collect.sh: no-op path — empty branch, verify no metadata
    subtest "Create worker-collect no-op bead" \
      bd create --title="Collect no-op test" --type=task --priority=2

    BEAD7=$(bd list --json --title "Collect no-op test" 2>/dev/null | jq -r '.[0].id')

    verify_collect_noop() {
      [ -n "$BEAD7" ] && [ "$BEAD7" != "null" ] || return 1
      GC_BEAD_ID="$BEAD7" GC_WORKSPACE="$WS" live worker-setup.sh >/dev/null
      GC_BEAD_ID="$BEAD7" GC_WORKSPACE="$WS" live worker-collect.sh

      local cr
      cr="$(bd show "$BEAD7" --json 2>/dev/null | jq -r '.[0].metadata.commit_range // empty')"
      [ -z "$cr" ] || { echo "FAIL: commit_range should be empty for no-op (got: $cr)"; return 1; }
    }
    subtest "worker-collect.sh no-ops on empty branch" verify_collect_noop

    cleanup_phase6() {
      for b in "$BEAD6" "$BEAD7"; do
        local wt="$WS/.wrapix/worktree/gc-$b"
        [ -d "$wt" ] && rm -rf "$wt"
        git -C "$WS" worktree prune 2>/dev/null || true
        git -C "$WS" branch -D "gc-$b" 2>/dev/null || true
      done
    }
    subtest "Clean up worker-setup-collect" cleanup_phase6

    # ================================================================
    # rebase-success: main advanced, rebase works, merge
    # ================================================================

    subtest "Create rebase-success bead" \
      bd create --title="Rebase success test" --type=bug --priority=2

    BEAD8=$(bd list --json --title "Rebase success test" 2>/dev/null | jq -r '.[0].id')

    setup_rebase_success() {
      [ -n "$BEAD8" ] && [ "$BEAD8" != "null" ] || return 1
      # Worker branches from current HEAD
      GC_BEAD_ID="$BEAD8" GC_WORKSPACE="$WS" live worker-setup.sh >/dev/null
      local wt="$WS/.wrapix/worktree/gc-$BEAD8"

      # Worker commits on its branch
      (cd "$wt" && echo "rebase fix" > rebase-fix.txt && git add rebase-fix.txt && git commit -m "fix: rebase success test")

      # Main advances with a NON-conflicting change (different file).
      # Verify checkout succeeded — inside subtest() set -e is disabled,
      # so a stale index.lock from a dying monitor pipeline would cause
      # checkout to fail silently and the commit to land on the wrong branch.
      git -C "$WS" checkout main 2>/dev/null
      local current_branch
      current_branch="$(git -C "$WS" rev-parse --abbrev-ref HEAD)"
      [[ "$current_branch" == "main" ]] || { echo "FAIL: checkout main failed, HEAD on $current_branch"; return 1; }
      (cd "$WS" && echo "parallel change" > parallel.txt && git add parallel.txt && git commit -m "parallel: non-conflicting advance")

      # Collect metadata
      GC_BEAD_ID="$BEAD8" GC_WORKSPACE="$WS" live worker-collect.sh
      bd update "$BEAD8" --set-metadata "review_verdict=approve"
    }
    subtest "Set up diverged branch (non-conflicting)" setup_rebase_success

    judge_merge_rebase_success() {
      # Stub prek — this test exercises rebase+merge, not pre-commit hooks.
      # judge-merge.sh guards with `command -v prek` so stubbing is safe.
      local stub_dir
      stub_dir="$(mktemp -d)"
      printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_dir/prek"
      chmod +x "$stub_dir/prek"
      local exit_code=0
      PATH="$stub_dir:$LIVE_PATH" GC_BEAD_ID="$BEAD8" GC_WORKSPACE="$WS" \
        bash "$WS/.gc/scripts/judge-merge.sh" 2>&1 || exit_code=$?
      rm -rf "$stub_dir"
      [ "$exit_code" -eq 0 ] || { echo "FAIL: judge-merge should exit 0 on rebase success (got: $exit_code)"; return 1; }
    }
    subtest "Judge rebases and merges diverged branch" judge_merge_rebase_success

    verify_rebase_merge_landed() {
      git -C "$WS" log --oneline main | grep -q "rebase success test"
    }
    subtest "Verify rebased commit landed on main" verify_rebase_merge_landed

    verify_rebase_linear_history() {
      # After rebase+ff-merge, history must be linear (no merge commits)
      local merge_commits
      merge_commits="$(git -C "$WS" log --merges --oneline main | wc -l)"
      [ "$merge_commits" -eq 0 ] || { echo "FAIL: found $merge_commits merge commits, expected linear history"; return 1; }
    }
    subtest "Verify linear history after rebase merge" verify_rebase_linear_history

    subtest "Verify rebase worktree cleaned up" \
      test ! -d "$WS/.wrapix/worktree/gc-$BEAD8"

    verify_rebase_branch_cleaned() {
      ! git -C "$WS" branch | grep "gc-$BEAD8"
    }
    subtest "Verify rebase branch cleaned up" verify_rebase_branch_cleaned

    # ================================================================
    # gate-approve-reject: approve and reject verdicts
    # gate.sh calls real gc session nudge — no stubs (wx-9gm3t)
    # ================================================================

    # Restart gc daemon so gate.sh's gc session nudge uses the live path.
    restart_gc_for_gate() {
      podman rm -f gc-test-city-mayor gc-test-city-scout gc-test-city-judge 2>/dev/null || true
      setsid env PATH="$LIVE_PATH" GC_NUDGE_IDLE_TIMEOUT=1 "$WS/.gc/scripts/entrypoint.sh" >"$WS/gc-gate.log" 2>&1 &
      GC_PID=$!
      poll_until 'test -S "$WS/.gc/home/.gc/controller.sock" || ! kill -0 "$GC_PID" 2>/dev/null' 15
      if ! kill -0 "$GC_PID" 2>/dev/null; then
        echo "gc daemon died before gate tests:"
        tail -40 "$WS/gc-gate.log" 2>/dev/null | sed 's/^/  /' || true
        return 1
      fi
    }
    subtest "Restart gc for gate tests" restart_gc_for_gate

    subtest "Create gate-approve bead" \
      bd create --title="Gate approve test" --type=task --priority=2

    BEAD9=$(bd list --json --title "Gate approve test" 2>/dev/null | jq -r '.[0].id')

    setup_gate_test() {
      [ -n "$BEAD9" ] && [ "$BEAD9" != "null" ] || return 1
      bd update "$BEAD9" --status=in_progress
      bd update "$BEAD9" --set-metadata "commit_range=abc..def"
      bd update "$BEAD9" --set-metadata "review_verdict=approve"
    }
    subtest "Set up gate approve test" setup_gate_test

    verify_gate_approve() {
      local exit_code=0
      PATH="$LIVE_PATH" GC_BEAD_ID="$BEAD9" GC_POLL_INTERVAL=0 GC_POLL_TIMEOUT=5 \
        bash "$WS/.gc/scripts/gate.sh" >/dev/null 2>&1 || exit_code=$?
      [ "$exit_code" -eq 0 ] || { echo "FAIL: gate should exit 0 on approve (got: $exit_code)"; return 1; }
    }
    subtest "Gate exits 0 on approve verdict" verify_gate_approve

    subtest "Create gate-reject bead" \
      bd create --title="Gate reject test" --type=task --priority=2

    BEAD10=$(bd list --json --title "Gate reject test" 2>/dev/null | jq -r '.[0].id')

    setup_gate_reject() {
      [ -n "$BEAD10" ] && [ "$BEAD10" != "null" ] || return 1
      bd update "$BEAD10" --status=in_progress
      bd update "$BEAD10" --set-metadata "commit_range=abc..def"
      bd update "$BEAD10" --set-metadata "review_verdict=reject"
    }
    subtest "Set up gate reject test" setup_gate_reject

    verify_gate_reject() {
      local exit_code=0
      PATH="$LIVE_PATH" GC_BEAD_ID="$BEAD10" GC_POLL_INTERVAL=0 GC_POLL_TIMEOUT=5 \
        bash "$WS/.gc/scripts/gate.sh" >/dev/null 2>&1 || exit_code=$?
      [ "$exit_code" -eq 1 ] || { echo "FAIL: gate should exit 1 on reject (got: $exit_code)"; return 1; }
    }
    subtest "Gate exits 1 on reject verdict" verify_gate_reject

    # Stop gc after gate tests
    stop_gc_after_gate() {
      if [ -n "$GC_PID" ] && kill -0 "$GC_PID" 2>/dev/null; then
        kill -TERM -"$GC_PID" 2>/dev/null || true
        for _ in $(seq 1 100); do
          kill -0 "$GC_PID" 2>/dev/null || break
          sleep 0.1
        done
        kill -9 -"$GC_PID" 2>/dev/null || true
        wait "$GC_PID" 2>/dev/null || true
      fi
      for cid in $(podman ps -a --filter "name=gc-test-city-" -q 2>/dev/null); do
        podman stop -t 3 "$cid" 2>/dev/null || true
        podman rm -f "$cid" 2>/dev/null || true
      done
      GC_PID=""
      beads-dolt start "$WS" >/dev/null 2>&1 || true
      for _i in $(seq 1 50); do
        bash -c "echo > /dev/tcp/127.0.0.1/$DOLT_PORT" 2>/dev/null && break
        sleep 0.2
      done
    }
    subtest "Stop gc after gate tests" stop_gc_after_gate

    # ================================================================
    # dispatch-cooldown: cooldown-aware worker scale check
    # ================================================================

    subtest "Create dispatch bead" \
      bd create --title="Dispatch cooldown test" --type=bug --priority=2

    BEAD_DISPATCH=$(bd list --json --title "Dispatch cooldown test" 2>/dev/null | jq -r '.[0].id')

    setup_dispatch() {
      [ -n "$BEAD_DISPATCH" ] && [ "$BEAD_DISPATCH" != "null" ] || return 1
      bd update "$BEAD_DISPATCH" --set-metadata "gc.routed_to=worker"
    }
    subtest "Route dispatch bead to worker" setup_dispatch

    verify_dispatch_no_cooldown() {
      # With cooldown=0, dispatch.sh is a passthrough to bd list
      local count
      count="$(GC_COOLDOWN=0 GC_WORKSPACE="$WS" live dispatch.sh)"
      [ "$count" -ge 1 ] || { echo "FAIL: dispatch should count >=1 bead (got: $count)"; return 1; }
    }
    subtest "dispatch.sh counts beads with no cooldown" verify_dispatch_no_cooldown

    verify_dispatch_cooldown_blocks() {
      # Set last-dispatch to now — cooldown should block
      mkdir -p "$WS/.wrapix/state"
      date +%s > "$WS/.wrapix/state/last-dispatch"
      local count
      count="$(GC_COOLDOWN=1h GC_WORKSPACE="$WS" live dispatch.sh)"
      [ "$count" -eq 0 ] || { echo "FAIL: dispatch should return 0 during cooldown (got: $count)"; return 1; }
    }
    subtest "dispatch.sh respects cooldown timer" verify_dispatch_cooldown_blocks

    verify_dispatch_p0_bypasses_cooldown() {
      # P0 beads bypass cooldown
      bd update "$BEAD_DISPATCH" --priority=0
      local count
      count="$(GC_COOLDOWN=1h GC_WORKSPACE="$WS" live dispatch.sh)"
      [ "$count" -ge 1 ] || { echo "FAIL: P0 should bypass cooldown (got: $count)"; return 1; }
      bd update "$BEAD_DISPATCH" --priority=2
    }
    subtest "dispatch.sh P0 bypasses cooldown" verify_dispatch_p0_bypasses_cooldown

    verify_dispatch_backpressure() {
      # Backpressure file with future timestamp blocks all dispatch
      mkdir -p "$WS/.wrapix/state"
      echo "$(( $(date +%s) + 3600 ))" > "$WS/.wrapix/state/rate-limited"
      local count
      count="$(GC_COOLDOWN=0 GC_WORKSPACE="$WS" live dispatch.sh)"
      [ "$count" -eq 0 ] || { echo "FAIL: backpressure should block dispatch (got: $count)"; return 1; }
      rm -f "$WS/.wrapix/state/rate-limited"
    }
    subtest "dispatch.sh respects backpressure" verify_dispatch_backpressure

    cleanup_dispatch() {
      rm -f "$WS/.wrapix/state/last-dispatch" "$WS/.wrapix/state/rate-limited"
      bd close "$BEAD_DISPATCH" 2>/dev/null || true
    }
    subtest "Clean up dispatch test" cleanup_dispatch

    # ================================================================
    # post-gate-close-bead: approved convergence closes work bead
    # ================================================================

    subtest "Create post-gate-close bead" \
      bd create --title="Post-gate close test" --type=bug --priority=2

    BEAD11=$(bd list --json --title "Post-gate close test" 2>/dev/null | jq -r '.[0].id')

    setup_post_gate_close() {
      [ -n "$BEAD11" ] && [ "$BEAD11" != "null" ] || return 1
      bd update "$BEAD11" --status=in_progress
    }
    subtest "Set up post-gate close test" setup_post_gate_close

    run_post_gate_close() {
      GC_BEAD_ID="$BEAD11" \
      GC_TERMINAL_REASON="approved" \
      GC_WORKSPACE="$WS" \
      GC_CITY_NAME="test-city" \
        live post-gate.sh
    }
    subtest "Run post-gate with approved reason" run_post_gate_close

    verify_post_gate_closed_bead() {
      local status
      status="$(bd show "$BEAD11" --json 2>/dev/null | jq -r '.[0].status')"
      [ "$status" = "closed" ] || { echo "FAIL: bead status=$status, expected closed"; return 1; }
    }
    subtest "Verify post-gate closed work bead" verify_post_gate_closed_bead

    # ================================================================
    # retry-judge-notes: task file includes judge rejection notes
    # ================================================================

    subtest "Create retry-notes bead" \
      bd create --title="Retry notes test" --type=bug --priority=2 \
        --description="Fix the flaky parser"

    BEAD12=$(bd list --json --title "Retry notes test" 2>/dev/null | jq -r '.[0].id')

    setup_retry_notes() {
      [ -n "$BEAD12" ] && [ "$BEAD12" != "null" ] || return 1
      # Simulate judge rejection with merge_failure notes
      bd update "$BEAD12" --set-metadata "merge_failure=Rebase conflicts: CONFLICT in parser.sh"
    }
    subtest "Set up bead with prior rejection notes" setup_retry_notes

    verify_task_includes_rejection() {
      GC_BEAD_ID="$BEAD12" GC_WORKSPACE="$WS" live worker-setup.sh >/dev/null
      local wt="$WS/.wrapix/worktree/gc-$BEAD12"
      [ -f "$wt/.task" ] || { echo "FAIL: .task file not created"; return 1; }

      grep -q "flaky parser" "$wt/.task" || { echo "FAIL: .task missing bead description"; cat "$wt/.task"; return 1; }
      grep -q "Prior Rejection" "$wt/.task" || { echo "FAIL: .task missing Prior Rejection section"; cat "$wt/.task"; return 1; }
      grep -q "CONFLICT in parser.sh" "$wt/.task" || { echo "FAIL: .task missing conflict details"; cat "$wt/.task"; return 1; }
    }
    subtest "Task file includes prior rejection notes" verify_task_includes_rejection

    cleanup_phase10() {
      local wt="$WS/.wrapix/worktree/gc-$BEAD12"
      [ -d "$wt" ] && rm -rf "$wt"
      git -C "$WS" worktree prune 2>/dev/null || true
      git -C "$WS" branch -D "gc-$BEAD12" 2>/dev/null || true
    }
    subtest "Clean up retry-judge-notes" cleanup_phase10

    # ================================================================
    # recovery-orphan-worktree: closed bead → recovery cleans worktree
    # ================================================================

    subtest "Create orphan-cleanup bead" \
      bd create --title="Orphan cleanup test" --type=bug --priority=2

    BEAD13=$(bd list --json --title "Orphan cleanup test" 2>/dev/null | jq -r '.[0].id')

    setup_orphan_worktree() {
      [ -n "$BEAD13" ] && [ "$BEAD13" != "null" ] || return 1
      GC_BEAD_ID="$BEAD13" GC_WORKSPACE="$WS" live worker-setup.sh >/dev/null
      local wt="$WS/.wrapix/worktree/gc-$BEAD13"
      [ -d "$wt" ] || { echo "FAIL: worktree not created"; return 1; }

      # Close the bead — worktree is now orphaned
      bd close "$BEAD13"
    }
    subtest "Create worktree then close its bead (orphan)" setup_orphan_worktree

    run_recovery_orphan() {
      GC_CITY_NAME="test-city" GC_WORKSPACE="$WS" live recovery.sh
    }
    subtest "Run recovery.sh for orphan cleanup" run_recovery_orphan

    verify_orphan_worktree_cleaned() {
      [ ! -d "$WS/.wrapix/worktree/gc-$BEAD13" ] || { echo "FAIL: orphaned worktree still exists"; return 1; }
    }
    subtest "Verify orphaned worktree cleaned up by recovery" verify_orphan_worktree_cleaned

    verify_orphan_branch_cleaned() {
      ! git -C "$WS" branch | grep "gc-$BEAD13"
    }
    subtest "Verify orphaned branch cleaned up by recovery" verify_orphan_branch_cleaned

    # ================================================================
    # phantom-dog-suppressed: dog agent max=0 override (wx-m7a1d)
    #
    # System packs define a dog agent (max=3). The city.toml override
    # sets max_active_sessions=0, preventing gc from creating any dog
    # sessions. Pack stripping is not possible (gc populates packs at
    # startup), so the config override is the sole defense.
    # ================================================================

    verify_no_phantom_dog() {
      local resolved
      resolved="$(gc config show --city "$WS/.gc/home" 2>&1)"
      # The dog override must be present with max_active_sessions = 0
      if ! echo "$resolved" | grep -A5 'name = "dog"' | grep -q 'max_active_sessions = 0'; then
        echo "FAIL: dog agent override missing or max_active_sessions != 0"
        echo "$resolved" | grep -A10 'name = "dog"'
        return 1
      fi
    }
    subtest "Dog agent override has max_active_sessions=0 (wx-m7a1d)" verify_no_phantom_dog

    # ================================================================
    # provider-stripped-from-config: workspace.provider removed (wx-y4tx2)
    #
    # A stale workspace.provider="claude" causes gc to use its built-in
    # tmux provider for display commands instead of the exec provider.
    # entrypoint.sh and stage-gc-home.sh strip the field defensively.
    # ================================================================

    verify_no_workspace_provider() {
      # Inject a stale workspace.provider into the workspace city.toml,
      # then re-run stage-gc-home.sh and verify it's stripped.
      local test_toml="$WS/city.toml.test-y4tx2"
      cp "$WS/city.toml" "$test_toml"
      # Add provider = "claude" under [workspace] if not already there
      sed -i '/^\[workspace\]/a provider = "claude"' "$test_toml"
      # Verify we injected it
      grep -q 'provider = "claude"' "$test_toml" || { echo "FAIL: could not inject test provider"; return 1; }

      # stage-gc-home reads from $GC_WORKSPACE/city.toml — use a temp workspace
      local stage_tmp
      stage_tmp="$(mktemp -d)"
      cp "$test_toml" "$stage_tmp/city.toml"
      mkdir -p "$stage_tmp/.beads" "$stage_tmp/.gc"
      touch "$stage_tmp/.beads/config.yaml"
      git init -q "$stage_tmp"

      local staged_home
      staged_home="$(GC_WORKSPACE="$stage_tmp" GC_DOLT_PORT=99999 live stage-gc-home.sh)"
      if grep -q 'provider = "claude"' "$staged_home/city.toml"; then
        echo "FAIL: workspace.provider not stripped from staged city.toml"
        grep provider "$staged_home/city.toml"
        rm -rf "$stage_tmp"
        return 1
      fi
      rm -rf "$stage_tmp"
      rm -f "$test_toml"
    }
    subtest "workspace.provider stripped from city.toml (wx-y4tx2)" verify_no_workspace_provider

    verify_gc_home_no_workspace_provider() {
      # The live gc home (staged by entrypoint) must not have workspace.provider
      if grep -q 'provider = "claude"' "$WS/.gc/home/city.toml" 2>/dev/null; then
        echo "FAIL: gc home city.toml has workspace.provider"
        grep provider "$WS/.gc/home/city.toml"
        return 1
      fi
    }
    subtest "gc home city.toml has no workspace.provider (wx-y4tx2)" verify_gc_home_no_workspace_provider

    # ================================================================
    # provider-worker-name-routing: agent_template detection (wx-aqe4z)
    #
    # gc may assign session names that don't contain "worker" (e.g.
    # bead-id based names). The provider must detect workers from the
    # start data's agent_template field, not just name patterns.
    # ================================================================

    verify_worker_detection_by_template() {
      # Simulate gc calling provider.sh start with a non-worker-named session
      # but agent_template=worker in the start JSON. Verify it uses worker_start
      # (creates worktree) rather than persistent_start (tmux).
      local test_bead
      bd create --title="Worker detection test" --type=task --priority=2
      test_bead=$(bd list --json --title "Worker detection test" 2>/dev/null | jq -r '.[0].id')
      [ -n "$test_bead" ] && [ "$test_bead" != "null" ] || { echo "FAIL: could not create test bead"; return 1; }
      bd update "$test_bead" --set-metadata "gc.routed_to=worker"

      # Call provider start with a bead-id-style session name and
      # agent_template=worker in stdin JSON. If the provider correctly
      # detects the worker template, it will call worker_start (which
      # creates a worktree). If not, it calls persistent_start (which
      # tries tmux and fails).
      local start_json='{"agent_template":"worker","bead_id":"'"$test_bead"'"}'
      local exit_code=0

      GC_BEAD_ID="$test_bead" \
      GC_CITY_NAME="test-city" \
      GC_WORKSPACE="$WS" \
      GC_AGENT_IMAGE="${liveCity.imageName}" \
      GC_PODMAN_NETWORK="$TEST_NETWORK" \
      GC_BEADS_DOLT_CONTAINER="$DOLT_CONTAINER" \
      BEADS_DOLT_SERVER_PORT="$DOLT_PORT" \
        bash -c "echo '$start_json' | PATH=\"$LIVE_PATH\" bash $WS/.gc/scripts/provider.sh start $test_bead" \
        2>&1 || exit_code=$?

      if [ "$exit_code" -ne 0 ]; then
        echo "FAIL: provider start failed (exit $exit_code) — likely routed to persistent_start"
        return 1
      fi

      # Verify worktree was created (worker_start creates it, persistent_start doesn't)
      if [ ! -d "$WS/.wrapix/worktree/gc-$test_bead" ]; then
        echo "FAIL: worktree not created — provider used persistent_start instead of worker_start"
        return 1
      fi

      # Clean up
      podman stop "gc-test-city-$test_bead" 2>/dev/null || true
      podman rm -f "gc-test-city-$test_bead" 2>/dev/null || true
      rm -rf "$WS/.wrapix/worktree/gc-$test_bead"
      git -C "$WS" worktree prune 2>/dev/null || true
      git -C "$WS" branch -D "gc-$test_bead" 2>/dev/null || true
    }
    subtest "Provider detects worker from agent_template, not name (wx-aqe4z)" verify_worker_detection_by_template

    verify_name_based_worker_still_works() {
      # Verify the existing name-based detection still works (regression check).
      # A session named "worker-test" should always be detected as a worker.
      # Re-ensure network exists — the previous test's container cleanup can
      # leave netavark in a state where the network bridge is torn down.
      podman network create "$TEST_NETWORK" >/dev/null 2>&1 || true
      local test_bead
      bd create --title="Name-based worker test" --type=task --priority=2
      test_bead=$(bd list --json --title "Name-based worker test" 2>/dev/null | jq -r '.[0].id')
      [ -n "$test_bead" ] && [ "$test_bead" != "null" ] || { echo "FAIL: could not create test bead"; return 1; }
      bd update "$test_bead" --set-metadata "gc.routed_to=worker"

      local exit_code=0
      GC_BEAD_ID="$test_bead" \
      GC_CITY_NAME="test-city" \
      GC_WORKSPACE="$WS" \
      GC_AGENT_IMAGE="${liveCity.imageName}" \
      GC_PODMAN_NETWORK="$TEST_NETWORK" \
      GC_BEADS_DOLT_CONTAINER="$DOLT_CONTAINER" \
      BEADS_DOLT_SERVER_PORT="$DOLT_PORT" \
        bash -c "echo '{}' | PATH=\"$LIVE_PATH\" bash $WS/.gc/scripts/provider.sh start worker-$test_bead" \
        2>&1 || exit_code=$?

      if [ "$exit_code" -ne 0 ]; then
        echo "FAIL: name-based worker detection failed (exit $exit_code)"
        return 1
      fi

      if [ ! -d "$WS/.wrapix/worktree/gc-$test_bead" ]; then
        echo "FAIL: worktree not created for name-based worker"
        return 1
      fi

      # Clean up
      podman stop "gc-test-city-worker-$test_bead" 2>/dev/null || true
      podman rm -f "gc-test-city-worker-$test_bead" 2>/dev/null || true
      rm -rf "$WS/.wrapix/worktree/gc-$test_bead"
      git -C "$WS" worktree prune 2>/dev/null || true
      git -C "$WS" branch -D "gc-$test_bead" 2>/dev/null || true
    }
    subtest "Name-based worker detection still works (wx-aqe4z)" verify_name_based_worker_still_works

    # ================================================================
    # provider-extracts-issue: issue field from start JSON (wx-fsqcz)
    #
    # When gc starts a worker via a formula, the start JSON contains an
    # "issue" field with the bead ID. provider.sh must extract it and
    # export GC_BEAD_ID so worker-setup.sh resolves the correct bead
    # instead of falling back to a racey bd list query.
    # ================================================================

    verify_provider_extracts_issue() {
      local test_bead
      bd create --title="Issue extraction test" --type=task --priority=2
      test_bead=$(bd list --json --title "Issue extraction test" 2>/dev/null | jq -r '.[0].id')
      [ -n "$test_bead" ] && [ "$test_bead" != "null" ] || { echo "FAIL: could not create test bead"; return 1; }
      bd update "$test_bead" --set-metadata "gc.routed_to=worker"

      # Start JSON with both agent_template and issue — mimics gc's real
      # start payload when a formula routes a specific bead to a worker.
      local start_json='{"agent_template":"worker","issue":"'"$test_bead"'"}'
      local exit_code=0

      # Do NOT set GC_BEAD_ID in the env — worker-setup.sh must get it
      # from the issue field that provider.sh extracts and exports.
      GC_CITY_NAME="test-city" \
      GC_WORKSPACE="$WS" \
      GC_AGENT_IMAGE="${liveCity.imageName}" \
      GC_PODMAN_NETWORK="$TEST_NETWORK" \
      GC_BEADS_DOLT_CONTAINER="$DOLT_CONTAINER" \
      BEADS_DOLT_SERVER_PORT="$DOLT_PORT" \
        bash -c "echo '$start_json' | PATH=\"$LIVE_PATH\" bash $WS/.gc/scripts/provider.sh start issue-$test_bead" \
        2>&1 || exit_code=$?

      if [ "$exit_code" -ne 0 ]; then
        echo "FAIL: provider start failed (exit $exit_code)"
        return 1
      fi

      # Verify the correct worktree was created (keyed by bead ID, not session name)
      if [ ! -d "$WS/.wrapix/worktree/gc-$test_bead" ]; then
        echo "FAIL: worktree not created for bead $test_bead — issue field not extracted"
        return 1
      fi

      # Clean up
      podman stop "gc-test-city-issue-$test_bead" 2>/dev/null || true
      podman rm -f "gc-test-city-issue-$test_bead" 2>/dev/null || true
      rm -rf "$WS/.wrapix/worktree/gc-$test_bead"
      git -C "$WS" worktree prune 2>/dev/null || true
      git -C "$WS" branch -D "gc-$test_bead" 2>/dev/null || true
    }
    subtest "Provider extracts issue from start JSON (wx-fsqcz)" verify_provider_extracts_issue

    # ================================================================
    # agent-max-sessions: pool agents have max_active_sessions (wx-65bws)
    #
    # Verify the resolved gc config has max_active_sessions on worker,
    # scout, and judge — without it, gc treats them as named singles
    # and the reconciler never creates pool sessions.
    # ================================================================

    verify_pool_agent_max_sessions() {
      local resolved
      resolved="$(gc config show --city "$WS/.gc/home" 2>&1)"

      for role in worker scout judge; do
        if ! echo "$resolved" | grep -A10 "name = \"$role\"" | grep -q 'max_active_sessions'; then
          echo "FAIL: $role agent missing max_active_sessions in resolved config"
          echo "$resolved" | grep -A10 "name = \"$role\""
          return 1
        fi
      done

      # Worker should have max_active_sessions = workers (2 in test config)
      local worker_max
      worker_max="$(echo "$resolved" | grep -A10 'name = "worker"' | grep 'max_active_sessions' | head -1 | grep -o '[0-9]*')"
      if [ "$worker_max" != "2" ]; then
        echo "FAIL: worker max_active_sessions=$worker_max, expected 2"
        return 1
      fi
    }
    subtest "Agent templates have max_active_sessions (wx-65bws)" verify_pool_agent_max_sessions

    # ================================================================
    # config-drift-kills-stale: entrypoint kills stale containers (wx-i42sb)
    #
    # Exercise the live entrypoint config drift path: start a labeled
    # container (simulating a leftover from a previous gc run), write a
    # config.hash with the old hash, mutate city.toml, then restart the
    # entrypoint. The entrypoint compares hashes and kills all containers
    # with the gc-city label before starting gc.
    # ================================================================

    config_drift_setup() {
      # Start a labeled container simulating a leftover persistent session.
      podman run -d --replace \
        --name gc-test-city-stale-scout \
        --entrypoint "" \
        --network "$TEST_NETWORK" \
        --label "gc-city=test-city" \
        "${liveCity.imageName}" sleep 3600

      # The happy-path entrypoint wrote .gc/config.hash with the current
      # city.toml hash. That file is the "previous run" state. Now mutate
      # city.toml so the next entrypoint run sees a different hash.
      echo "# drift-marker $(date +%s)" >> "$WS/city.toml"

      # Verify precondition: stale container is running
      if [[ "$(podman inspect --format '{{.State.Running}}' gc-test-city-stale-scout 2>/dev/null)" != "true" ]]; then
        echo "FAIL: stale container should be running before entrypoint"
        return 1
      fi
    }
    subtest "Config drift: set up stale container" config_drift_setup

    config_drift_restart() {
      DOLT_CONTAINER="$(beads-dolt name "$WS")"
      DOLT_PORT="$(beads-dolt port "$WS")"

      export GC_CITY_NAME="test-city"
      export GC_WORKSPACE="$WS"
      export GC_AGENT_IMAGE="${liveCity.imageName}"
      export GC_PODMAN_NETWORK="$TEST_NETWORK"

      # Run the live entrypoint — stages gc home (picks up mutated
      # city.toml), detects hash mismatch, kills stale containers,
      # writes new hash, starts gc.
      setsid env PATH="$LIVE_PATH" "$WS/.gc/scripts/entrypoint.sh" >"$WS/drift.log" 2>&1 &
      DRIFT_PID=$!

      # Wait for drift detection or gc start
      for _i in $(seq 1 60); do
        if grep -q "Config drift detected" "$WS/drift.log" 2>/dev/null || \
           grep -q "City started" "$WS/drift.log" 2>/dev/null || \
           ! kill -0 "$DRIFT_PID" 2>/dev/null; then
          break
        fi
        sleep 0.5
      done

      # Poll until the stale container is stopped (rather than sleeping a fixed interval)
      poll_until '! podman inspect --format "{{.State.Running}}" gc-test-city-stale-scout 2>/dev/null | grep -q true' 15
      echo "  PASS: stale container killed"

      # Verify the entrypoint logged the drift
      if ! grep -q "Config drift detected" "$WS/drift.log" 2>/dev/null; then
        echo "FAIL: no drift log message in entrypoint output"
        cat "$WS/drift.log" | sed 's/^/  /'
        kill -TERM -"$DRIFT_PID" 2>/dev/null || true
        return 1
      fi
      echo "  PASS: drift detection logged"

      # Verify config.hash was updated to new value
      local hash_file="$WS/.gc/config.hash"
      if [[ ! -f "$hash_file" ]]; then
        echo "FAIL: config.hash not written"
        kill -TERM -"$DRIFT_PID" 2>/dev/null || true
        return 1
      fi
      echo "  PASS: config.hash updated"

      # Clean up: stop the entrypoint
      kill -TERM -"$DRIFT_PID" 2>/dev/null || true
      for _ in $(seq 1 30); do
        kill -0 "$DRIFT_PID" 2>/dev/null || break
        sleep 0.2
      done
      kill -9 -"$DRIFT_PID" 2>/dev/null || true
      wait "$DRIFT_PID" 2>/dev/null || true

      # Clean up containers
      podman rm -f gc-test-city-stale-scout 2>/dev/null || true
      for cid in $(podman ps -a --filter "name=gc-test-city-" -q 2>/dev/null); do
        podman stop -t 3 "$cid" 2>/dev/null || true
        podman rm -f "$cid" 2>/dev/null || true
      done
    }
    subtest "Config drift: entrypoint kills stale containers (wx-i42sb)" config_drift_restart
  '';

in
{
  # Script derivation — consumed by tests/default.nix to build the app
  script = testScript;
}
