# Test entry point - exports checks and test runner app
{
  pkgs,
  system,
  src,
}:

let
  inherit (builtins) elem pathExists;
  inherit (pkgs) writeShellScriptBin;

  isDarwin = system == "aarch64-darwin";
  isLinux = elem system [
    "x86_64-linux"
    "aarch64-linux"
  ];

  # Check if KVM is available (for VM integration tests)
  # This is impure - requires `nix flake check --impure`
  hasKvm = pathExists "/dev/kvm";

  # ============================================================================
  # Pure Nix Checks (run via `nix flake check`)
  # ============================================================================

  # Smoke tests run on all platforms
  smokeTests = import ./smoke.nix { inherit pkgs system; };

  # Darwin mount tests run on all platforms (test logic, not VM)
  darwinMountTests = import ./darwin/mounts.nix { inherit pkgs system; };

  # Darwin network tests run on all platforms (test logic, not VM)
  darwinNetworkTests = import ./darwin/network.nix { inherit pkgs system; };

  # Darwin UID mapping tests (verify unshare-based VirtioFS ownership fix)
  darwinUidTests = import ./darwin/uid.nix { inherit pkgs system; };

  # Integration tests require NixOS VM (Linux with KVM only)
  # Skip when KVM unavailable (e.g., inside containers)
  integrationTests =
    if isLinux && hasKvm then import ./integration.nix { inherit pkgs system; } else { };

  # Ralph utility function tests run on all platforms
  ralphTests = import ./ralph { inherit pkgs system; };

  # Ralph template validation check (runs as part of nix flake check)
  # Uses mkTemplatesCheck from lib/ralph to validate all templates
  ralphTemplatesCheck =
    let
      ralph = import ../lib/ralph {
        inherit pkgs;
        mkSandbox = null; # not needed for template validation
      };
    in
    {
      ralph-templates = ralph.mkTemplatesCheck;
    };

  # Shell utility tests run on all platforms
  shellTests = import ./shell.nix { inherit pkgs system; };

  # tmux-mcp tests (Rust unit tests and shell script syntax)
  tmuxMcpTests = import ./tmux-mcp.nix { inherit pkgs system src; };

  # Lint checks run on all platforms
  lintChecks = import ./lint.nix { inherit pkgs src; };

  # README example verification
  readmeTest = {
    readme = import ./readme.nix { inherit pkgs src; };
  };

  # All checks combined
  checks =
    smokeTests
    // darwinMountTests
    // darwinNetworkTests
    // darwinUidTests
    // integrationTests
    // ralphTests
    // ralphTemplatesCheck
    // shellTests
    // tmuxMcpTests
    // lintChecks
    // readmeTest;

  # ============================================================================
  # Integration Test Runners (require runtime environment)
  # ============================================================================

  # Darwin container integration tests
  darwinIntegrationTests = import ./darwin { inherit pkgs system; };

  # Ralph workflow integration tests (with mock-claude)
  # Copy entire ralph test directory to store so run-tests.sh can find mock-claude and scenarios
  ralphTestDir = pkgs.runCommandLocal "ralph-test-dir" { } ''
    cp -r ${./ralph} $out
    chmod +x $out/run-tests.sh $out/mock-claude $out/scenarios/*.sh
  '';

  # Get ralph scripts for RALPH_METADATA_DIR (contains variables.json, templates.json)
  ralphModule = import ../lib/ralph {
    inherit pkgs;
    mkSandbox = null;
  };

  ralphIntegrationTests = writeShellScriptBin "test-ralph-integration" ''
    set -euo pipefail
    export REPO_ROOT="${src}"
    export RALPH_METADATA_DIR="${ralphModule.scripts}/share/ralph"
    export RALPH_TEMPLATE_DIR="${src}/lib/ralph/template"
    exec ${ralphTestDir}/run-tests.sh
  '';

  # Builder integration tests (Darwin only)
  builderIntegrationTests = writeShellScriptBin "test-builder" ''
    set -euo pipefail
    exec ${./builder-test.sh}
  '';

  # ============================================================================
  # Individual Test Runner Apps
  # ============================================================================

  # Lint-only tests (fast: ~5s)
  testLint = writeShellScriptBin "test-lint" ''
    set -euo pipefail
    echo "=== Lint Checks ==="
    echo ""
    echo "Running: nix flake check (lint only)"
    echo "This runs nixfmt, shellcheck, and statix checks."
    echo ""
    # Build only the lint checks
    ${pkgs.nix}/bin/nix build --no-link \
      .#checks.${system}.nixfmt \
      .#checks.${system}.shellcheck \
      .#checks.${system}.statix
    echo "PASS: All lint checks"
  '';

  # Ralph integration tests only (no flake check)
  testRalph = writeShellScriptBin "test-ralph" ''
    set -euo pipefail
    echo "=== Ralph Integration Tests ==="
    echo ""
    if command -v bd &>/dev/null && command -v ralph-run &>/dev/null; then
      ${ralphIntegrationTests}/bin/test-ralph-integration
    else
      echo "SKIP: Ralph integration tests (bd or ralph-run not in PATH)"
      echo "Run from devShell: nix develop"
      exit 1
    fi
  '';

  # ============================================================================
  # Unified Test Runner App
  # ============================================================================

  testAll = writeShellScriptBin "test-all" ''
    set -euo pipefail

    FAILED=0
    SKIPPED_TESTS=""

    echo "=== Wrapix Test Suite ==="
    echo ""

    # ----------------------------------------
    # Nix Flake Checks (skipped - already run by nix flake check)
    # ----------------------------------------
    # NOTE: Removed embedded "nix flake check" call.
    # If you ran "nix run .#test", the checks were already built.
    # Run "nix flake check" separately if you want lint/smoke checks.
    # This saves ~50s by avoiding redundant evaluation.

    # ----------------------------------------
    # Ralph Integration Tests
    # ----------------------------------------
    echo "----------------------------------------"
    echo "Running: Ralph Integration Tests"
    echo "----------------------------------------"
    if command -v bd &>/dev/null && command -v ralph-run &>/dev/null; then
      if ${ralphIntegrationTests}/bin/test-ralph-integration; then
        echo "PASS: Ralph integration tests"
      else
        echo "FAIL: Ralph integration tests"
        FAILED=1
      fi
    else
      echo "SKIP: Ralph integration tests (bd or ralph-run not in PATH)"
      SKIPPED_TESTS="$SKIPPED_TESTS ralph"
    fi
    echo ""

    # ----------------------------------------
    # Darwin Integration Tests
    # ----------------------------------------
    echo "----------------------------------------"
    echo "Running: Darwin Integration Tests"
    echo "----------------------------------------"
    ${
      if isDarwin then
        ''
          if ${darwinIntegrationTests}/bin/test-darwin; then
            echo "PASS: Darwin integration tests"
          else
            echo "FAIL: Darwin integration tests"
            FAILED=1
          fi
        ''
      else
        ''
          echo "SKIP: Darwin tests (not on Darwin)"
          SKIPPED_TESTS="$SKIPPED_TESTS darwin"
        ''
    }
    echo ""

    # ----------------------------------------
    # Builder Integration Tests (Darwin only)
    # ----------------------------------------
    echo "----------------------------------------"
    echo "Running: Builder Integration Tests"
    echo "----------------------------------------"
    ${
      if isDarwin then
        ''
          if ${builderIntegrationTests}/bin/test-builder; then
            echo "PASS: Builder integration tests"
          else
            echo "FAIL: Builder integration tests"
            FAILED=1
          fi
        ''
      else
        ''
          echo "SKIP: Builder tests (not on Darwin)"
          SKIPPED_TESTS="$SKIPPED_TESTS builder"
        ''
    }
    echo ""

    # ----------------------------------------
    # Summary
    # ----------------------------------------
    echo "========================================"
    if [ "$FAILED" -eq 0 ]; then
      if [ -n "$SKIPPED_TESTS" ]; then
        echo "ALL TESTS PASSED (skipped:$SKIPPED_TESTS)"
      else
        echo "ALL TESTS PASSED"
      fi
      exit 0
    else
      echo "SOME TESTS FAILED"
      exit 1
    fi
  '';

in
{
  # Checks for `nix flake check`
  inherit checks;

  # App for `nix run .#test`
  app = {
    meta.description = "Run all tests (some skip gracefully based on platform)";
    type = "app";
    program = "${testAll}/bin/test-all";
  };

  # Additional apps for selective testing
  apps = {
    # Fast lint-only tests (~5s)
    lint = {
      meta.description = "Run lint checks only (nixfmt, shellcheck, statix)";
      type = "app";
      program = "${testLint}/bin/test-lint";
    };

    # Ralph integration tests only (~20s)
    ralph = {
      meta.description = "Run ralph integration tests only";
      type = "app";
      program = "${testRalph}/bin/test-ralph";
    };
  };

  # Individual test sets (for debugging/selective running)
  inherit
    smokeTests
    darwinMountTests
    darwinNetworkTests
    darwinUidTests
    integrationTests
    ralphTests
    ralphTemplatesCheck
    shellTests
    tmuxMcpTests
    lintChecks
    readmeTest
    ;
}
