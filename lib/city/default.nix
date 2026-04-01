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
  profiles,
}:

let
  inherit (builtins)
    concatStringsSep
    hasAttr
    isString
    mapAttrs
    replaceStrings
    substring
    ;
  inherit (pkgs.lib)
    filterAttrs
    mapAttrsToList
    optionalAttrs
    ;

  # Convert a Nix attrset into TOML text.
  # Handles strings, integers, booleans, lists of strings, and nested tables.
  toTOML =
    let
      # Escape a TOML string value
      escapeStr = s: "\"${replaceStrings [ "\\" "\"" "\n" ] [ "\\\\" "\\\"" "\\n" ] s}\"";

      # Format a single value
      fmtValue =
        v:
        if builtins.isBool v then
          (if v then "true" else "false")
        else if builtins.isInt v then
          toString v
        else if builtins.isString v then
          escapeStr v
        else if builtins.isList v then
          "[${concatStringsSep ", " (map fmtValue v)}]"
        else
          throw "toTOML: unsupported value type";

      # Render a table at a given key path
      renderTable =
        prefix: attrs:
        let
          scalars = filterAttrs (_: v: !(builtins.isAttrs v)) attrs;
          tables = filterAttrs (_: v: builtins.isAttrs v) attrs;

          scalarLines = mapAttrsToList (k: v: "${k} = ${fmtValue v}") scalars;

          tableBlocks = mapAttrsToList (
            k: v:
            let
              fullKey = if prefix == "" then k else "${prefix}.${k}";
            in
            "\n[${fullKey}]\n${renderTable fullKey v}"
          ) tables;
        in
        concatStringsSep "\n" (scalarLines ++ tableBlocks);
    in
    attrs: renderTable "" attrs;

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
      profile ? profiles.base,
      agent ? "claude",
      workers ? 1,
      cooldown ? "0",
      scout ? { },
      resources ? { },
      secrets ? { },
    }:
    let
      scoutInterval = scout.interval or "5m";
      scoutMaxBeads = scout.maxBeads or 10;

      # Build service container images
      serviceImages = mapAttrs mkServiceImage services;

      # Build agent sandbox (for worker/scout/reviewer containers)
      agentSandbox = mkSandbox { inherit profile; };

      # Provider script — placeholder path, actual script is in lib/city/provider.sh
      # At build time we generate the reference; the script is implemented separately.
      providerScript = pkgs.writeShellScript "wrapix-provider" ''
        set -euo pipefail
        echo "wrapix provider stub — see lib/city/provider.sh for implementation" >&2
        exit 1
      '';

      # Build the city.toml configuration
      cityConfig = {
        city = {
          provider = "exec:${providerScript}";
        };

        session = {
          max_concurrent = workers;
          inherit cooldown;
        };

        scout = {
          interval = scoutInterval;
          max_beads = scoutMaxBeads;
        };

        agent = {
          type = agent;
        };
      }
      // optionalAttrs (resources != { }) {
        resources = mapAttrs (
          _role: res:
          { }
          // optionalAttrs (hasAttr "cpus" res) { inherit (res) cpus; }
          // optionalAttrs (hasAttr "memory" res) { inherit (res) memory; }
        ) resources;
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

    in
    assert secretsValid;
    {
      # The generated city.toml
      config = cityToml;

      # TOML content as a Nix attrset (for programmatic access)
      configAttrs = cityConfig;

      # Provider script path (exec:<path> reference)
      provider = "exec:${providerScript}";

      # Service container images keyed by service name
      inherit serviceImages;

      # Agent sandbox (used by provider to start agent containers)
      inherit agentSandbox;

      # Profile used for agent containers
      inherit profile;

      # Classified secrets metadata
      inherit classifiedSecrets;

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
