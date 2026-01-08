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
      profileImage,
      deployKey ? null,
      ...
    }:
    let
      deployKeyExpr = if deployKey != null then ''"${deployKey}"'' else ''$(basename "$PROJECT_DIR")'';
    in
    pkgs.writeShellScriptBin "wrapix" ''
      set -euo pipefail

      # XDG-compliant directories
      XDG_DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}"
      XDG_CACHE_HOME="''${XDG_CACHE_HOME:-$HOME/.cache}"
      WRAPIX_DATA="$XDG_DATA_HOME/wrapix"
      WRAPIX_CACHE="$XDG_CACHE_HOME/wrapix"
      RUNNER_BIN="$WRAPIX_DATA/bin/wrapix-runner"
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
        echo "wrapix-runner built successfully"
      fi

      # Check kernel
      KERNEL_PATH="${kernel}/vmlinux"
      if [ ! -f "$KERNEL_PATH" ]; then
        echo "Error: Linux kernel not found. Build on Linux or configure remote builder."
        exit 1
      fi

      # Build vminit image if needed (from Apple containerization repo)
      if ! "$WRAPIX_DATA/bin/cctl" images get vminit:latest >/dev/null 2>&1; then
        echo "Building vminit image from containerization repo..."
        CONTAINERIZATION_DIR="$WRAPIX_CACHE/containerization"

        if [ ! -d "$CONTAINERIZATION_DIR" ]; then
          git clone --depth 1 https://github.com/apple/containerization.git "$CONTAINERIZATION_DIR"
        fi

        cd "$CONTAINERIZATION_DIR"

        XCODE_SWIFT="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        XCODE_SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

        # Build cctl with Xcode (clean env to avoid Nix SDK conflicts)
        echo "Building cctl..."
        env -i HOME="$HOME" USER="$USER" TMPDIR="''${TMPDIR:-/tmp}" \
          PATH="/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Xcode.app/Contents/Developer/usr/bin" \
          DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
          SDKROOT="$XCODE_SDK" \
          "$XCODE_SWIFT" build -c release --product cctl

        mkdir -p bin
        cp "$(env -i PATH="/usr/bin:/bin" DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" "$XCODE_SWIFT" build -c release --show-bin-path)/cctl" bin/
        codesign --force --sign - --timestamp=none --entitlements=signing/vz.entitlements bin/cctl

        # Add swiftly to PATH (required for cross-compilation)
        export PATH="$HOME/.swiftly/bin:$PATH"

        # Install Swift cross-compilation SDK if needed (checks if SDK is already installed)
        if ! swift sdk list 2>/dev/null | grep -q "aarch64-swift-linux-musl"; then
          echo "Installing Swift cross-compilation toolchain (~2GB download)..."
          make cross-prep
        fi

        # Build vminitd with swiftly (for Linux cross-compilation)
        echo "Building vminitd..."
        make -C vminitd BUILD_CONFIGURATION=release

        # Create vminit image
        echo "Creating vminit image..."
        ./bin/cctl rootfs create \
          --vminitd vminitd/bin/vminitd \
          --vmexec vminitd/bin/vmexec \
          --label org.opencontainers.image.source=https://github.com/apple/containerization \
          --image vminit:latest \
          bin/init.rootfs.tar.gz

        # Copy cctl for future use
        mkdir -p "$WRAPIX_DATA/bin"
        cp bin/cctl "$WRAPIX_DATA/bin/"

        echo "vminit image built successfully"
        cd - > /dev/null
      fi

      # Load profile image if not already present
      PROFILE_IMAGE="wrapix-${profile.name}:latest"
      if ! "$WRAPIX_DATA/bin/cctl" images get "$PROFILE_IMAGE" >/dev/null 2>&1; then
        echo "Loading profile image..."
        "$WRAPIX_DATA/bin/cctl" images load < ${profileImage}
      fi

      # Build mount arguments
      MOUNT_ARGS="${mkMountArgs profile}"
      DEPLOY_KEY="$HOME/.ssh/deploy_keys/${deployKeyExpr}"
      [ -f "$DEPLOY_KEY" ] && MOUNT_ARGS="$MOUNT_ARGS --mount $DEPLOY_KEY:/home/$USER/.ssh/deploy_keys/${deployKeyExpr}"

      export WRAPIX_PROMPT='${systemPrompt}'

      exec "$RUNNER_BIN" "$PROJECT_DIR" \
        --image "''${WRAPIX_IMAGE:-$PROFILE_IMAGE}" \
        --kernel-path "$KERNEL_PATH" \
        $MOUNT_ARGS
    '';
}
