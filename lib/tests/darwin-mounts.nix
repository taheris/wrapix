# Darwin VM mount integration test
# Tests file and directory mounts work correctly in the VM
#
# This test will:
# - Run during `nix flake check` if container CLI is available
# - Skip gracefully if infrastructure is missing (with instructions)
#
# Prerequisites:
#   container system start    # Start container system first
{
  pkgs,
  system,
}:

let
  inherit (pkgs) runCommandLocal;

  isDarwin = system == "aarch64-darwin";

  # Use Linux packages for image building (requires remote builder on Darwin)
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

  # Test script that runs inside the container
  containerTestScript = ./darwin-mount-test.sh;

in
{
  # Integration test that runs a VM and tests mounts
  # Skips gracefully if infrastructure is not available
  darwin-mount-integration =
    runCommandLocal "test-darwin-mounts"
      {
        nativeBuildInputs = [ pkgs.skopeo ];
      }
      ''
        set -euo pipefail

        # Ensure we're on Darwin
        if [ "$(uname)" != "Darwin" ]; then
          echo "SKIP: Darwin-only test"
          mkdir -p $out
          exit 0
        fi

        # Check macOS version
        MACOS_VERSION=$(/usr/bin/sw_vers -productVersion | cut -d. -f1)
        if [ "$MACOS_VERSION" -lt 26 ]; then
          echo "SKIP: Requires macOS 26+ (current: $(/usr/bin/sw_vers -productVersion))"
          mkdir -p $out
          exit 0
        fi

        echo "=== Darwin Mount Integration Test ==="
        echo ""

        # Get the real console user
        REAL_USER=$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || echo "")
        if [ -z "$REAL_USER" ]; then
          echo "SKIP: Could not determine console user"
          mkdir -p $out
          exit 0
        fi

        REAL_HOME="/Users/$REAL_USER"

        # Check if container CLI is available
        if ! command -v container >/dev/null 2>&1; then
          echo "SKIP: container CLI not found"
          echo "Install with: nix profile install nixpkgs#container"
          mkdir -p $out
          exit 0
        fi

        # Check if container system is running
        if ! container system status >/dev/null 2>&1; then
          echo "SKIP: container system not running"
          echo "Start with: container system start"
          mkdir -p $out
          exit 0
        fi

        # Check if we can access the container storage
        CONTAINER_STORAGE="$REAL_HOME/Library/Application Support/com.apple.container"
        if [ ! -d "$CONTAINER_STORAGE" ] || [ ! -w "$CONTAINER_STORAGE" ]; then
          echo ""
          echo "SKIP: Cannot access container storage (running in nix build sandbox)"
          echo ""
          echo "To run this test manually:"
          echo "  nix run .#test-integration"
          mkdir -p $out
          exit 0
        fi

        # Set HOME so container uses the right storage directory
        export HOME="$REAL_HOME"

        # Load test image
        TEST_IMAGE="wrapix-mount-test:latest"
        echo "Loading test image..."
        container image delete "$TEST_IMAGE" 2>/dev/null || true
        OCI_TAR=$(mktemp)
        skopeo --insecure-policy copy "docker-archive:${profileImage}" "oci-archive:$OCI_TAR"
        LOAD_OUTPUT=$(container image load --input "$OCI_TAR" 2>&1)
        LOADED_REF=$(echo "$LOAD_OUTPUT" | grep -oE 'untagged@sha256:[a-f0-9]+' | head -1)
        if [ -n "$LOADED_REF" ]; then
          container image tag "$LOADED_REF" "$TEST_IMAGE"
        fi
        rm -f "$OCI_TAR"

        echo "Using image: $TEST_IMAGE"
        echo ""

        # Create temporary test directory
        TEST_DIR=$(mktemp -d)
        cleanup() { rm -rf "$TEST_DIR"; }
        trap cleanup EXIT

        echo "Test directory: $TEST_DIR"

        # Set up test workspace
        WORKSPACE="$TEST_DIR/workspace"
        mkdir -p "$WORKSPACE"
        echo "workspace-file-content" > "$WORKSPACE/workspace-test.txt"

        # Copy the container test script into workspace
        cp ${containerTestScript} "$WORKSPACE/mount-test.sh"
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
        DIR_MOUNTS="/mnt/wrapix/dir0:/home/$REAL_USER/.claude"
        FILE_MOUNTS="/mnt/wrapix/file0/claude.json:/home/$REAL_USER/.claude.json"

        echo ""
        echo "Test files created:"
        echo "  Workspace: $WORKSPACE/workspace-test.txt"
        echo "  Dir mount: $CLAUDE_DIR/ -> /mnt/wrapix/dir0 (staging)"
        echo "  File mount: $CLAUDE_JSON_DIR/claude.json -> /mnt/wrapix/file0 (staging)"
        echo ""

        echo "Running container with test mounts..."
        echo ""

        # Run the container with our test script
        set +e
        container run --rm \
          -w / \
          -v "$WORKSPACE:/workspace" \
          -v "$CLAUDE_DIR:/mnt/wrapix/dir0" \
          -v "$CLAUDE_JSON_DIR:/mnt/wrapix/file0" \
          -e HOST_USER=$REAL_USER \
          -e HOST_UID=$(id -u "$REAL_USER") \
          -e WRAPIX_PROMPT="test" \
          -e BD_NO_DB=1 \
          -e WRAPIX_DIR_MOUNTS="$DIR_MOUNTS" \
          -e WRAPIX_FILE_MOUNTS="$FILE_MOUNTS" \
          --network default \
          --entrypoint /bin/bash \
          "$TEST_IMAGE" /workspace/mount-test.sh
        EXIT_CODE=$?
        set -e

        echo ""
        echo "Container exit code: $EXIT_CODE"

        # Verify sync-back worked
        echo ""
        echo "Verifying sync-back..."
        if [ -f "$WORKSPACE/container-output.txt" ]; then
          CONTENT=$(cat "$WORKSPACE/container-output.txt")
          if [ "$CONTENT" = "container-wrote-this-content" ]; then
            echo "  PASS: Workspace sync-back worked"
          else
            echo "  FAIL: Sync-back content mismatch: $CONTENT"
            EXIT_CODE=1
          fi
        else
          echo "  FAIL: container-output.txt not synced back"
          ls -la "$WORKSPACE/"
          EXIT_CODE=1
        fi

        echo ""
        if [ "$EXIT_CODE" -eq 0 ]; then
          echo "=== MOUNT INTEGRATION TEST PASSED ==="
          mkdir -p $out
        else
          echo "=== MOUNT INTEGRATION TEST FAILED ==="
          exit 1
        fi
      '';
}
