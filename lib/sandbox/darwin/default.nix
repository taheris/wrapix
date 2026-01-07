# Darwin sandbox using Apple Containerization framework (macOS 26+)
{ pkgs, linuxPkgs }:

let
  systemPrompt = builtins.readFile ../sandbox-prompt.txt;
  swiftSource = pkgs.runCommand "wrapix-runner-source" { } ''
    mkdir -p $out
    cp -r ${./swift}/* $out/
  '';
  # Build kernel using Linux packages (via remote builder on Darwin)
  kernel = import ./kernel.nix { pkgs = linuxPkgs; };

  expandPath =
    path:
    if builtins.substring 0 2 path == "~/" then
      ''$HOME/${builtins.substring 2 (builtins.stringLength path) path}''
    else
      path;

  expandDest =
    path:
    if builtins.substring 0 2 path == "~/" then
      ''/home/$USER/${builtins.substring 2 (builtins.stringLength path) path}''
    else
      path;

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
      deployKey ? null,
      ...
    }:
    let
      deployKeyExpr = if deployKey != null then ''"${deployKey}"'' else ''$(basename "$PROJECT_DIR")'';
    in
    pkgs.writeShellScriptBin "wrapix" ''
      set -euo pipefail

      WRAPIX_DIR="$HOME/.wrapix"
      RUNNER_BIN="$WRAPIX_DIR/bin/wrapix-runner"
      PROJECT_DIR="''${1:-$(pwd)}"

      # Check macOS version
      if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]; then
        echo "Error: macOS 26+ required (current: $(sw_vers -productVersion))"
        exit 1
      fi

      # Build wrapix-runner if needed
      if [ ! -x "$RUNNER_BIN" ]; then
        echo "Building wrapix-runner..."
        XCODE_SWIFT="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        XCODE_SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

        if [ ! -x "$XCODE_SWIFT" ] || [ ! -d "$XCODE_SDK" ]; then
          echo "Error: Xcode required (CLT has Swift PM bug on macOS 26)"
          echo "Install from App Store, then run: sudo xcode-select -s /Applications/Xcode.app"
          exit 1
        fi

        mkdir -p "$WRAPIX_DIR/build"
        rm -rf "$WRAPIX_DIR/build/wrapix-runner"
        cp -r "${swiftSource}" "$WRAPIX_DIR/build/wrapix-runner"
        chmod -R +w "$WRAPIX_DIR/build/wrapix-runner"
        cd "$WRAPIX_DIR/build/wrapix-runner"

        # Clean environment to avoid Nix SDK conflicts
        env -i HOME="$HOME" USER="$USER" TMPDIR="''${TMPDIR:-/tmp}" \
          PATH="/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Xcode.app/Contents/Developer/usr/bin" \
          DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
          SDKROOT="$XCODE_SDK" \
          "$XCODE_SWIFT" build -c release

        mkdir -p "$WRAPIX_DIR/bin"
        cp .build/release/wrapix-runner "$RUNNER_BIN"
        echo "wrapix-runner built successfully"
      fi

      # Check kernel
      KERNEL_PATH="${kernel}/vmlinux"
      if [ ! -f "$KERNEL_PATH" ]; then
        echo "Error: Linux kernel not found. Build on Linux or configure remote builder."
        exit 1
      fi

      # Build mount arguments
      MOUNT_ARGS="${mkMountArgs profile}"
      DEPLOY_KEY="$HOME/.ssh/deploy_keys/${deployKeyExpr}"
      [ -f "$DEPLOY_KEY" ] && MOUNT_ARGS="$MOUNT_ARGS --mount $DEPLOY_KEY:/home/$USER/.ssh/deploy_keys/${deployKeyExpr}"

      export WRAPIX_PROMPT='${systemPrompt}'

      exec "$RUNNER_BIN" "$PROJECT_DIR" \
        --image "''${WRAPIX_IMAGE:-docker.io/library/alpine:3.21}" \
        --kernel-path "$KERNEL_PATH" \
        $MOUNT_ARGS
    '';
}
