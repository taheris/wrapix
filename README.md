# Wrapix

Secure sandbox for running [Claude Code](https://claude.ai/code) in isolated containers.

- **Linux**: Podman rootless container
- **macOS**: Apple [container CLI](https://github.com/apple/container) (macOS 26+, Apple Silicon)

## Documentation

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design and security model.

## Basic usage

```bash
nix run github:taheris/wrapix                # base sandbox
nix run github:taheris/wrapix#wrapix-rust    # with Rust toolchain
nix run github:taheris/wrapix#wrapix-python  # with Python toolchain
```

## Sandbox usage

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
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      perSystem =
        { system, ... }:
        let
          wrapix = inputs.wrapix.legacyPackages.${system}.lib;

          # sandbox runs Linux; use Linux packages even on Darwin
          linuxSystem = if system == "aarch64-darwin" then "aarch64-linux" else system;
          linuxPkgs = import inputs.nixpkgs { system = linuxSystem; };

        in
        {
          # simple example using the base profile (start with `nix run`)
          packages.default = wrapix.mkSandbox { };

          # complete example with additional configuration
          packages.sandbox = wrapix.mkSandbox {
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

Desktop notifications when Claude needs attention:

```bash
# host
nix run github:taheris/wrapix#wrapix-notifyd

# ~/.claude/settings.json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "wrapix-notify 'Claude' 'Waiting'"
          }
        ]
      }
    ]
  }
}
```

## Linux Builder (macOS)

Build `aarch64-linux` packages on macOS with Nix via a remote builder:

```bash
wrapix-builder start   # start container
wrapix-builder setup   # configure routes/SSH (sudo)
nix build --system aarch64-linux .#mypackage
```

See `wrapix-builder config` for nix-darwin integration.
