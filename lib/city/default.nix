# mkCity — multi-agent orchestration via Gas City
#
# Generates city.toml, a provider script reference, and service container
# images from Nix expressions.  Consumers never write TOML directly.
#
# See specs/gas-city.md for the full specification.
{
  pkgs,
  linuxPkgs,
  mkSandbox,
  mkRalph,
  profiles,
}:

let
  inherit (builtins)
    hasAttr
    isString
    mapAttrs
    substring
    ;
  inherit (pkgs.lib)
    mapAttrsToList
    ;

  toTOML = import ../util/toml.nix { inherit (pkgs) lib; };

  # Build a service container image from a Nix package
  mkServiceImage =
    name: svcCfg:
    let
      inherit (svcCfg) package;
      cmd = svcCfg.cmd or [ "${package}/bin/${package.pname or package.name or name}" ];
      environment = svcCfg.environment or { };
      ports = svcCfg.ports or [ ];

      envList = mapAttrsToList (k: v: "${k}=${v}") environment;
    in
    linuxPkgs.dockerTools.buildLayeredImage {
      name = "wrapix-svc-${name}";
      tag = "latest";
      maxLayers = 50;

      contents = [
        linuxPkgs.dockerTools.caCertificates
        package
      ];

      config = {
        Cmd = cmd;
        Env = [ "PATH=${package}/bin:/bin:/usr/bin" ] ++ envList;
        ExposedPorts = builtins.listToAttrs (
          map (p: {
            name = "${toString p}/tcp";
            value = { };
          }) ports
        );
      };
    };

  # The main mkCity function
  mkCity =
    {
      services ? { },
      sandbox ? null,
      profile ? profiles.base,
      agent ? "claude",
      workers ? 1,
      cooldown ? "0",
      scout ? { },
      resources ? { },
      secrets ? { },
      name ? "dev",
    }:
    let
      scoutInterval = scout.interval or "5m";
      scoutMaxBeads = scout.maxBeads or 10;

      # Build service container images
      serviceImages = mapAttrs mkServiceImage services;

      # One sandbox shared by ad-hoc container, ralph, and gc agents
      agentSandbox = if sandbox != null then sandbox else mkSandbox { inherit profile; };

      # Ralph wired to the same sandbox
      ralphInstance = mkRalph { sandbox = agentSandbox; };

      imageName = "wrapix-${agentSandbox.profile.name}:latest";
      networkName = "wrapix-${name}";

      # Provider script — copies lib/city/provider.sh into the Nix store
      providerScript = pkgs.writeShellScript "wrapix-provider" (builtins.readFile ./provider.sh);

      # Default role formulas — consumers can override by placing files in formulas/
      defaultFormulas = {
        scout = ./formulas/scout.formula.toml;
        worker = ./formulas/worker.formula.toml;
        reviewer = ./formulas/reviewer.formula.toml;
      };

      # Copy formulas into the Nix store as a directory
      formulasDir = pkgs.runCommand "wrapix-formulas" { } ''
        mkdir -p $out
        cp ${./formulas/scout.formula.toml} $out/wrapix-scout.formula.toml
        cp ${./formulas/worker.formula.toml} $out/wrapix-worker.formula.toml
        cp ${./formulas/reviewer.formula.toml} $out/wrapix-reviewer.formula.toml
      '';

      # Build the city.toml configuration (matches gc's Go config schema)
      cityConfig = {
        workspace = {
          inherit name;
          provider = agent;
          max_active_sessions = workers;
        };

        session = {
          provider = "exec:${providerScript}";
        };

        formulas = {
          dir = ".gc/formulas";
        };

        beads = {
          provider = "bd";
        };

        daemon = {
          patrol_interval = "30s";
          max_restarts = 5;
          restart_window = "1h";
        };

        # [[agent]] — rendered as array of tables
        agent = [
          {
            name = "scout";
            scope = "city";
          }
          {
            name = "worker";
            scope = "city";
            max_active_sessions = workers;
          }
          {
            name = "reviewer";
            scope = "city";
          }
        ];
      };

      cityToml = pkgs.writeText "city.toml" (toTOML cityConfig);

      # Secrets validation — claude secret is required
      secretsValid =
        if services != { } then
          assert hasAttr "claude" secrets || throw "mkCity: secrets.claude is required";
          true
        else
          true;

      # Classify each secret: starts with "/" = file path, else = env var name
      classifiedSecrets = mapAttrs (
        _name: value:
        if isString value && substring 0 1 value == "/" then
          {
            type = "file";
            path = value;
          }
        else
          {
            type = "env";
            var = value;
          }
      ) secrets;

      # City helper scripts bundled for PATH
      cityScripts = pkgs.runCommand "wrapix-city-scripts" { } ''
        mkdir -p $out/bin
        cp ${./agent.sh} $out/bin/wrapix-agent
        chmod +x $out/bin/wrapix-agent
      '';

      # Shell hook: copies config and exports env vars for provider
      shellHook = ''
        ${ralphInstance.shellHook}
        export GC_CITY_NAME="${name}"
        export GC_WORKSPACE="$(pwd)"
        export GC_AGENT_IMAGE="${imageName}"
        export GC_PODMAN_NETWORK="${networkName}"

        # Copy Nix-generated config so gc finds it
        # (files must be real, not store symlinks, for container mounts)
        cp -f ${cityToml} city.toml
        mkdir -p .gc/formulas
        for f in ${formulasDir}/*.formula.toml; do
          cp -f "$f" .gc/formulas/
        done
      '';

      # Packages for devShell: gc, bd, ralph scripts, agent wrapper, sandbox
      cityPackages = ralphInstance.packages ++ [
        pkgs.gc
        cityScripts
      ];

      # Pre-built devShell with everything on PATH
      devShell = pkgs.mkShell {
        packages = cityPackages;
        inherit shellHook;
      };

      # Extend devShell with consumer extras
      cityMkDevShell =
        extra:
        pkgs.mkShell {
          packages = cityPackages ++ (extra.packages or [ ]);
          shellHook = ''
            ${shellHook}
            ${extra.shellHook or ""}
          '';
        };

      # App for `nix run .#city` — sets up env and runs gc
      app = {
        meta.description = "Gas City orchestration loop";
        type = "app";
        program = "${pkgs.writeShellScriptBin "wrapix-city" ''
          set -euo pipefail
          export GC_CITY_NAME="${name}"
          export GC_WORKSPACE="$(pwd)"
          export GC_AGENT_IMAGE="${imageName}"
          export GC_PODMAN_NETWORK="${networkName}"

          cp -f ${cityToml} city.toml
          mkdir -p .gc/formulas
          for f in ${formulasDir}/*.formula.toml; do
            cp -f "$f" .gc/formulas/
          done

          exec ${pkgs.gc}/bin/gc start --foreground "$@"
        ''}/bin/wrapix-city";
      };

    in
    assert secretsValid;
    {
      # Consumer-facing API (like mkRalph)
      inherit
        app
        devShell
        shellHook
        ;
      packages = cityPackages;
      mkDevShell = cityMkDevShell;

      # Shared sandbox (ad-hoc container via sandbox.package)
      sandbox = agentSandbox;

      # Ralph instance (e.g. city.ralph.app)
      ralph = ralphInstance;

      # The generated city.toml
      config = cityToml;

      # TOML content as a Nix attrset (for programmatic access)
      configAttrs = cityConfig;

      # Provider script path (exec:<path> reference)
      provider = "exec:${providerScript}";

      # Service container images keyed by service name
      inherit serviceImages;

      # Classified secrets metadata
      inherit classifiedSecrets;

      # Default role formulas (directory of .formula.toml files)
      formulas = formulasDir;

      # Individual formula paths for selective override
      inherit defaultFormulas;

      # Re-export inputs for downstream consumers (NixOS module, etc.)
      inherit
        agent
        workers
        cooldown
        resources
        ;
      scoutConfig = {
        interval = scoutInterval;
        maxBeads = scoutMaxBeads;
      };
    };

in
{
  inherit mkCity;
}
