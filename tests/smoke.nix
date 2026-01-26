# Smoke tests - pure Nix tests that don't require Podman runtime
{
  pkgs,
  system,
}:

let
  inherit (pkgs) bash runCommandLocal;
  inherit (builtins) elem getEnv;

  isLinux = elem system [
    "x86_64-linux"
    "aarch64-linux"
  ];
  isDarwin = system == "aarch64-darwin";

  # Skip heavy image tests when SKIP_IMAGE_TEST=1 (saves ~20s)
  skipImageTest = getEnv "SKIP_IMAGE_TEST" != "";

  # Use Linux packages for image building (requires remote builder on Darwin)
  # Must apply same overlay as flake.nix to get pkgs.beads
  linuxPkgs =
    if isDarwin then
      import pkgs.path {
        system = "aarch64-linux";
        config.allowUnfree = true;
        inherit (pkgs) overlays;
      }
    else
      pkgs;

  profiles = import ../lib/sandbox/profiles.nix { pkgs = linuxPkgs; };

  baseImage = import ../lib/sandbox/image.nix {
    pkgs = linuxPkgs;
    profile = profiles.base;
    entrypointPkg = linuxPkgs.claude-code;
    entrypointSh =
      if isDarwin then ../lib/sandbox/darwin/entrypoint.sh else ../lib/sandbox/linux/entrypoint.sh;
    claudeConfig = { };
    claudeSettings = { };
  };

  sandboxLib = import ../lib { inherit pkgs system linuxPkgs; };
  wrapix = sandboxLib.mkSandbox { profile = sandboxLib.profiles.base; };

in
{
  # Verify OCI image builds and is a valid tar archive
  # On Darwin, this requires a Linux remote builder
  # Skip with SKIP_IMAGE_TEST=1 for faster iteration (saves ~20s)
  image-builds =
    if skipImageTest then
      runCommandLocal "smoke-image-builds-skipped" { } ''
        echo "SKIP: Image build test (SKIP_IMAGE_TEST=1)"
        mkdir $out
      ''
    else
      runCommandLocal "smoke-image-builds" { } ''
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

  # Verify Darwin entrypoint script syntax and mount handling logic
  darwin-entrypoint-syntax =
    runCommandLocal "smoke-darwin-entrypoint"
      {
        nativeBuildInputs = [
          bash
          pkgs.coreutils
        ];
      }
      ''
        echo "Checking Darwin entrypoint syntax..."
        bash -n ${../lib/sandbox/darwin/entrypoint.sh}

        echo "Verifying entrypoint handles mount env vars..."
        # Test that entrypoint processes WRAPIX_DIR_MOUNTS correctly
        SCRIPT="${../lib/sandbox/darwin/entrypoint.sh}"
        grep -q 'WRAPIX_DIR_MOUNTS' "$SCRIPT" || { echo "Missing WRAPIX_DIR_MOUNTS handling"; exit 1; }
        grep -q 'WRAPIX_FILE_MOUNTS' "$SCRIPT" || { echo "Missing WRAPIX_FILE_MOUNTS handling"; exit 1; }

        # Verify /etc/passwd uses correct home directory
        grep -q '/home/\$HOST_USER:/bin/bash' "$SCRIPT" || { echo "/etc/passwd should set home to /home/\$HOST_USER"; exit 1; }

        echo "Darwin entrypoint validation passed"
        mkdir $out
      '';

  # Verify Linux entrypoint script syntax
  linux-entrypoint-syntax =
    runCommandLocal "smoke-linux-entrypoint"
      {
        nativeBuildInputs = [ bash ];
      }
      ''
        echo "Checking Linux entrypoint syntax..."
        bash -n ${../lib/sandbox/linux/entrypoint.sh}

        echo "Linux entrypoint validation passed"
        mkdir $out
      '';
}
