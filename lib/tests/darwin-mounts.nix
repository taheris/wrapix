# Darwin VM mount integration test
# Requires: macOS 26+, Xcode, wrapix-runner built
#
# Run with:
#   nix build .#checks.aarch64-darwin.darwin-mount-integration
#   ./result/bin/test-darwin-mounts
{
  pkgs,
  system,
}:

let
  inherit (pkgs) writeShellScriptBin;
  inherit (builtins) elem;

  isDarwin = system == "aarch64-darwin";

  # Use Linux packages for kernel (requires remote builder on Darwin)
  linuxPkgs =
    if isDarwin then
      import (pkgs.path) {
        system = "aarch64-linux";
        config.allowUnfree = true;
        overlays = pkgs.overlays;
      }
    else
      pkgs;

  # Import kernel from the sandbox module
  kernel = import ../sandbox/darwin/kernel.nix { pkgs = linuxPkgs; };

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

  # Integration test script that sets up and runs the VM
  integrationTest = writeShellScriptBin "test-darwin-mounts" ''
    set -euo pipefail

    # Ensure we're on Darwin
    if [ "$(uname)" != "Darwin" ]; then
      echo "SKIP: Darwin-only test"
      exit 0
    fi

    # Check macOS version
    MACOS_VERSION=$(sw_vers -productVersion | cut -d. -f1)
    if [ "$MACOS_VERSION" -lt 26 ]; then
      echo "SKIP: Requires macOS 26+ (current: $(sw_vers -productVersion))"
      exit 0
    fi

    # Check Xcode
    if [ ! -d "/Applications/Xcode.app" ]; then
      echo "SKIP: Requires Xcode"
      exit 0
    fi

    echo "=== Darwin Mount Integration Test ==="
    echo ""

    # Find wrapix-runner and cctl
    XDG_DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}"
    RUNNER_BIN="$XDG_DATA_HOME/wrapix/bin/wrapix-runner"
    CCTL_BIN="$XDG_DATA_HOME/wrapix/bin/cctl"

    if [ ! -x "$RUNNER_BIN" ]; then
      echo "ERROR: wrapix-runner not found at $RUNNER_BIN"
      echo "Run 'nix run .#wrapix-darwin -- .' first to build it"
      exit 1
    fi

    if [ ! -x "$CCTL_BIN" ]; then
      echo "ERROR: cctl not found at $CCTL_BIN"
      echo "Run 'nix run .#wrapix-darwin -- .' first to build it"
      exit 1
    fi

    # Kernel path is baked in from Nix
    KERNEL_PATH="${kernel}/vmlinux"

    if [ ! -f "$KERNEL_PATH" ]; then
      echo "ERROR: Linux kernel not found at $KERNEL_PATH"
      echo "Build with remote Linux builder first"
      exit 1
    fi

    # Load test image if needed
    TEST_IMAGE="wrapix-mount-test:latest"
    if ! "$CCTL_BIN" images get "$TEST_IMAGE" >/dev/null 2>&1; then
      echo "Loading test image..."
      OCI_TAR=$(mktemp)
      ${pkgs.skopeo}/bin/skopeo --insecure-policy copy "docker-archive:${profileImage}" "oci-archive:$OCI_TAR:$TEST_IMAGE"
      "$CCTL_BIN" images load --input "$OCI_TAR"
      rm -f "$OCI_TAR"
    fi

    echo "Found wrapix-runner: $RUNNER_BIN"
    echo "Found kernel: $KERNEL_PATH"
    echo "Using image: $TEST_IMAGE"
    echo ""

    # Create temporary test directory
    TEST_DIR=$(mktemp -d)
    trap "rm -rf $TEST_DIR" EXIT

    echo "Test directory: $TEST_DIR"

    # Set up test workspace
    WORKSPACE="$TEST_DIR/workspace"
    mkdir -p "$WORKSPACE"
    echo "workspace-file-content" > "$WORKSPACE/workspace-test.txt"

    # Copy the container test script into workspace
    cp ${containerTestScript} "$WORKSPACE/mount-test.sh"
    chmod +x "$WORKSPACE/mount-test.sh"

    # Set up test directory mount (simulating ~/.claude)
    CLAUDE_DIR="$TEST_DIR/claude-config"
    mkdir -p "$CLAUDE_DIR/mcp"
    echo '{"test": "settings-value"}' > "$CLAUDE_DIR/settings.json"
    echo '{"server": "mcp-config"}' > "$CLAUDE_DIR/mcp/config.json"

    # Set up test file mount (simulating ~/.claude.json)
    CLAUDE_JSON="$TEST_DIR/claude.json"
    echo '{"apiKey": "test-api-key-12345"}' > "$CLAUDE_JSON"

    echo ""
    echo "Test files created:"
    echo "  Workspace: $WORKSPACE/workspace-test.txt"
    echo "  Dir mount: $CLAUDE_DIR/ (with settings.json, mcp/config.json)"
    echo "  File mount: $CLAUDE_JSON"
    echo ""

    echo "Running container with test mounts..."
    echo "Command: $RUNNER_BIN $WORKSPACE --image $TEST_IMAGE --kernel-path $KERNEL_PATH \\"
    echo "         --dir-mount $CLAUDE_DIR:/home/$USER/.claude \\"
    echo "         --file-mount $CLAUDE_JSON:/home/$USER/.claude.json \\"
    echo "         --command /bin/bash /workspace/mount-test.sh"
    echo ""

    # Run the container with our test script
    set +e
    "$RUNNER_BIN" "$WORKSPACE" \
      --image "$TEST_IMAGE" \
      --kernel-path "$KERNEL_PATH" \
      --dir-mount "$CLAUDE_DIR:/home/$USER/.claude" \
      --file-mount "$CLAUDE_JSON:/home/$USER/.claude.json" \
      --command /bin/bash /workspace/mount-test.sh
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
      echo "=== INTEGRATION TEST PASSED ==="
    else
      echo "=== INTEGRATION TEST FAILED ==="
    fi

    exit $EXIT_CODE
  '';

in
{
  # Export the integration test script
  # Run with: nix build .#checks.aarch64-darwin.darwin-mount-integration && ./result/bin/test-darwin-mounts
  darwin-mount-integration = integrationTest;
}
