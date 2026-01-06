{ pkgs }:

let
  # Include Swift source for runtime compilation
  # We can't build the Swift CLI at nix build time because:
  # 1. The Containerization framework requires macOS 15
  # 2. Swift 6.0 is needed (nixpkgs has 5.10.1)
  # Instead, we build at runtime using the system Swift toolchain
  swiftSource = pkgs.runCommand "wrapix-runner-source" {} ''
    mkdir -p $out
    cp -r ${./swift}/* $out/
  '';

  # Build the kernel (stub on Darwin, real on Linux)
  kernel = import ./kernel.nix { inherit pkgs; };

  # Convert ~ paths to shell expressions
  expandPath = path:
    if builtins.substring 0 2 path == "~/"
    then ''$HOME/${builtins.substring 2 (builtins.stringLength path) path}''
    else path;

  # Convert destination ~ paths to container home
  expandDest = path:
    if builtins.substring 0 2 path == "~/"
    then ''/home/$USER/${builtins.substring 2 (builtins.stringLength path) path}''
    else path;

  # Generate mount args from profile
  mkMountArgs = profile:
    builtins.concatStringsSep " \\\n        " (
      map (m: ''--mount "${expandPath m.source}:${expandDest m.dest}"'') profile.mounts
    );

in {
  mkSandbox = { profile, profileImage, entrypoint, deployKey ? null }:
    pkgs.writeShellScriptBin "wrapix" ''
      set -euo pipefail

      echo "=================================================="
      echo "Wrapix Darwin support is not yet fully implemented"
      echo "=================================================="
      echo ""
      echo "The Darwin sandbox requires:"
      echo "  - macOS 15 (Sequoia) with Apple's Containerization framework"
      echo "  - Swift 6.0 (Xcode 16+)"
      echo "  - A pre-built Linux kernel for the VM"
      echo ""
      echo "Cross-compiling the container image from Darwin to Linux"
      echo "is currently not supported in nixpkgs due to toolchain issues."
      echo ""
      echo "For now, please use wrapix on a Linux system, or wait for"
      echo "improved Darwin support in a future release."
      echo ""
      echo "See: https://github.com/taheris/wrapix/issues"
      exit 1
    '';
}
