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

  # Integration tests require NixOS VM (Linux with KVM only)
  # Skip when KVM unavailable (e.g., inside containers)
  integrationTests =
    if isLinux && hasKvm then import ./integration.nix { inherit pkgs system; } else { };

  # Ralph utility function tests run on all platforms
  ralphTests = import ./ralph { inherit pkgs system; };

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
    // integrationTests
    // ralphTests
    // lintChecks
    // readmeTest;

  # ============================================================================
  # Integration Test Runners (require runtime environment)
  # ============================================================================

  # Darwin container integration tests
  darwinIntegrationTests = import ./darwin { inherit pkgs system; };

  # Ralph workflow integration tests (with mock-claude)
  ralphIntegrationTests = writeShellScriptBin "test-ralph-integration" ''
    set -euo pipefail
    exec ${./ralph/run-tests.sh}
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
    # Nix Flake Checks
    # ----------------------------------------
    echo "----------------------------------------"
    echo "Running: Nix Flake Checks"
    echo "----------------------------------------"
    if ${pkgs.nix}/bin/nix flake check --impure 2>&1; then
      echo "PASS: Nix flake checks"
    else
      echo "FAIL: Nix flake checks"
      FAILED=1
    fi
    echo ""

    # ----------------------------------------
    # Ralph Integration Tests
    # ----------------------------------------
    echo "----------------------------------------"
    echo "Running: Ralph Integration Tests"
    echo "----------------------------------------"
    if command -v bd &>/dev/null && command -v ralph-step &>/dev/null; then
      if ${ralphIntegrationTests}/bin/test-ralph-integration; then
        echo "PASS: Ralph integration tests"
      else
        echo "FAIL: Ralph integration tests"
        FAILED=1
      fi
    else
      echo "SKIP: Ralph integration tests (bd or ralph-step not in PATH)"
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

  # Individual test sets (for debugging/selective running)
  inherit
    smokeTests
    darwinMountTests
    darwinNetworkTests
    integrationTests
    ralphTests
    lintChecks
    readmeTest
    ;
}
