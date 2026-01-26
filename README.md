# Wrapix

Secure sandbox for running [Claude Code](https://claude.ai/code) in isolated containers.

- **Linux**: Podman rootless container
- **macOS**: Apple [container CLI](https://github.com/apple/container) (macOS 26+, Apple Silicon)

## Security Model

The sandbox provides **filesystem and process isolation**—code inside the container cannot access your host filesystem outside `/workspace` or affect host processes.

**Network access is unrestricted by design.** Sandboxed code can reach any internet host, which is intentional for AI research, package managers, and git operations. If you need network isolation, additional firewall rules must be applied externally.

For the overall security model, see [architecture.md](specs/architecture.md).

## Usage

### Without flake

```bash
nix run github:taheris/wrapix                # base profile
nix run github:taheris/wrapix#wrapix-rust    # rust profile
nix run github:taheris/wrapix#wrapix-python  # python profile
```

### Flake with base profile

```nix
{
  inputs = {
    wrapix.url = "github:taheris/wrapix";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      perSystem =
        { system, ... }:
        let
          wrapix = inputs.wrapix.legacyPackages.${system}.lib;
        in
        {
          packages.default = wrapix.mkSandbox { };
        };
    };
}
```

### Flake with custom profile

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    wrapix.url = "github:taheris/wrapix";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      perSystem =
        { system, ... }:
        let
          wrapix = inputs.wrapix.legacyPackages.${system}.lib;

          # sandbox runs Linux; use Linux packages even on Darwin
          linuxSystem = if system == "aarch64-darwin" then "aarch64-linux" else system;
          linuxPkgs = import inputs.nixpkgs { system = linuxSystem; };
        in
        {
          packages.default = wrapix.mkSandbox {
            profile = wrapix.profiles.rust;
            deployKey = "myproject"; # for git push (see scripts/setup-deploy-key)

            packages = with linuxPkgs; [
              sqlx-cli
            ];

            env = {
              DATABASE_URL = "postgres://localhost/mydb";
            };

            mounts = [
              {
                source = "~/.cargo/config.toml";
                dest = "~/.cargo/config.toml";
                mode = "ro";
              }
            ];
          };
        };
    };
}
```

## Profiles

| Profile | Packages |
|---------|----------|
| `base` | git, ripgrep, fd, jq, vim |
| `rust` | base + rustup, gcc, openssl, pkg-config |
| `python` | base + python3, uv, ty, ruff |

## Notifications

Desktop notifications when Claude needs attention. See
[scripts/notify/README.md](scripts/notify/README.md) for installation details.

**Quick start** (run daemon manually):

```bash
nix run github:taheris/wrapix#wrapix-notifyd
```

**Home-manager**: See [scripts/notify/README.md](scripts/notify/README.md) for
launchd/systemd configuration.

## Linux Builder (macOS)

Build `aarch64-linux` packages on macOS with Nix via a remote builder:

```bash
wrapix-builder start   # start container
wrapix-builder setup   # configure routes/SSH (sudo)
nix build --system aarch64-linux .#mypackage
```

See `wrapix-builder config` for nix-darwin integration.
