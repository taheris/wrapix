# Darwin VM network integration test
# Runs actual VM to verify networking works
#
# This test will:
# - Run during `nix flake check` if wrapix infrastructure is set up
# - Skip gracefully if infrastructure is missing (with instructions)
#
# Prerequisites:
#   nix run . -- .    # Build and setup wrapix infrastructure first
{
  pkgs,
  system,
}:

let
  inherit (pkgs) runCommandLocal;

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
  containerTestScript = ./darwin-network-test.sh;

in
{
  # Integration test that runs a VM and tests networking
  # Skips gracefully if infrastructure is not available
  darwin-network-integration =
    runCommandLocal "test-darwin-network"
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

        # Check Xcode
        if [ ! -d "/Applications/Xcode.app" ]; then
          echo "SKIP: Requires Xcode"
          mkdir -p $out
          exit 0
        fi

        echo "=== Darwin Network Integration Test ==="
        echo ""

        # Get the real console user
        REAL_USER=$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || echo "")
        if [ -z "$REAL_USER" ]; then
          echo "SKIP: Could not determine console user"
          mkdir -p $out
          exit 0
        fi

        REAL_HOME="/Users/$REAL_USER"
        XDG_DATA_HOME="$REAL_HOME/.local/share"
        RUNNER_BIN="$XDG_DATA_HOME/wrapix/bin/wrapix-runner"
        CCTL_BIN="$XDG_DATA_HOME/wrapix/bin/cctl"
        KERNEL_PATH="${kernel}/vmlinux"

        # Check prerequisites
        if [ ! -x "$RUNNER_BIN" ]; then
          echo "SKIP: wrapix-runner not found at $RUNNER_BIN"
          echo "Run 'nix run . -- .' first to build it"
          mkdir -p $out
          exit 0
        fi

        if [ ! -x "$CCTL_BIN" ]; then
          echo "SKIP: cctl not found at $CCTL_BIN"
          echo "Run 'nix run . -- .' first to build it"
          mkdir -p $out
          exit 0
        fi

        if [ ! -f "$KERNEL_PATH" ]; then
          echo "SKIP: Linux kernel not found at $KERNEL_PATH"
          echo "Build with remote Linux builder first"
          mkdir -p $out
          exit 0
        fi

        # Check if we can access the containerization storage
        # This fails in nix build because we run as nixbld user
        CONTAINER_STORAGE="$REAL_HOME/Library/Application Support/com.apple.containerization"
        if [ ! -d "$CONTAINER_STORAGE" ] || [ ! -w "$CONTAINER_STORAGE" ]; then
          echo ""
          echo "SKIP: Cannot access containerization storage (running in nix build sandbox)"
          echo ""
          echo "To run this test manually:"
          echo "  nix build .#checks.aarch64-darwin.darwin-network-integration"
          echo "  # Then run outside of nix:"
          echo "  TEST_IMAGE=wrapix-network-test:latest"
          echo "  WORKSPACE=\$(mktemp -d)/workspace && mkdir -p \$WORKSPACE"
          echo "  cp ${containerTestScript} \$WORKSPACE/network-test.sh"
          echo "  $RUNNER_BIN \$WORKSPACE --image \$TEST_IMAGE --kernel-path $KERNEL_PATH --command /bin/bash /workspace/network-test.sh"
          mkdir -p $out
          exit 0
        fi

        # Set HOME so cctl uses the right Application Support directory
        export HOME="$REAL_HOME"

        # Check if test image exists or load it
        TEST_IMAGE="wrapix-network-test:latest"
        if ! "$CCTL_BIN" images get "$TEST_IMAGE" >/dev/null 2>&1; then
          echo "Loading test image..."
          OCI_TAR=$(mktemp)
          skopeo --insecure-policy copy "docker-archive:${profileImage}" "oci-archive:$OCI_TAR:$TEST_IMAGE"
          "$CCTL_BIN" images load --input "$OCI_TAR"
          rm -f "$OCI_TAR"
        fi

        echo "Found wrapix-runner: $RUNNER_BIN"
        echo "Found kernel: $KERNEL_PATH"
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

        # Copy the container test script into workspace
        cp ${containerTestScript} "$WORKSPACE/network-test.sh"
        chmod +x "$WORKSPACE/network-test.sh"

        echo ""
        echo "Running container with network test..."
        echo ""

        # Run the container with our test script
        set +e
        "$RUNNER_BIN" "$WORKSPACE" \
          --image "$TEST_IMAGE" \
          --kernel-path "$KERNEL_PATH" \
          --command /bin/bash /workspace/network-test.sh
        EXIT_CODE=$?
        set -e

        echo ""
        echo "Container exit code: $EXIT_CODE"

        echo ""
        if [ "$EXIT_CODE" -eq 0 ]; then
          echo "=== NETWORK INTEGRATION TEST PASSED ==="
          mkdir -p $out
        else
          echo "=== NETWORK INTEGRATION TEST FAILED ==="
          exit 1
        fi
      '';
}
