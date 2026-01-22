#!/bin/bash
# Notification socket test - run inside container
#
# Tests notification socket mounting and accessibility
# Skips gracefully if daemon not running on host
set -euo pipefail

echo "=== Notification Socket Test ==="

# Test 1: Check if socket exists
echo ""
echo "Test 1: Socket existence"
if [ -S "/run/wrapix/notify.sock" ]; then
  echo "  PASS: Socket exists at /run/wrapix/notify.sock"
else
  echo "  SKIP: Socket not mounted (daemon may not be running on host)"
  exit 0
fi

# Test 2: Check socket permissions (Darwin-specific VirtioFS quirk)
echo ""
echo "Test 2: Socket permissions"
# Try Linux stat first, fall back to BSD stat
PERMS=$(stat -c '%a' "/run/wrapix/notify.sock" 2>/dev/null || stat -f '%Lp' "/run/wrapix/notify.sock" 2>/dev/null)
if [ "$PERMS" = "777" ] || [ "$PERMS" = "755" ] || [ "$PERMS" = "700" ] || [ "$PERMS" = "666" ]; then
  echo "  PASS: Socket has accessible permissions ($PERMS)"
else
  echo "  FAIL: Socket has inaccessible permissions ($PERMS)"
  echo "        VirtioFS may show 0000 perms - check WRAPIX_SOCK_MOUNTS includes socket"
  exit 1
fi

# Test 3: Write test (verifies daemon is listening)
echo ""
echo "Test 3: Socket writability"
if echo '{"title":"test","message":"test"}' | socat -u STDIN UNIX-CONNECT:/run/wrapix/notify.sock 2>/dev/null; then
  echo "  PASS: Successfully wrote to socket"
else
  echo "  FAIL: Could not write to socket"
  echo ""
  echo "  This usually means one of:"
  echo "    1. Stale socket mount - the daemon was restarted after the container started."
  echo "       Fix: Restart the container to pick up the new socket."
  echo "    2. Daemon not running - wrapix-notifyd is not running on the host."
  echo "       Fix: Run 'nix run .#wrapix-notifyd' on the host."
  exit 1
fi

echo ""
echo "=== ALL TESTS PASSED ==="
