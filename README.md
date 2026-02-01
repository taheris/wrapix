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
          sandbox = wrapix.mkSandbox { };
        in
        {
          packages.default = sandbox.package;
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

          sandbox = wrapix.mkSandbox {
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
        in
        {
          packages.default = sandbox.package;
        };
    };
}
```

### Composing sandbox with ralph

`mkSandbox` returns `{ package, profile }`, allowing you to share the effective profile with `mkRalph`:

```nix
let
  wrapix = inputs.wrapix.legacyPackages.${system}.lib;

  # Create sandbox with customizations
  sandbox = wrapix.mkSandbox {
    profile = wrapix.profiles.rust;
    packages = [ linuxPkgs.sqlx-cli ];
  };

  # Ralph uses the same sandbox (shares profile)
  ralph = wrapix.mkRalph { inherit sandbox; };
in
{
  packages.default = sandbox.package;

  apps.ralph = ralph.app;

  devShells.default = pkgs.mkShell {
    packages = ralph.packages;
    shellHook = ralph.shellHook;
  };
}
```

Alternatively, pass a profile directly to `mkRalph` (creates its own sandbox):

```nix
ralph = wrapix.mkRalph { profile = wrapix.profiles.rust; };
```

## Profiles

| Profile | Packages |
|---------|----------|
| `base` | git, ripgrep, fd, jq, vim |
| `rust` | base + rustup, gcc, openssl, pkg-config |
| `python` | base + python3, uv, ty, ruff |

## MCP Servers

MCP (Model Context Protocol) servers can be enabled per-sandbox via the `mcp` parameter. This avoids profile proliferation by adding capabilities to existing profiles.

### tmux-debug

Provides tmux pane management for AI-assisted debugging. Run servers in one pane, send test requests from another, capture logs.

```bash
nix run github:taheris/wrapix#wrapix-debug       # base + tmux-debug
nix run github:taheris/wrapix#wrapix-rust-debug  # rust + tmux-debug
```

### Flake usage

```nix
sandbox = wrapix.mkSandbox {
  profile = wrapix.profiles.rust;
  mcp = {
    tmux-debug = { };  # enable with defaults
  };
};

# With audit logging
sandbox = wrapix.mkSandbox {
  profile = wrapix.profiles.rust;
  mcp = {
    tmux-debug = {
      audit = "/workspace/.debug-audit.log";
      auditFull = "/workspace/.debug-audit/";  # full capture logs
    };
  };
};
```

See [specs/tmux-mcp.md](specs/tmux-mcp.md) for the full specification.

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
