# Smoke tests - pure Nix tests that don't require Podman runtime
{
  pkgs,
  system,
}:

let
  inherit (pkgs) bash runCommandLocal;
  inherit (builtins) elem;

  isLinux = elem system [
    "x86_64-linux"
    "aarch64-linux"
  ];
  isDarwin = system == "aarch64-darwin";

  # Use Linux packages for image building (requires remote builder on Darwin)
  # Must apply same overlay as flake.nix to get pkgs.beads
  linuxPkgs =
    if isDarwin then
      import (pkgs.path) {
        system = "aarch64-linux";
        config.allowUnfree = true;
        overlays = pkgs.overlays;
      }
    else
      pkgs;

  profiles = import ../sandbox/profiles.nix { pkgs = linuxPkgs; };

  baseImage = import ../sandbox/image.nix {
    pkgs = linuxPkgs;
    profile = profiles.base;
    claudePackage = linuxPkgs.claude-code;
  };

  sandboxLib = import ../default.nix { inherit pkgs system; };
  wrapix = sandboxLib.mkSandbox { profile = sandboxLib.profiles.base; };

in
{
  # Verify OCI image builds and is a valid tar archive
  # On Darwin, this requires a Linux remote builder
  image-builds = runCommandLocal "smoke-image-builds" { } ''
    echo "Checking base image..."
    test -f ${baseImage}
    tar -tf ${baseImage} >/dev/null

    echo "Image built successfully"
    mkdir $out
  '';

  # Verify wrapix script has valid bash syntax
  script-syntax =
    runCommandLocal "smoke-script-syntax"
      {
        nativeBuildInputs = [ bash ];
      }
      ''
        echo "Checking bash syntax..."
        bash -n ${wrapix}/bin/wrapix

        echo "Script syntax validation passed"
        mkdir $out
      '';
}
