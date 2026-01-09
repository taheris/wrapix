# Integration test runner - runs Darwin VM integration tests
# Use with: nix run .#test-integration
{
  pkgs,
  system,
}:

let
  isDarwin = system == "aarch64-darwin";

  # Use Linux packages for building the container image (requires remote builder on Darwin)
  linuxPkgs =
    if isDarwin then
      import (pkgs.path) {
        system = "aarch64-linux";
        config.allowUnfree = true;
        overlays = pkgs.overlays;
      }
    else
      pkgs;

  # Build profile image for testing
  profiles = import ../sandbox/profiles.nix { pkgs = linuxPkgs; };
  profileImage = import ../sandbox/image.nix {
    pkgs = linuxPkgs;
    profile = profiles.base;
    claudePackage = linuxPkgs.claude-code;
    entrypointScript = ../sandbox/darwin/entrypoint.sh;
  };

  # Test scripts that run inside the container
  networkTestScript = ./darwin-network-test.sh;
  mountTestScript = ./darwin-mount-test.sh;

in
pkgs.writeShellScriptBin "test-integration" ''
  set -euo pipefail

  # Ensure we're on Darwin
  if [ "$(uname)" != "Darwin" ]; then
    echo "ERROR: Integration tests only run on Darwin"
    exit 1
  fi

  # Check macOS version
  MACOS_VERSION=$(sw_vers -productVersion | cut -d. -f1)
  if [ "$MACOS_VERSION" -lt 26 ]; then
    echo "ERROR: Requires macOS 26+ (current: $(sw_vers -productVersion))"
    exit 1
  fi

  echo "=== Darwin Integration Tests ==="
  echo ""

  # Ensure container system is running
  if ! container system status >/dev/null 2>&1; then
    echo "Starting container system..."
    container system start
    sleep 2
  fi

  TEST_IMAGE="wrapix-integration-test:latest"
  XDG_CACHE_HOME="''${XDG_CACHE_HOME:-$HOME/.cache}"
  WRAPIX_CACHE="$XDG_CACHE_HOME/wrapix"
  mkdir -p "$WRAPIX_CACHE"

  # Load test image
  echo "Loading test image..."
  container image delete "$TEST_IMAGE" 2>/dev/null || true
  OCI_TAR="$WRAPIX_CACHE/integration-test-image.tar"
  ${pkgs.skopeo}/bin/skopeo --insecure-policy copy "docker-archive:${profileImage}" "oci-archive:$OCI_TAR"
  LOAD_OUTPUT=$(container image load --input "$OCI_TAR" 2>&1)
  LOADED_REF=$(echo "$LOAD_OUTPUT" | grep -oE 'untagged@sha256:[a-f0-9]+' | head -1)
  if [ -n "$LOADED_REF" ]; then
    container image tag "$LOADED_REF" "$TEST_IMAGE"
  fi
  rm -f "$OCI_TAR"

  echo "Using container CLI for tests"
  echo ""

  FAILED=0

  # ============================================
  # Network Integration Test
  # ============================================
  echo "----------------------------------------"
  echo "Running: Network Integration Test"
  echo "----------------------------------------"

  TEST_DIR=$(mktemp -d)
  trap "rm -rf $TEST_DIR" EXIT

  WORKSPACE="$TEST_DIR/workspace"
  mkdir -p "$WORKSPACE"
  cp ${networkTestScript} "$WORKSPACE/network-test.sh"
  chmod +x "$WORKSPACE/network-test.sh"

  set +e
  container run --rm \
    -w / \
    -v "$WORKSPACE:/workspace" \
    -e HOST_USER=$USER \
    -e HOST_UID=$(id -u) \
    -e WRAPIX_PROMPT="test" \
    -e BD_NO_DB=1 \
    --network default \
    --entrypoint /bin/bash \
    "$TEST_IMAGE" /workspace/network-test.sh
  NETWORK_EXIT=$?
  set -e

  if [ "$NETWORK_EXIT" -eq 0 ]; then
    echo "PASS: Network test"
  else
    echo "FAIL: Network test (exit code: $NETWORK_EXIT)"
    FAILED=1
  fi
  echo ""

  # ============================================
  # Mount Integration Test
  # ============================================
  echo "----------------------------------------"
  echo "Running: Mount Integration Test"
  echo "----------------------------------------"

  rm -rf "$TEST_DIR"
  TEST_DIR=$(mktemp -d)
  WORKSPACE="$TEST_DIR/workspace"
  mkdir -p "$WORKSPACE"
  echo "workspace-file-content" > "$WORKSPACE/workspace-test.txt"
  cp ${mountTestScript} "$WORKSPACE/mount-test.sh"
  chmod +x "$WORKSPACE/mount-test.sh"

  # Set up directory mount (simulating ~/.claude)
  # VirtioFS maps files as root, so we use staging + WRAPIX_DIR_MOUNTS
  CLAUDE_DIR="$TEST_DIR/claude-config"
  mkdir -p "$CLAUDE_DIR/mcp"
  echo '{"test": "settings-value"}' > "$CLAUDE_DIR/settings.json"
  echo '{"server": "mcp-config"}' > "$CLAUDE_DIR/mcp/config.json"

  # Set up file mount (simulating ~/.claude.json)
  # VirtioFS only supports directory mounts, so we mount parent dir to staging
  CLAUDE_JSON_DIR="$TEST_DIR/claude-json"
  mkdir -p "$CLAUDE_JSON_DIR"
  echo '{"apiKey": "test-api-key-12345"}' > "$CLAUDE_JSON_DIR/claude.json"

  # Build mount environment variables in same format as production:
  # DIR_MOUNTS:  /staging/path:/destination/path
  # FILE_MOUNTS: /staging/path/filename:/destination/path
  DIR_MOUNTS="/mnt/wrapix/dir0:/home/$USER/.claude"
  FILE_MOUNTS="/mnt/wrapix/file0/claude.json:/home/$USER/.claude.json"

  set +e
  container run --rm \
    -w / \
    -v "$WORKSPACE:/workspace" \
    -v "$CLAUDE_DIR:/mnt/wrapix/dir0" \
    -v "$CLAUDE_JSON_DIR:/mnt/wrapix/file0" \
    -e HOST_USER=$USER \
    -e HOST_UID=$(id -u) \
    -e WRAPIX_PROMPT="test" \
    -e BD_NO_DB=1 \
    -e WRAPIX_DIR_MOUNTS="$DIR_MOUNTS" \
    -e WRAPIX_FILE_MOUNTS="$FILE_MOUNTS" \
    --network default \
    --entrypoint /bin/bash \
    "$TEST_IMAGE" /workspace/mount-test.sh
  MOUNT_EXIT=$?
  set -e

  # Verify sync-back
  if [ -f "$WORKSPACE/container-output.txt" ]; then
    CONTENT=$(cat "$WORKSPACE/container-output.txt")
    if [ "$CONTENT" != "container-wrote-this-content" ]; then
      echo "FAIL: Sync-back content mismatch"
      MOUNT_EXIT=1
    fi
  else
    echo "FAIL: container-output.txt not synced back"
    MOUNT_EXIT=1
  fi

  if [ "$MOUNT_EXIT" -eq 0 ]; then
    echo "PASS: Mount test"
  else
    echo "FAIL: Mount test (exit code: $MOUNT_EXIT)"
    FAILED=1
  fi
  echo ""

  # ============================================
  # Summary
  # ============================================
  echo "========================================"
  if [ "$FAILED" -eq 0 ]; then
    echo "ALL INTEGRATION TESTS PASSED"
    exit 0
  else
    echo "SOME INTEGRATION TESTS FAILED"
    exit 1
  fi
''
