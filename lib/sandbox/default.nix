{
  pkgs,
  system,
  linuxPkgs,
}:

let
  inherit (builtins)
    concatMap
    concatStringsSep
    elem
    mapAttrs
    attrValues
    ;

  isDarwin = system == "aarch64-darwin";
  isLinux = elem system [
    "aarch64-linux"
    "x86_64-linux"
  ];

  darwinSandbox = import ./darwin { inherit pkgs; };
  linuxSandbox = import ./linux { inherit pkgs; };

  # Profiles must use Linux packages (they contain Linux-only tools like iproute2)
  profiles = import ./profiles.nix { pkgs = linuxPkgs; };

  # MCP server registry (uses Linux packages for server binaries)
  mcpRegistry = import ../mcp { pkgs = linuxPkgs; };

  # Claude config (~/.claude.json) - onboarding state and runtime flags
  claudeConfig = {
    bypassPermissionsModeAccepted = true;
    hasCompletedOnboarding = true;
    hasSeenTasksHint = true;
    numStartups = 1;
    officialMarketplaceAutoInstallAttempted = true;
  };

  # Claude settings (~/.claude/settings.json) - user preferences
  # Base settings that can be extended with MCP servers
  baseClaudeSettings = {
    "$schema" = "https://json.schemastore.org/claude-code-settings.json";
    autoUpdates = false;
    env = {
      ANTHROPIC_MODEL = "claude-opus-4-6";
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
      CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
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
    {
      profile,
      entrypointSh,
      krunSupport ? false,
      claudeSettings ? baseClaudeSettings,
    }:
    import ./image.nix {
      pkgs = linuxPkgs;
      inherit
        profile
        entrypointSh
        krunSupport
        claudeConfig
        claudeSettings
        ;
      entrypointPkg = linuxPkgs.claude-code;
    };

  # Merge extra packages/mounts/env/networkAllowlist into a profile
  extendProfile =
    profile:
    {
      packages ? [ ],
      mounts ? [ ],
      env ? { },
      networkAllowlist ? [ ],
    }:
    profile
    // {
      packages = (profile.packages or [ ]) ++ packages;
      mounts = (profile.mounts or [ ]) ++ mounts;
      env = (profile.env or { }) // env;
      networkAllowlist = (profile.networkAllowlist or [ ]) ++ networkAllowlist;
    };

  # Build MCP server configurations from the mcp attrset
  # Returns { packages, mcpServers } where:
  #   - packages: flattened list of all server runtime packages
  #   - mcpServers: attrset of server configs for claudeSettings
  buildMcpConfig =
    mcp:
    let
      # For each enabled server, look up definition and build config
      serverConfigs = mapAttrs (
        name: userConfig:
        let
          serverDef = mcpRegistry.${name} or (throw "Unknown MCP server: ${name}");
          serverConfig = serverDef.mkServerConfig userConfig;
        in
        {
          inherit (serverDef) packages;
          config = serverConfig;
        }
      ) mcp;
    in
    {
      packages = concatMap (s: s.packages) (attrValues serverConfigs);
      mcpServers = mapAttrs (_name: s: s.config) serverConfigs;
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
      mcp ? { },
    }:
    let
      # Build MCP configuration from enabled servers
      mcpConfig = buildMcpConfig mcp;

      # Extend profile with user packages + MCP server packages
      finalProfile = extendProfile profile {
        packages = packages ++ mcpConfig.packages;
        inherit mounts env;
      };

      # Merge MCP servers into Claude settings
      finalClaudeSettings = baseClaudeSettings // {
        inherit (mcpConfig) mcpServers;
      };

      # Compute comma-separated network allowlist for WRAPIX_NETWORK=limit mode
      networkAllowlist = concatStringsSep "," (finalProfile.networkAllowlist or [ ]);

      package =
        if isLinux then
          linuxSandbox.mkSandbox {
            profile = finalProfile;
            inherit
              cpus
              memoryMb
              deployKey
              networkAllowlist
              ;
            profileImage = mkImage {
              profile = finalProfile;
              entrypointSh = ./linux/entrypoint.sh;
              krunSupport = true;
              claudeSettings = finalClaudeSettings;
            };
          }
        else if isDarwin then
          darwinSandbox.mkSandbox {
            profile = finalProfile;
            inherit
              cpus
              memoryMb
              deployKey
              networkAllowlist
              ;
            profileImage = mkImage {
              profile = finalProfile;
              entrypointSh = ./darwin/entrypoint.sh;
              claudeSettings = finalClaudeSettings;
            };
          }
        else
          throw "Unsupported system: ${system}";

    in
    {
      inherit package;
      profile = finalProfile;
    };

in
{
  inherit mkSandbox profiles;
}
