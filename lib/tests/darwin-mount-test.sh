#!/bin/bash
# Container mount verification test script
# This runs INSIDE the container to verify mounts are working
set -e

echo "=== Container Mount Verification ==="
echo "Running as: $(id)"
echo "HOME: $HOME"
echo "PWD: $(pwd)"
echo ""

FAILED=0

# Test 1: Workspace mount
echo "Test 1: Workspace mount at /workspace"
if [ -f /workspace/workspace-test.txt ]; then
  CONTENT=$(cat /workspace/workspace-test.txt)
  if [ "$CONTENT" = "workspace-file-content" ]; then
    echo "  PASS: Content matches"
  else
    echo "  FAIL: Content mismatch: $CONTENT"
    FAILED=1
  fi
else
  echo "  FAIL: File not found"
  ls -la /workspace/ || true
  FAILED=1
fi

# Test 2: Directory mount environment variable
echo ""
echo "Test 2: WRAPIX_DIR_MOUNTS env var"
if [ -n "${WRAPIX_DIR_MOUNTS:-}" ]; then
  echo "  PASS: WRAPIX_DIR_MOUNTS=$WRAPIX_DIR_MOUNTS"
else
  echo "  FAIL: WRAPIX_DIR_MOUNTS not set"
  FAILED=1
fi

# Test 3: File mount environment variable
echo ""
echo "Test 3: WRAPIX_FILE_MOUNTS env var"
if [ -n "${WRAPIX_FILE_MOUNTS:-}" ]; then
  echo "  PASS: WRAPIX_FILE_MOUNTS=$WRAPIX_FILE_MOUNTS"
else
  echo "  FAIL: WRAPIX_FILE_MOUNTS not set"
  FAILED=1
fi

# Test 4: Directory mount staging location
echo ""
echo "Test 4: Directory mount staging"
if [ -d /mnt/wrapix/dir-mount/0 ]; then
  echo "  PASS: Staging directory exists"
  if [ -f /mnt/wrapix/dir-mount/0/settings.json ]; then
    if grep -q "settings-value" /mnt/wrapix/dir-mount/0/settings.json; then
      echo "  PASS: settings.json content correct"
    else
      echo "  FAIL: settings.json content wrong"
      cat /mnt/wrapix/dir-mount/0/settings.json
      FAILED=1
    fi
  else
    echo "  FAIL: settings.json not in staging"
    ls -la /mnt/wrapix/dir-mount/0/ || true
    FAILED=1
  fi
  if [ -f /mnt/wrapix/dir-mount/0/mcp/config.json ]; then
    echo "  PASS: Nested mcp/config.json exists"
  else
    echo "  FAIL: mcp/config.json not in staging"
    ls -laR /mnt/wrapix/dir-mount/0/ || true
    FAILED=1
  fi
else
  echo "  FAIL: Staging directory /mnt/wrapix/dir-mount/0 not found"
  ls -la /mnt/wrapix/ 2>/dev/null || echo "  /mnt/wrapix does not exist"
  FAILED=1
fi

# Test 5: File mount staging location
echo ""
echo "Test 5: File mount staging"
# File mounts go through parent directory
if ls /mnt/wrapix/file-mount/*/claude.json 2>/dev/null; then
  FILE_PATH=$(ls /mnt/wrapix/file-mount/*/claude.json 2>/dev/null | head -1)
  if grep -q "test-api-key-12345" "$FILE_PATH"; then
    echo "  PASS: claude.json content correct at $FILE_PATH"
  else
    echo "  FAIL: claude.json content wrong"
    cat "$FILE_PATH"
    FAILED=1
  fi
else
  echo "  FAIL: claude.json not found in file mount staging"
  ls -laR /mnt/wrapix/file-mount/ 2>/dev/null || echo "  /mnt/wrapix/file-mount does not exist"
  FAILED=1
fi

# Test 6: Write to workspace (sync-back test)
echo ""
echo "Test 6: Write to workspace"
echo "container-wrote-this-content" > /workspace/container-output.txt
if [ -f /workspace/container-output.txt ]; then
  echo "  PASS: Wrote to workspace"
else
  echo "  FAIL: Could not write to workspace"
  FAILED=1
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "=== ALL TESTS PASSED ==="
  exit 0
else
  echo "=== SOME TESTS FAILED ==="
  exit 1
fi
