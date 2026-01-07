# Darwin sandbox implementation using Apple Containerization framework
#
# This uses Apple's native Containerization framework (macOS 26+) to run
# a lightweight Linux VM with the Claude Code container.
#
# Requirements:
# - macOS 26+ (for Containerization framework)
# - Xcode 26+ (required for Containerization framework in SDK)
# - A Linux remote builder (to build the container image and kernel)

{ pkgs }:

let
  systemPrompt = builtins.readFile ../sandbox-prompt.txt;

  # Include Swift source for runtime compilation
  swiftSource = pkgs.runCommand "wrapix-runner-source" { } ''
    mkdir -p $out
    cp -r ${./swift}/* $out/
  '';

  # Linux kernel for the VM (built on Linux remote builder)
  kernel = import ./kernel.nix { inherit pkgs; };

  # Convert ~ paths to shell expressions
  expandPath =
    path:
    if builtins.substring 0 2 path == "~/" then
      ''$HOME/${builtins.substring 2 (builtins.stringLength path) path}''
    else
      path;

  # Convert destination ~ paths to container home
  expandDest =
    path:
    if builtins.substring 0 2 path == "~/" then
      ''/home/$USER/${builtins.substring 2 (builtins.stringLength path) path}''
    else
      path;

  # Generate mount args for wrapix-runner
  mkMountArgs =
    profile:
    builtins.concatStringsSep " " (
      map (m: ''--mount "${expandPath m.source}:${expandDest m.dest}"'') profile.mounts
    );

in
{
  mkSandbox =
    {
      profile,
      profileImage,
      entrypoint,
      deployKey ? null,
    }:
    let
      # If deployKey is null, default to basename of project dir at runtime
      deployKeyExpr = if deployKey != null then ''"${deployKey}"'' else ''$(basename "$PROJECT_DIR")'';
    in
    pkgs.writeShellScriptBin "wrapix" ''
      set -euo pipefail

      WRAPIX_DIR="$HOME/.wrapix"
      RUNNER_BIN="$WRAPIX_DIR/bin/wrapix-runner"
      SWIFT_SOURCE="${swiftSource}"
      PROJECT_DIR="''${1:-$(pwd)}"

      # Check macOS version (need 26+)
      MACOS_VERSION=$(sw_vers -productVersion | cut -d. -f1)
      if [ "$MACOS_VERSION" -lt 26 ]; then
        echo "Error: macOS 26 or later is required for Apple Containerization"
        echo "Current version: $(sw_vers -productVersion)"
        exit 1
      fi

      # Build wrapix-runner if not present or outdated
      build_runner() {
        echo "Building wrapix-runner..."
        mkdir -p "$WRAPIX_DIR/build"

        # Copy source to build directory (make writable for future updates)
        chmod -R +w "$WRAPIX_DIR/build/wrapix-runner" 2>/dev/null || true
        rm -rf "$WRAPIX_DIR/build/wrapix-runner"
        cp -r "$SWIFT_SOURCE" "$WRAPIX_DIR/build/wrapix-runner"
        chmod -R +w "$WRAPIX_DIR/build/wrapix-runner"
        cd "$WRAPIX_DIR/build/wrapix-runner"

        # Try Xcode first (use /usr/bin/xcrun to bypass Nix wrapper)
        # The Containerization framework requires Xcode 26+ SDK
        if /usr/bin/xcrun --find swift &>/dev/null; then
          echo "Using Xcode Swift..."
          /usr/bin/xcrun swift build -c release
        else
          echo "Error: Xcode 26+ is required to build wrapix-runner."
          echo "The Containerization framework is only available in the Xcode SDK."
          exit 1
        fi

        # Install the binary
        mkdir -p "$WRAPIX_DIR/bin"
        cp .build/release/wrapix-runner "$RUNNER_BIN"
        echo "wrapix-runner built successfully"
      }

      # Check if runner needs to be built
      if [ ! -x "$RUNNER_BIN" ]; then
        build_runner
      fi

      # Build mount arguments
      MOUNT_ARGS="${mkMountArgs profile}"

      # Add deploy key mount if present
      DEPLOY_KEY_NAME=${deployKeyExpr}
      DEPLOY_KEY="$HOME/.ssh/deploy_keys/$DEPLOY_KEY_NAME"
      if [ -f "$DEPLOY_KEY" ]; then
        MOUNT_ARGS="$MOUNT_ARGS --mount $DEPLOY_KEY:/home/$USER/.ssh/deploy_keys/$DEPLOY_KEY_NAME"
      fi

      # Export environment for the VM
      export WRAPIX_PROMPT='${systemPrompt}'

      # Check for required components
      KERNEL_PATH="${kernel}/vmlinux"
      IMAGE_PATH="${if profileImage != null then profileImage else ""}"

      if [ ! -f "$KERNEL_PATH" ]; then
        echo "Error: Linux kernel not found at $KERNEL_PATH"
        echo ""
        echo "The kernel must be built on Linux. Options:"
        echo "1. Configure a Linux remote builder: /etc/nix/machines"
        echo "2. Build on Linux and copy: nix build .#packages.aarch64-linux.kernel"
        echo "3. Use a Nix build service like nixbuild.net"
        exit 1
      fi

      if [ -z "$IMAGE_PATH" ] || [ ! -f "$IMAGE_PATH" ]; then
        echo "Error: Container image not found"
        echo ""
        echo "The container image requires a Linux remote builder."
        echo "Configure a builder in /etc/nix/machines or use nixbuild.net"
        exit 1
      fi

      # Run the sandbox
      exec "$RUNNER_BIN" "$PROJECT_DIR" \
        --image-path "$IMAGE_PATH" \
        --kernel-path "$KERNEL_PATH" \
        $MOUNT_ARGS
    '';
}
