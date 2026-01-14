{
  pkgs,
  system,
  linuxPkgs,
}:

let
  inherit (builtins) elem;

  isDarwin = system == "aarch64-darwin";
  isLinux = elem system [
    "aarch64-linux"
    "x86_64-linux"
  ];

  darwinSandbox = import ./darwin { inherit pkgs; };
  linuxSandbox = import ./linux { inherit pkgs; };

  # Profiles must use Linux packages (they contain Linux-only tools like iproute2)
  profiles = import ./profiles.nix { pkgs = linuxPkgs; };

  # Build the container image using Linux packages
  # On Darwin, this will use a remote Linux builder if configured
  mkImage =
    { profile, entrypointScript }:
    import ./image.nix {
      pkgs = linuxPkgs;
      inherit profile entrypointScript;
      claudePackage = linuxPkgs.claude-code;
    };

  # Merge extra packages/mounts/env into a profile
  extendProfile =
    profile:
    {
      packages ? [ ],
      mounts ? [ ],
      env ? { },
    }:
    profile
    // {
      packages = (profile.packages or [ ]) ++ packages;
      mounts = (profile.mounts or [ ]) ++ mounts;
      env = (profile.env or { }) // env;
    };

  mkSandbox =
    {
      profile,
      deployKey ? null,
      # Extra packages to add without using deriveProfile
      packages ? [ ],
      # Extra mounts to add without using deriveProfile
      mounts ? [ ],
      # Extra env vars to add without using deriveProfile
      env ? { },
    }:
    let
      finalProfile = extendProfile profile { inherit packages mounts env; };
    in
    if isLinux then
      linuxSandbox.mkSandbox {
        profile = finalProfile;
        inherit deployKey;
        profileImage = mkImage {
          profile = finalProfile;
          entrypointScript = ./linux/entrypoint.sh;
        };
      }
    else if isDarwin then
      darwinSandbox.mkSandbox {
        profile = finalProfile;
        inherit deployKey;
        profileImage = mkImage {
          profile = finalProfile;
          entrypointScript = ./darwin/entrypoint.sh;
        };
      }
    else
      throw "Unsupported system: ${system}";

in
{
  inherit mkSandbox profiles;
}
