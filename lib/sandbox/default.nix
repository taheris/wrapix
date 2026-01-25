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

  # Claude config (~/.claude.json) - onboarding state and runtime flags
  claudeConfig = {
    bypassPermissionsModeAccepted = true;
    hasCompletedOnboarding = true;
    hasSeenTasksHint = true;
    numStartups = 1;
    officialMarketplaceAutoInstallAttempted = true;
  };

  # Claude settings (~/.claude/settings.json) - user preferences
  claudeSettings = {
    "$schema" = "https://json.schemastore.org/claude-code-settings.json";
    autoUpdates = false;
    env = {
      ANTHROPIC_MODEL = "opus";
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
      DISABLE_AUTOUPDATER = "1";
      DISABLE_ERROR_REPORTING = "1";
      DISABLE_TELEMETRY = "1";
    };
    hooks = {
      Notification = [
        {
          matcher = "";
          hooks = [
            {
              type = "command";
              command = "wrapix-notify 'Claude Code' 'Waiting for input...'";
            }
          ];
        }
      ];
    };
  };

  # Build the container image using Linux packages
  # On Darwin, this will use a remote Linux builder if configured
  mkImage =
    { profile, entrypointSh }:
    import ./image.nix {
      pkgs = linuxPkgs;
      inherit
        profile
        entrypointSh
        claudeConfig
        claudeSettings
        ;
      entrypointPkg = linuxPkgs.claude-code;
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
      profile ? profiles.base,
      cpus ? null,
      memoryMb ? 4096,
      deployKey ? null,
      packages ? [ ],
      mounts ? [ ],
      env ? { },
    }:
    let
      finalProfile = extendProfile profile { inherit packages mounts env; };

    in
    if isLinux then
      linuxSandbox.mkSandbox {
        profile = finalProfile;
        inherit cpus memoryMb deployKey;
        profileImage = mkImage {
          profile = finalProfile;
          entrypointSh = ./linux/entrypoint.sh;
        };
      }
    else if isDarwin then
      darwinSandbox.mkSandbox {
        profile = finalProfile;
        inherit cpus memoryMb deployKey;
        profileImage = mkImage {
          profile = finalProfile;
          entrypointSh = ./darwin/entrypoint.sh;
        };
      }
    else
      throw "Unsupported system: ${system}";

in
{
  inherit mkSandbox profiles;
}
