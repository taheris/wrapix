# Unified test runner - runs all tests with graceful skipping
# Use with: nix run .#test
{
  pkgs,
  system,
}:

let
  isDarwin = system == "aarch64-darwin";

  darwinTests = import ./darwin { inherit pkgs system; };

in
pkgs.writeShellScriptBin "test-all" ''
  set -euo pipefail

  FAILED=0
  DARWIN_SKIPPED=0

  echo "=== Wrapix Test Suite ==="
  echo ""

  # Run nix flake checks (smoke, ralph, lint, darwin logic tests)
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

  # Darwin integration tests (container runtime)
  echo "----------------------------------------"
  echo "Running: Darwin Integration Tests"
  echo "----------------------------------------"
  ${
    if isDarwin then
      ''
        if ${darwinTests}/bin/test-darwin; then
          echo "PASS: Darwin integration tests"
        else
          echo "FAIL: Darwin integration tests"
          FAILED=1
        fi
      ''
    else
      ''
        echo "SKIP: Darwin tests (not on Darwin)"
        DARWIN_SKIPPED=1
      ''
  }
  echo ""

  # Summary
  echo "========================================"
  if [ "$FAILED" -eq 0 ]; then
    if [ "$DARWIN_SKIPPED" -eq 1 ]; then
      echo "ALL TESTS PASSED (Darwin tests skipped)"
    else
      echo "ALL TESTS PASSED"
    fi
    exit 0
  else
    echo "SOME TESTS FAILED"
    exit 1
  fi
''
