# Smoke tests - pure Nix tests that don't require Podman runtime
{ pkgs, system }:

let
  inherit (pkgs) bash claude-code runCommandLocal;

  profiles = import ../sandbox/profiles.nix { inherit pkgs; };

  baseImage = import ../sandbox/image.nix {
    inherit pkgs;
    profile = profiles.base;
    claudePackage = claude-code;
  };

  sandboxLib = import ../default.nix { inherit pkgs system; };
  wrapix = sandboxLib.mkSandbox sandboxLib.profiles.base;

in {
  # Verify OCI image builds and is a valid tar archive
  image-builds = runCommandLocal "smoke-image-builds" {} ''
    echo "Checking base image..."
    test -f ${baseImage}
    tar -tf ${baseImage} >/dev/null

    echo "Image built successfully"
    mkdir $out
  '';

  # Verify wrapix script has valid bash syntax
  script-syntax = runCommandLocal "smoke-script-syntax" {
    nativeBuildInputs = [ bash ];
  } ''
    echo "Checking bash syntax..."
    bash -n ${wrapix}/bin/wrapix

    echo "Script syntax validation passed"
    mkdir $out
  '';
}
