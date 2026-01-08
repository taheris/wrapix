# Integration test runner - runs Darwin VM integration tests
# Use with: nix run .#test-integration
{
  pkgs,
  system,
}:

let
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

  # Swift source for runner (triggers rebuild when changed)
  swiftSource = pkgs.runCommand "wrapix-runner-source" { } ''
    mkdir -p $out
    cp -r ${../sandbox/darwin/swift}/* $out/
  '';

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

  # Check Xcode
  if [ ! -d "/Applications/Xcode.app" ]; then
    echo "ERROR: Requires Xcode"
    exit 1
  fi

  echo "=== Darwin Integration Tests ==="
  echo ""

  # XDG directories
  XDG_DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}"
  XDG_CACHE_HOME="''${XDG_CACHE_HOME:-$HOME/.cache}"
  WRAPIX_DATA="$XDG_DATA_HOME/wrapix"
  WRAPIX_CACHE="$XDG_CACHE_HOME/wrapix"
  RUNNER_BIN="$WRAPIX_DATA/bin/wrapix-runner"
  CCTL_BIN="$WRAPIX_DATA/bin/cctl"
  KERNEL_PATH="${kernel}/vmlinux"

  # Rebuild wrapix-runner if source changed
  RUNNER_VERSION_FILE="$WRAPIX_DATA/bin/wrapix-runner.version"
  CURRENT_SOURCE_HASH="${swiftSource}"
  if [ ! -x "$RUNNER_BIN" ] || [ ! -f "$RUNNER_VERSION_FILE" ] || [ "$(cat "$RUNNER_VERSION_FILE")" != "$CURRENT_SOURCE_HASH" ]; then
    echo "Building wrapix-runner..."
    XCODE_SWIFT="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
    XCODE_SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

    mkdir -p "$WRAPIX_CACHE"
    rm -rf "$WRAPIX_CACHE/wrapix-runner"
    cp -r "${swiftSource}" "$WRAPIX_CACHE/wrapix-runner"
    chmod -R +w "$WRAPIX_CACHE/wrapix-runner"
    cd "$WRAPIX_CACHE/wrapix-runner"

    # Clean environment to avoid Nix SDK conflicts
    env -i HOME="$HOME" USER="$USER" TMPDIR="''${TMPDIR:-/tmp}" \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Xcode.app/Contents/Developer/usr/bin" \
      DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
      SDKROOT="$XCODE_SDK" \
      "$XCODE_SWIFT" build -c release

    mkdir -p "$WRAPIX_DATA/bin"
    cp .build/release/wrapix-runner "$RUNNER_BIN"
    codesign --force --sign - --timestamp=none --entitlements=vz.entitlements "$RUNNER_BIN"
    echo "$CURRENT_SOURCE_HASH" > "$RUNNER_VERSION_FILE"
    echo "wrapix-runner built successfully"
    cd - > /dev/null
  fi

  if [ ! -x "$CCTL_BIN" ]; then
    echo "ERROR: cctl not found at $CCTL_BIN"
    echo "Run 'nix run . -- .' first to build it"
    exit 1
  fi

  if [ ! -f "$KERNEL_PATH" ]; then
    echo "ERROR: Linux kernel not found at $KERNEL_PATH"
    echo "Build with remote Linux builder first"
    exit 1
  fi

  echo "Using runner: $RUNNER_BIN"
  echo "Using kernel: $KERNEL_PATH"
  echo ""

  FAILED=0

  # ============================================
  # Network Integration Test
  # ============================================
  echo "----------------------------------------"
  echo "Running: Network Integration Test"
  echo "----------------------------------------"

  TEST_IMAGE="wrapix-integration-test:latest"

  # Always reload the image to pick up any changes
  echo "Loading test image..."
  "$CCTL_BIN" images delete "$TEST_IMAGE" 2>/dev/null || true
  OCI_TAR=$(mktemp)
  ${pkgs.skopeo}/bin/skopeo --insecure-policy copy "docker-archive:${profileImage}" "oci-archive:$OCI_TAR:$TEST_IMAGE"
  "$CCTL_BIN" images load --input "$OCI_TAR"
  rm -f "$OCI_TAR"

  TEST_DIR=$(mktemp -d)
  trap "rm -rf $TEST_DIR" EXIT

  WORKSPACE="$TEST_DIR/workspace"
  mkdir -p "$WORKSPACE"
  cp ${networkTestScript} "$WORKSPACE/network-test.sh"
  chmod +x "$WORKSPACE/network-test.sh"

  set +e
  "$RUNNER_BIN" "$WORKSPACE" \
    --image "$TEST_IMAGE" \
    --kernel-path "$KERNEL_PATH" \
    --command /bin/bash /workspace/network-test.sh
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

  # Reuse the same image from network test
  MOUNT_IMAGE="$TEST_IMAGE"

  rm -rf "$TEST_DIR"
  TEST_DIR=$(mktemp -d)
  WORKSPACE="$TEST_DIR/workspace"
  mkdir -p "$WORKSPACE"
  echo "workspace-file-content" > "$WORKSPACE/workspace-test.txt"
  cp ${mountTestScript} "$WORKSPACE/mount-test.sh"
  chmod +x "$WORKSPACE/mount-test.sh"

  CLAUDE_DIR="$TEST_DIR/claude-config"
  mkdir -p "$CLAUDE_DIR/mcp"
  echo '{"test": "settings-value"}' > "$CLAUDE_DIR/settings.json"
  echo '{"server": "mcp-config"}' > "$CLAUDE_DIR/mcp/config.json"

  CLAUDE_JSON="$TEST_DIR/claude.json"
  echo '{"apiKey": "test-api-key-12345"}' > "$CLAUDE_JSON"

  set +e
  "$RUNNER_BIN" "$WORKSPACE" \
    --image "$MOUNT_IMAGE" \
    --kernel-path "$KERNEL_PATH" \
    --dir-mount "$CLAUDE_DIR:/home/$USER/.claude" \
    --file-mount "$CLAUDE_JSON:/home/$USER/.claude.json" \
    --command /bin/bash /workspace/mount-test.sh
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
