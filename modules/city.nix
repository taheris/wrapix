# NixOS module for services.wrapix.cities.<name>
#
# Generates systemd units, a podman network per city, and invokes mkCity
# to produce city.toml and container images.
#
# See specs/gas-city.md for the full specification.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    filterAttrs
    mapAttrs
    mapAttrs'
    mapAttrsToList
    mkIf
    mkMerge
    mkOption
    nameValuePair
    types
    ;

  cfg = config.services.wrapix;

  # Import wrapix library — the module receives pkgs with overlays applied
  wrapix = import ../lib {
    inherit pkgs;
    inherit (pkgs.stdenv.hostPlatform) system;
    linuxPkgs = pkgs;
  };

  # Resolve a profile string shorthand to a profile attrset
  resolveProfile =
    p:
    if builtins.isString p then
      wrapix.profiles.${p}
        or (throw "services.wrapix.cities: unknown profile '${p}', expected one of: ${builtins.concatStringsSep ", " (builtins.attrNames wrapix.profiles)}")
    else
      p;

  # Per-city submodule options
  cityOpts =
    { name, ... }:
    {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to enable wrapix city '${name}'.";
        };

        workspace = mkOption {
          type = types.path;
          description = "Workspace directory (required on NixOS — no flake root).";
        };

        profile = mkOption {
          type = types.either types.str (types.attrsOf types.anything);
          default = "base";
          description = ''
            Profile for agent containers. String shorthand (e.g. "rust", "python",
            "base") is resolved via wrapix.profiles. An attrset is passed through
            directly.
          '';
        };

        services = mkOption {
          type = types.attrsOf (
            types.submodule {
              options = {
                package = mkOption {
                  type = types.package;
                  description = "Nix package for this service.";
                };
                cmd = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Override entrypoint command. Defaults to package binary.";
                };
                environment = mkOption {
                  type = types.attrsOf types.str;
                  default = { };
                  description = "Environment variables for the service container.";
                };
                ports = mkOption {
                  type = types.listOf types.port;
                  default = [ ];
                  description = "Exposed TCP ports.";
                };
                volumes = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Volume mounts (host:container format).";
                };
              };
            }
          );
          default = { };
          description = "Service containers managed by Gas City.";
        };

        secrets = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = ''
            Secrets mapping. String starting with "/" = file path (works with
            sops-nix, agenix, etc.). Any other string = host environment variable
            name. The "claude" secret is required when services are defined.
          '';
          example = {
            claude = "/run/secrets/claude-api-key";
            deployKey = "/run/secrets/deploy-key";
          };
        };

        agent = mkOption {
          type = types.str;
          default = "claude";
          description = "Agent type. Only 'claude' is supported.";
        };

        workers = mkOption {
          type = types.ints.positive;
          default = 1;
          description = "Maximum concurrent workers.";
        };

        cooldown = mkOption {
          type = types.str;
          default = "0";
          description = ''
            Time between task dispatches. Supports "30m", "1h", "2h30m", etc.
          '';
        };

        scout = mkOption {
          type = types.submodule {
            options = {
              interval = mkOption {
                type = types.str;
                default = "5m";
                description = "Scout polling interval.";
              };
              maxBeads = mkOption {
                type = types.ints.positive;
                default = 10;
                description = "Maximum open beads before scout pauses.";
              };
            };
          };
          default = { };
          description = "Scout configuration.";
        };

        resources = mkOption {
          type = types.attrsOf (
            types.submodule {
              options = {
                cpus = mkOption {
                  type = types.nullOr types.ints.positive;
                  default = null;
                  description = "CPU limit for this role.";
                };
                memory = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Memory limit for this role (e.g. \"4g\").";
                };
              };
            }
          );
          default = { };
          description = "Per-role resource limits (worker, scout, reviewer).";
          example = {
            worker = {
              cpus = 2;
              memory = "4g";
            };
          };
        };
      };
    };

  # Build the city derivation for a given city config
  mkCityForConfig =
    cityName: cityCfg:
    let
      profile = resolveProfile cityCfg.profile;

      # Convert service options to mkCity format
      serviceAttrs = mapAttrs (
        _svcName: svc:
        {
          inherit (svc) package;
        }
        // (if svc.cmd != [ ] then { inherit (svc) cmd; } else { })
        // (if svc.environment != { } then { inherit (svc) environment; } else { })
        // (if svc.ports != [ ] then { inherit (svc) ports; } else { })
      ) cityCfg.services;

      # Convert resource options — filter out null values
      resourceAttrs = mapAttrs (
        _role: res:
        filterAttrs (_: v: v != null) {
          inherit (res) cpus memory;
        }
      ) (filterAttrs (_: res: res.cpus != null || res.memory != null) cityCfg.resources);
    in
    wrapix.mkCity {
      name = cityName;
      services = serviceAttrs;
      inherit profile;
      inherit (cityCfg)
        agent
        workers
        cooldown
        secrets
        ;
      scout = {
        inherit (cityCfg.scout) interval maxBeads;
      };
      resources = resourceAttrs;
    };

  # Build secret flags for podman run — returns a list of shell-escaped args
  mkSecretArgs =
    cityCfg:
    let
      classified = mapAttrs (
        _name: value:
        if builtins.substring 0 1 value == "/" then
          {
            type = "file";
            path = value;
          }
        else
          {
            type = "env";
            var = value;
          }
      ) cityCfg.secrets;

      envSecrets = filterAttrs (_: s: s.type == "env") classified;
      fileSecrets = filterAttrs (_: s: s.type == "file") classified;

      # Env var secrets: read host env var and pass to container
      envLines = mapAttrsToList (
        name: s:
        let
          upperName = lib.strings.toUpper name;
        in
        ''--env="${upperName}=''${${s.var}}"''
      ) envSecrets;

      # File secrets: mount as read-only volumes
      fileLines = mapAttrsToList (name: s: ''--volume="${s.path}:/run/secrets/${name}:ro"'') fileSecrets;
    in
    envLines ++ fileLines;

  # All enabled cities
  enabledCities = filterAttrs (_: cityCfg: cityCfg.enable) cfg.cities;

  # Systemd service units for gc containers
  cityServices = mapAttrs' (
    name: cityCfg:
    let
      city = mkCityForConfig name cityCfg;
      resolvedProfile = resolveProfile cityCfg.profile;
      imageName = "wrapix-${resolvedProfile.name}:latest";
      networkName = "gc-${name}";
      containerName = "gc-${name}";
      secretArgs = mkSecretArgs cityCfg;
      entrypoint = pkgs.writeShellScript "gc-entrypoint-${name}" (
        builtins.readFile ../lib/city/entrypoint.sh
      );

      # Script to load all container images into podman
      loadImages = pkgs.writeShellScript "load-images-${name}" (
        ''
          set -euo pipefail
          ${city.sandbox.image} | ${pkgs.podman}/bin/podman load
        ''
        + builtins.concatStringsSep "" (
          mapAttrsToList (svcName: _svc: ''
            ${city.serviceImages.${svcName}} | ${pkgs.podman}/bin/podman load
          '') cityCfg.services
        )
      );

      # Script to run the gc container — shell script so env vars expand
      startScript = pkgs.writeShellScript "start-city-${name}" ''
        set -euo pipefail
        exec ${pkgs.podman}/bin/podman run \
          --rm \
          --name="${containerName}" \
          --network="${networkName}" \
          --volume=/run/podman/podman.sock:/run/podman/podman.sock \
          --volume="${toString cityCfg.workspace}:/workspace" \
          --volume="${city.config}:/etc/gc/city.toml:ro" \
          --volume="${city.formulas}:/etc/gc/formulas:ro" \
          --label=gc-city="${name}" \
          --env=GC_CITY_NAME="${name}" \
          --env=GC_WORKSPACE=/workspace \
          --env=GC_AGENT_IMAGE="${imageName}" \
          --env=GC_PODMAN_NETWORK="${networkName}" \
          ${builtins.concatStringsSep " \\\n      " secretArgs} \
          "${imageName}" \
          "${entrypoint}"
      '';
    in
    nameValuePair "wrapix-city-${name}" {
      description = "Wrapix Gas City: ${name}";
      after = [
        "network-online.target"
        "podman.service"
        "wrapix-city-${name}-network.service"
      ];
      requires = [
        "wrapix-city-${name}-network.service"
      ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "exec";
        Restart = "always";
        RestartSec = 10;
        ExecStartPre = [ "${loadImages}" ];
        ExecStart = "${startScript}";
        ExecStop = "${pkgs.podman}/bin/podman stop ${containerName}";
      };
    }
  ) enabledCities;

  # Systemd oneshot units for podman network creation
  networkServices = mapAttrs' (
    name: _cityCfg:
    let
      networkName = "gc-${name}";
    in
    nameValuePair "wrapix-city-${name}-network" {
      description = "Podman network for wrapix city: ${name}";
      after = [ "podman.service" ];
      requires = [ "podman.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "create-network-${name}" ''
          ${pkgs.podman}/bin/podman network create ${networkName} || true
        '';
        ExecStop = pkgs.writeShellScript "remove-network-${name}" ''
          ${pkgs.podman}/bin/podman network rm ${networkName} || true
        '';
      };
    }
  ) enabledCities;

in
{
  options.services.wrapix = {
    cities = mkOption {
      type = types.attrsOf (types.submodule cityOpts);
      default = { };
      description = "Gas City instances managed by wrapix.";
    };
  };

  config = mkIf (enabledCities != { }) {
    virtualisation.podman.enable = true;

    systemd.services = mkMerge [
      cityServices
      networkServices
    ];
  };
}
