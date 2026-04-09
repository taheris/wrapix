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
      doltPort ? 13306, # non-default to avoid colliding with bd auto-start (3306)
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
      cityProfile = profile // {
        packages = (profile.packages or [ ]) ++ [ cityScripts ];
      };
      agentSandbox = if sandbox != null then sandbox else mkSandbox { profile = cityProfile; };

      # Ralph wired to the same sandbox
      ralphInstance = mkRalph { sandbox = agentSandbox; };

      imageName = "wrapix-${agentSandbox.profile.name}:latest";
      profileImage = agentSandbox.image;
      networkName = "wrapix-${name}";

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
        "post-gate.sh"
        "provider.sh"
        "recovery.sh"
        "stage-gc-home.sh"
      ];
      promptNames = [
        "judge.md"
        "mayor.md"
        "scout.md"
        "worker.md"
      ];

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

      # Prefix for scale_check commands: the dolt container publishes
      # doltPort to localhost.  Override gc's stale metadata.json values.
      bdEnv = "BEADS_DOLT_SERVER_PORT=${toString doltPort} BEADS_DOLT_SERVER_HOST=127.0.0.1";

      # Worker scale_check: cooldown-aware when cooldown is non-zero
      workerScaleCheck =
        if cooldown == "0" then
          "${bdEnv} bd list --metadata-field gc.routed_to=worker --status open,in_progress --no-assignee --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0"
        else
          "GC_COOLDOWN=${cooldown} GC_WORKSPACE=\"$(pwd)\" ${dispatchScript}";

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

        # Dolt connection — the entrypoint starts a dolt container that
        # publishes this port to localhost.  gc reads this section for
        # its internal bd calls; without it, bd defaults to port 0.
        dolt = {
          host = "127.0.0.1";
          port = doltPort;
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

        # [[agent]] — rendered as array of tables
        # Custom scale_check: gc's default runs two bd queries which can
        # timeout under dolt contention (gc hardcodes 30s). A single
        # bd list query is ~2x faster and avoids the timeout.
        agent = [
          {
            name = "mayor";
            scope = "city";
            scale_check = "echo 0";
          }
          {
            name = "scout";
            scope = "city";
            scale_check = "${bdEnv} bd list --metadata-field gc.routed_to=scout --status open,in_progress --no-assignee --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0";
          }
          {
            name = "worker";
            scope = "city";
            max_active_sessions = workers;
            scale_check = workerScaleCheck;
          }
          {
            name = "judge";
            scope = "city";
            scale_check = "${bdEnv} bd list --metadata-field gc.routed_to=judge --status open,in_progress --no-assignee --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0";
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

      # City helper scripts bundled for PATH (content-addressed — only
      # rebuilds when script text changes, not when unrelated files change)
      cityScripts = pkgs.symlinkJoin {
        name = "wrapix-city-scripts";
        paths = [
          (pkgs.writeShellScriptBin "wrapix-agent" (readFile ./agent.sh))
          (pkgs.writeShellScriptBin "beads-push" (readFile ../../scripts/beads-push))
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
        export GC_DOLT_PORT="${toString doltPort}"
        export SCOUT_MAX_BEADS="${toString scoutMaxBeads}"

        ${loadImageSnippet}

        # Copy Nix-generated config so gc finds it (formulas have sed substitutions)
        cp -f --remove-destination ${cityToml} city.toml
        mkdir -p .gc/formulas .gc/scripts .gc/prompts
        for f in ${formulasDir}/*.formula.toml; do
          cp -f --remove-destination "$f" .gc/formulas/
        done
        # Copy orders (preserve directory structure)
        chmod -R u+w .gc/formulas/orders 2>/dev/null || true
        rm -rf .gc/formulas/orders
        cp -r --no-preserve=mode ${formulasDir}/orders .gc/formulas/
        # Symlink scripts to source tree (live — no direnv reload needed)
        _city_src="$GC_WORKSPACE/lib/city"
        for f in ${concatStringsSep " " scriptNames}; do
          ln -sf "$_city_src/$f" .gc/scripts/"$f"
        done
        # Symlink role prompts to source tree
        for f in ${concatStringsSep " " promptNames}; do
          ln -sf "$_city_src/prompts/$f" .gc/prompts/"$f"
        done

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

      # App for `nix run .#city` — sets up env and runs gc via entrypoint
      app = {
        meta.description = "Gas City orchestration loop";
        type = "app";
        program = "${pkgs.writeShellScriptBin "wrapix-city" ''
          set -euo pipefail
          export GC_CITY_NAME="${name}"
          export GC_WORKSPACE="$(pwd)"
          export GC_AGENT_IMAGE="${imageName}"
          export GC_PODMAN_NETWORK="${networkName}"
          export GC_DOLT_PORT="${toString doltPort}"
          export SCOUT_MAX_BEADS="${toString scoutMaxBeads}"

          ${loadImageSnippet}

          cp -f --remove-destination ${cityToml} city.toml

          # --- gc scaffold ---
          # Pre-create the .gc/ layout so gc start never runs auto-init
          # (which scaffolds unwanted root-level dirs and overwrites beads).
          mkdir -p .gc/cache .gc/system .gc/runtime
          touch .gc/events.jsonl

          # Overlay our formulas and scripts
          mkdir -p .gc/formulas .gc/scripts .gc/prompts
          for f in ${formulasDir}/*.formula.toml; do
            cp -f --remove-destination "$f" .gc/formulas/
          done
          chmod -R u+w .gc/formulas/orders 2>/dev/null || true
          rm -rf .gc/formulas/orders
          cp -r --no-preserve=mode ${formulasDir}/orders .gc/formulas/
          # Symlink scripts to source tree (live)
          _city_src="$GC_WORKSPACE/lib/city"
          for f in ${concatStringsSep " " scriptNames}; do
            ln -sf "$_city_src/$f" .gc/scripts/"$f"
          done
          # Symlink role prompts to source tree
          for f in ${concatStringsSep " " promptNames}; do
            ln -sf "$_city_src/prompts/$f" .gc/prompts/"$f"
          done

          # Ensure the podman network exists (NixOS module creates it via
          # systemd; nix run needs to do it here).
          if ! podman network exists "${networkName}" 2>/dev/null; then
            podman network create "${networkName}" >/dev/null
          fi

          exec "$GC_WORKSPACE/lib/city/entrypoint.sh"
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

      # City script and prompt file names (symlinked to source tree at runtime)
      inherit scriptNames promptNames;

      # Content-addressed store copies (for integration tests in Nix sandbox)
      scripts = scriptsStore;
      prompts = promptsStore;

      # Individual formula paths for selective override
      inherit defaultFormulas;

      # Re-export inputs for downstream consumers (NixOS module, etc.)
      inherit
        agent
        workers
        cooldown
        doltPort
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
