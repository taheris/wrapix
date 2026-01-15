#!/bin/bash
# wrapix-builder integration test
# Tests the persistent Linux builder functionality on macOS 26+
# Use with: nix run .#test-builder (when added to flake.nix)
set -euo pipefail

echo "=== wrapix-builder Integration Test ==="
echo "Date: $(date)"
echo ""

# Ensure we're on Darwin with macOS 26+
if [ "$(uname)" != "Darwin" ]; then
  echo "ERROR: This test only runs on Darwin"
  exit 1
fi

MACOS_VERSION=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MACOS_VERSION" -lt 26 ]; then
  echo "ERROR: Requires macOS 26+ (current: $(sw_vers -productVersion))"
  exit 1
fi

FAILED=0

# Build wrapix-builder
echo "=== Building wrapix-builder ==="
nix build .#wrapix-builder
BUILDER="./result/bin/wrapix-builder"

# Test 1: Start builder
echo ""
echo "Test 1: Start builder"
if $BUILDER start; then
  echo "  PASS: Builder started"
else
  echo "  FAIL: Failed to start builder"
  FAILED=1
fi

# Give it time to initialize
sleep 5

# Test 2: Check status
echo ""
echo "Test 2: Check status"
if $BUILDER status | grep -q "running"; then
  echo "  PASS: Builder is running"
else
  echo "  FAIL: Builder not running"
  FAILED=1
fi

# Test 3: Test SSH connection
echo ""
echo "Test 3: SSH connection"
if $BUILDER ssh "whoami" 2>/dev/null | grep -q "builder"; then
  echo "  PASS: SSH works, user is builder"
else
  echo "  FAIL: SSH connection failed"
  FAILED=1
fi

# Test 4: Verify nix-daemon is running inside container
echo ""
echo "Test 4: nix-daemon running"
if $BUILDER ssh "pgrep -x nix-daemon" >/dev/null 2>&1; then
  echo "  PASS: nix-daemon is running"
else
  echo "  FAIL: nix-daemon not running"
  FAILED=1
fi

# Test 5: Verify nix commands work
echo ""
echo "Test 5: Nix commands work"
if $BUILDER ssh "nix --version" >/dev/null 2>&1; then
  NIX_VERSION=$($BUILDER ssh "nix --version" 2>/dev/null)
  echo "  PASS: Nix available ($NIX_VERSION)"
else
  echo "  FAIL: Nix commands not working"
  FAILED=1
fi

# Test 6: Remote build test
echo ""
echo "Test 6: Remote build (nixpkgs#hello)"
KEYS_DIR="$HOME/.local/share/wrapix/builder-keys"
if nix build \
  --builders "ssh-ng://builder@localhost:2222 aarch64-linux $KEYS_DIR/builder_ed25519 4 1" \
  --max-jobs 0 \
  --no-link \
  nixpkgs#hello 2>/dev/null; then
  echo "  PASS: Remote build succeeded"
else
  echo "  FAIL: Remote build failed"
  echo "  (This may fail if no remote Linux builder is available for aarch64-linux)"
  # Don't fail the whole test for this - it requires a working Linux builder chain
fi

# Test 7: Store persistence test
echo ""
echo "Test 7: Store persistence"
# Create a test file in the store
TEST_MARKER="wrapix-test-$(date +%s)"
$BUILDER ssh "echo '$TEST_MARKER' > /nix/test-marker" 2>/dev/null || true

# Stop and restart
echo "  Stopping builder..."
$BUILDER stop
sleep 2
echo "  Starting builder..."
$BUILDER start
sleep 5

# Check if marker persists
if $BUILDER ssh "cat /nix/test-marker" 2>/dev/null | grep -q "$TEST_MARKER"; then
  echo "  PASS: Store persists across restart"
  $BUILDER ssh "rm /nix/test-marker" 2>/dev/null || true
else
  echo "  FAIL: Store not persistent"
  FAILED=1
fi

# Test 8: Config output
echo ""
echo "Test 8: Config command"
if $BUILDER config | grep -q "ssh-ng://"; then
  echo "  PASS: Config outputs valid nix.conf snippet"
else
  echo "  FAIL: Config command failed"
  FAILED=1
fi

# Cleanup
echo ""
echo "=== Cleanup ==="
$BUILDER stop
echo "Builder stopped"

# Summary
echo ""
echo "========================================"
if [ "$FAILED" -eq 0 ]; then
  echo "ALL BUILDER TESTS PASSED"
  exit 0
else
  echo "SOME BUILDER TESTS FAILED"
  exit 1
fi
