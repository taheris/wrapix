{ pkgs }:

let
  # Build the Swift CLI
  swiftCli = pkgs.stdenv.mkDerivation {
    pname = "wrapix-runner";
    version = "0.1.0";

    src = ./swift;

    nativeBuildInputs = [ pkgs.swift pkgs.swiftpm ];

    buildPhase = ''
      swift build -c release
    '';

    installPhase = ''
      mkdir -p $out/bin
      cp .build/release/wrapix-runner $out/bin/
    '';
  };

  # Build the kernel
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
  mkSandbox = { profile, profileImage, entrypoint }:
    pkgs.writeShellScriptBin "wrapix" ''
      set -euo pipefail

      PROJECT_DIR="''${1:-$(pwd)}"

      # Export OCI image to tarball if needed
      IMAGE_TAR=$(mktemp -d)/image.tar
      ${pkgs.skopeo}/bin/skopeo copy docker-archive:${profileImage} oci-archive:$IMAGE_TAR

      exec ${swiftCli}/bin/wrapix-runner \
        "$PROJECT_DIR" \
        --image-path "$IMAGE_TAR" \
        --kernel-path ${kernel}/vmlinux \
        ${mkMountArgs profile}
    '';
}
