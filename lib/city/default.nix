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
  beads,
  baseClaudeSettings,
}:

let
  inherit (builtins)
    concatStringsSep
    elem
    hasAttr
    isString
    listToAttrs
    mapAttrs
    path
    readFile
    substring
    ;
  inherit (pkgs.lib)
    escapeShellArg
    filterAttrs
    mapAttrsToList
    ;
  inherit (pkgs.lib.strings) toUpper;

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
    (
      if pkgs.stdenv.isDarwin then
        linuxPkgs.dockerTools.buildLayeredImage
      else
        linuxPkgs.dockerTools.streamLayeredImage
    )
      {
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
          ExposedPorts = listToAttrs (
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
      mayor ? { },
      resources ? { },
      secrets ? { },
      name ? "dev",
    }:
    let
      scoutInterval = scout.interval or "5m";
      scoutMaxBeads = scout.maxBeads or 10;
      mayorAutoDecompose = mayor.autoDecompose or false;

      # Build service container images
      serviceImages = mapAttrs mkServiceImage services;

      # One sandbox shared by ad-hoc container, ralph, and gc agents.
      # Include city scripts (wrapix-agent, beads-push) in the profile so
      # they're available inside agent containers (worker runs wrapix-agent).
      imagePackages = [
        cityScripts
      ];

      cityProfile = profile // {
        name = "gc-${profile.name}";
        packages = (profile.packages or [ ]) ++ imagePackages;
      };
      agentSandbox = if sandbox != null then sandbox else mkSandbox { profile = cityProfile; };

      # Ralph wired to the same sandbox
      ralphInstance = mkRalph { sandbox = agentSandbox; };

      imageName = "wrapix-${agentSandbox.profile.name}:latest";
      profileImage = agentSandbox.image;
      networkName = "gc-${name}";

      # Load image into podman: stream script on Linux, tarball on Darwin.
      # On Darwin, the image is a buildLayeredImage tar (Linux shebang won't run).
      loadImageCmd = if pkgs.stdenv.isDarwin then "cat ${profileImage}" else "${profileImage}";

      # Shared image loading snippet — used by both shellHook and app
      loadImageSnippet = ''
        XDG_CACHE_HOME="''${XDG_CACHE_HOME:-$HOME/.cache}"
        _img_version="$XDG_CACHE_HOME/wrapix/images/wrapix-${agentSandbox.profile.name}.version"
        mkdir -p "$XDG_CACHE_HOME/wrapix/images"
        if [ ! -f "$_img_version" ] || [ "$(cat "$_img_version")" != "${profileImage}" ]; then
          echo "Loading sandbox image..."
          ${loadImageCmd} | podman load -q >/dev/null
          echo "${profileImage}" > "$_img_version"
        elif ! podman image exists "${imageName}" 2>/dev/null; then
          echo "Reloading sandbox image (missing from podman store)..."
          ${loadImageCmd} | podman load -q >/dev/null
          echo "${profileImage}" > "$_img_version"
        fi
      '';

      # Provider path — references the live script in .gc/scripts/, which the
      # shellHook and app copy from the Nix store on every entry/run.
      # This MUST be a stable filesystem path, not a Nix store path — gc
      # caches the provider and Nix store paths change on every rebuild.
      providerScript = ".gc/scripts/provider.sh";

      # Dispatch check script — cooldown-aware scale_check for workers
      dispatchScript = pkgs.writeShellScript "wrapix-dispatch" (readFile ./dispatch.sh);

      # Default role formulas — consumers can override by placing files in formulas/
      defaultFormulas = {
        scout = ./formulas/scout.formula.toml;
        worker = ./formulas/worker.formula.toml;
        judge = ./formulas/judge.formula.toml;
        mayor = ./formulas/mayor.formula.toml;
      };

      # Copy formulas and orders into the Nix store as a directory.
      # Scout formula defaults are rewritten with configured values so gc
      # uses the right max_beads and poll_interval without extra config.
      formulasDir = pkgs.runCommand "wrapix-formulas" { } ''
        mkdir -p $out/orders/post-gate
        ${pkgs.gnused}/bin/sed \
          -e 's|^default = "5m"$|default = "${scoutInterval}"|' \
          -e 's|^default = "10"$|default = "${toString scoutMaxBeads}"|' \
          ${./formulas/scout.formula.toml} > $out/wrapix-scout.formula.toml
        cp ${./formulas/worker.formula.toml} $out/wrapix-worker.formula.toml
        cp ${./formulas/judge.formula.toml} $out/wrapix-judge.formula.toml
        ${pkgs.gnused}/bin/sed \
          -e 's|^default = "false"$|default = "${if mayorAutoDecompose then "true" else "false"}"|' \
          ${./formulas/mayor.formula.toml} > $out/wrapix-mayor.formula.toml
        cp ${./orders/post-gate/order.toml} $out/orders/post-gate/order.toml
      '';

      # Source-relative paths for live symlinks (no direnv reload needed)
      scriptNames = [
        "dispatch.sh"
        "entrypoint.sh"
        "gate.sh"
        "judge-merge.sh"
        "post-gate.sh"
        "provider.sh"
        "recovery.sh"
        "stage-gc-home.sh"
        "worker-collect.sh"
        "worker-setup.sh"
      ];
      promptNames = [
        "judge.md"
        "mayor.md"
        "scout.md"
        "worker.md"
      ];

      # Stage formulas and script symlinks into .gc/.
      # Shared by shellHook, app entrypoint, and integration tests so
      # they all exercise the same symlink creation path.
      stageGcLayout = pkgs.writeShellScript "stage-gc-layout" ''
        mkdir -p .gc/formulas .gc/scripts
        for f in ${formulasDir}/*.formula.toml; do
          cp -f --remove-destination "$f" .gc/formulas/
        done
        chmod -R u+w .gc/formulas/orders 2>/dev/null || true
        rm -rf .gc/formulas/orders
        cp -r --no-preserve=mode ${formulasDir}/orders .gc/formulas/
        for f in ${concatStringsSep " " scriptNames}; do
          ln -sf "../../lib/city/$f" .gc/scripts/"$f"
        done
      '';

      # Content-addressed store copies for integration tests (Nix sandbox
      # can't reach the source tree, so tests need real store paths).
      # builtins.path with a name ensures the hash depends only on file
      # content, not on the position within self.
      scriptsStore = path {
        name = "city-scripts";
        path = ./.;
        filter = path: _type: elem (baseNameOf path) scriptNames;
      };
      promptsStore = path {
        name = "city-prompts";
        path = ./prompts;
        filter = path: _type: elem (baseNameOf path) promptNames;
      };

      # Worker scale_check: cooldown-aware when cooldown is non-zero
      workerScaleCheck =
        if cooldown == "0" then
          "bd list --metadata-field gc.routed_to=worker --status open,in_progress --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0"
        else
          "GC_COOLDOWN=${cooldown} GC_WORKSPACE=\"$(pwd)\" ${dispatchScript}";

      # Build the city.toml configuration (matches gc's Go config schema)
      cityConfig = {
        workspace = {
          inherit name;
          # NOTE: Do NOT set `provider = "claude"` here — that activates gc's
          # built-in claude provider which manages sessions via HOST tmux,
          # conflicting with the exec session provider. Agent invocation is
          # handled by wrapix-agent inside containers. (wx-entt5)
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

        # Host-side gc daemon talks to dolt over the published port on
        # 127.0.0.1. Role containers reach dolt by container hostname; the
        # provider script injects BEADS_DOLT_SERVER_HOST=$GC_BEADS_DOLT_CONTAINER
        # into each container's env, overriding this value.
        dolt = {
          host = "127.0.0.1";
          port = 99999;
        };

        daemon = {
          patrol_interval = "10s";
          max_restarts = 5;
          restart_window = "1h";
        };

        convergence = {
          max_per_agent = 2;
          max_total = 10;
        };

        # scale_check uses `bd list` so orphaned in_progress beads resume.
        # prompt_template resolves against the staged .wrapix/city/current/.
        agent = [
          {
            name = "mayor";
            scope = "city";
            scale_check = "echo 0";
            prompt_template = ".wrapix/city/current/prompts/mayor.md";
          }
          {
            name = "scout";
            scope = "city";
            max_active_sessions = 1;
            min_active_sessions = 0;
            scale_check = "bd list --metadata-field gc.routed_to=scout --status open,in_progress --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0";
            prompt_template = ".wrapix/city/current/prompts/scout.md";
          }
          {
            name = "worker";
            scope = "city";
            max_active_sessions = workers;
            min_active_sessions = 0;
            scale_check = workerScaleCheck;
            prompt_template = ".wrapix/city/current/prompts/worker.md";
          }
          {
            name = "judge";
            scope = "city";
            max_active_sessions = 1;
            min_active_sessions = 0;
            scale_check = "bd list --metadata-field gc.routed_to=judge --status open,in_progress --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0";
            prompt_template = ".wrapix/city/current/prompts/judge.md";
          }
          {
            # Override the dog agent injected by system packs (gastown,
            # maintenance, dolt). max_active_sessions=0 prevents gc from
            # creating any dog sessions. (wx-m7a1d)
            name = "dog";
            scope = "city";
            max_active_sessions = 0;
            min_active_sessions = 0;
            scale_check = "echo 0";
          }
        ];

        # [[named_session]] — persistent sessions that gc auto-starts
        named_session = [
          {
            template = "mayor";
            mode = "always";
          }
          {
            template = "scout";
            mode = "always";
          }
          {
            template = "judge";
            mode = "always";
          }
        ];
      };

      cityToml = pkgs.writeText "city.toml" (toTOML cityConfig);

      # baseClaudeSettings + SessionStart/PreCompact hooks. wrapix-prime-hook
      # is provided by cityScripts and reads $WRAPIX_CITY_DIR/$GC_AGENT.
      cityClaudeSettings = baseClaudeSettings // {
        hooks = (baseClaudeSettings.hooks or { }) // {
          SessionStart = [
            {
              matcher = "";
              hooks = [
                {
                  type = "command";
                  command = "wrapix-prime-hook";
                }
              ];
            }
          ];
          PreCompact = [
            {
              matcher = "";
              hooks = [
                {
                  type = "command";
                  command = "wrapix-prime-hook";
                }
              ];
            }
          ];
        };
      };

      cityClaudeSettingsJson = pkgs.writeText "city-claude-settings.json" (
        builtins.toJSON cityClaudeSettings
      );

      cityTmuxConf = pkgs.writeText "city-tmux.conf" ''
        set -g mouse on
      '';

      # Staged artifacts read by containers via $WRAPIX_CITY_DIR.
      cityConfigDir = pkgs.runCommand "wrapix-city-config" { } ''
        mkdir -p $out/prompts
        cp ${cityToml} $out/city.toml
        cp ${cityClaudeSettingsJson} $out/claude-settings.json
        cp ${cityTmuxConf} $out/tmux.conf
        for f in ${promptsStore}/*; do
          cp "$f" $out/prompts/"$(basename "$f")"
        done
      '';

      # Secrets validation — claude secret is required
      secretsValid =
        if services != { } then
          assert hasAttr "claude" secrets || throw "mkCity: secrets.claude is required";
          true
        else
          true;

      # Classify each secret: starts with "/" = file path, else = env var name.
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

      envSecrets = filterAttrs (_: s: s.type == "env") classifiedSecrets;
      fileSecrets = filterAttrs (_: s: s.type == "file") classifiedSecrets;

      # Env-var secrets: read host env var at shellHook/app runtime, pass to
      # container. The ''${…} escape keeps the expansion in the emitted
      # bash rather than evaluating it in Nix.
      secretEnvLines = mapAttrsToList (name: s: ''--env="${toUpper name}=''${${s.var}}"'') envSecrets;

      # File-path secrets: bind-mount read-only into the container.
      secretFileLines = mapAttrsToList (
        name: s: ''--volume="${s.path}:/run/secrets/${name}:ro"''
      ) fileSecrets;

      # Well-known file secrets that /git-ssh-setup.sh reads as env vars.
      wellKnownSecretEnv = {
        deployKey = "WRAPIX_DEPLOY_KEY";
        signingKey = "WRAPIX_SIGNING_KEY";
      };
      wellKnownSecretLines = mapAttrsToList (
        name: _s: "--env=${wellKnownSecretEnv.${name}}=/run/secrets/${name}"
      ) (filterAttrs (n: _: hasAttr n wellKnownSecretEnv) fileSecrets);

      secretFlagsValue = concatStringsSep " " (secretEnvLines ++ secretFileLines ++ wellKnownSecretLines);
      secretFlagsExport = "export GC_SECRET_FLAGS=${escapeShellArg secretFlagsValue}";

      # City helper scripts bundled for PATH (content-addressed — only
      # rebuilds when script text changes, not when unrelated files change)
      cityScripts = pkgs.symlinkJoin {
        name = "wrapix-city-scripts";
        paths = [
          (pkgs.writeShellScriptBin "wrapix-agent" (readFile ./agent.sh))
          (pkgs.writeShellScriptBin "beads-push" (readFile ../../scripts/beads-push))
          (pkgs.writeShellScriptBin "wrapix-prime-hook" (readFile ./prime-hook.sh))
        ];
      };

      # Shell hook: copies config and exports env vars for provider
      shellHook = ''
        ${ralphInstance.shellHook}
        export GC_CITY_NAME="${name}"
        export GC_WORKSPACE="$(pwd)"
        export GC_AGENT_IMAGE="${imageName}"
        export GC_PODMAN_NETWORK="${networkName}"
        export GC_COOLDOWN="${cooldown}"
        export SCOUT_MAX_BEADS="${toString scoutMaxBeads}"
        ${secretFlagsExport}

        ${loadImageSnippet}

        # Stage city-config; provider.sh re-stages on role start for drift.
        mkdir -p .wrapix/city
        _city_stage_tmp=".wrapix/city/.staging.$$"
        rm -rf "$_city_stage_tmp"
        cp -rL --no-preserve=mode ${cityConfigDir} "$_city_stage_tmp"
        chmod -R u+w "$_city_stage_tmp"
        rm -rf .wrapix/city/current
        mv -T "$_city_stage_tmp" .wrapix/city/current

        cp -f --remove-destination .wrapix/city/current/city.toml city.toml

        ${stageGcLayout}

        # Ensure podman network exists (NixOS module creates via systemd)
        if command -v podman >/dev/null 2>&1; then
          if ! podman network exists "${networkName}" 2>/dev/null; then
            podman network create "${networkName}" >/dev/null 2>&1 || true
          fi
        fi

        # Point gc commands at gc home so they don't touch host .beads/.
        # The entrypoint stages gc home (rm -rf + recreate); here we only
        # set the env var if gc home already exists — no re-staging.
        if [ -d .gc/home/.gc ]; then
          export GC_CITY="$(pwd)/.gc/home"
        fi
      '';

      # Packages for devShell: gc, bd, ralph scripts, agent wrapper, sandbox.
      # gc runtime deps (tmux, procps, lsof) are included so the devShell
      # is self-contained — gc doctor/start checks for these at startup.
      shellPackages = ralphInstance.packages ++ [
        beads.cli
        beads.push
        cityScripts
        pkgs.gc
        pkgs.lsof
        pkgs.procps
        pkgs.tmux
      ];

      # Pre-built devShell with everything on PATH
      devShell = pkgs.mkShell {
        packages = shellPackages;
        inherit shellHook;
      };

      # Extend devShell with consumer extras
      cityMkDevShell =
        extra:
        pkgs.mkShell {
          packages = shellPackages ++ (extra.packages or [ ]);
          shellHook = ''
            ${shellHook}
            ${extra.shellHook or ""}
          '';
        };

      # App for `nix run .#city` — sets up env and execs entrypoint.sh on the host
      app = {
        meta.description = "Gas City orchestration loop";
        type = "app";
        program = "${pkgs.writeShellScriptBin "wrapix-city" ''
          set -euo pipefail
          export GC_CITY_NAME="${name}"
          export GC_WORKSPACE="$(pwd)"
          export GC_AGENT_IMAGE="${imageName}"
          export GC_PODMAN_NETWORK="${networkName}"
          export SCOUT_MAX_BEADS="${toString scoutMaxBeads}"
          ${secretFlagsExport}

          # Ensure the per-workspace beads dolt container is running
          # and propagate its host/port to child processes (gc → bd).
          ${beads.cli}/bin/beads-dolt start "$GC_WORKSPACE"
          export BEADS_DOLT_SERVER_HOST=127.0.0.1
          BEADS_DOLT_SERVER_PORT="$(${beads.cli}/bin/beads-dolt port "$GC_WORKSPACE")"
          export BEADS_DOLT_SERVER_PORT
          export BEADS_DOLT_AUTO_START=0

          ${loadImageSnippet}

          # Stage city-config — see shellHook above for rationale.
          mkdir -p .wrapix/city
          _city_stage_tmp=".wrapix/city/.staging.$$"
          rm -rf "$_city_stage_tmp"
          cp -rL --no-preserve=mode ${cityConfigDir} "$_city_stage_tmp"
          chmod -R u+w "$_city_stage_tmp"
          rm -rf .wrapix/city/current
          mv -T "$_city_stage_tmp" .wrapix/city/current
          cp -f --remove-destination .wrapix/city/current/city.toml city.toml

          # Pre-create the .gc/ layout so gc start never runs auto-init
          # (which scaffolds unwanted root-level dirs and overwrites beads).
          mkdir -p .gc/cache .gc/system .gc/runtime
          touch .gc/events.jsonl

          ${stageGcLayout}

          if ! podman network exists "${networkName}" 2>/dev/null; then
            podman network create "${networkName}" >/dev/null
          fi

          exec .gc/scripts/entrypoint.sh
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
      packages = shellPackages;
      mkDevShell = cityMkDevShell;

      # Shared sandbox (ad-hoc container via sandbox.package)
      sandbox = agentSandbox;

      # Ralph instance (e.g. city.ralph.app)
      ralph = ralphInstance;

      # The generated city.toml
      config = cityToml;

      # Staged dir (see flake.nix: packages.${system}.city-config).
      configDir = cityConfigDir;

      # TOML content as a Nix attrset (for programmatic access)
      configAttrs = cityConfig;

      # Provider script path (exec:<path> reference)
      provider = "exec:${providerScript}";

      # Service container images keyed by service name
      inherit serviceImages;

      # Classified secrets metadata
      inherit classifiedSecrets;

      # Single source of truth for podman secret flags — consumed by the
      # devShell/app shellHook and by modules/city.nix so the systemd,
      # `nix develop`, and `nix run .#city` entry points all plumb deploy
      # and signing keys into role containers the same way.
      secretFlags = secretFlagsValue;

      # Default role formulas (directory of .formula.toml files)
      formulas = formulasDir;

      # City script and prompt file names (symlinked to source tree at runtime)
      inherit scriptNames promptNames;

      # Stage .gc/formulas + .gc/scripts (shared by shellHook, app, and tests)
      inherit stageGcLayout;

      # Content-addressed store copies (for integration tests in Nix sandbox)
      scripts = scriptsStore;
      prompts = promptsStore;

      # Individual formula paths for selective override
      inherit defaultFormulas;

      inherit imageName networkName;

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
      mayorConfig = {
        autoDecompose = mayorAutoDecompose;
      };
    };

in
{
  inherit mkCity;
}
