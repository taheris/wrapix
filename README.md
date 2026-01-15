# Wrapix

Cross-platform sandbox for Claude Code.

## Overview

A secure sandbox for running Claude Code on Linux and macOS. Container isolation provides filesystem and process protection while allowing full network access for web research and development.

- **Linux**: Podman rootless container with user namespace mapping
- **macOS**: Apple [container CLI](https://github.com/apple/container) (lightweight VM)

See [ARCHITECTURE.md](ARCHITECTURE.md) for design details and security model.

## Usage

```bash
# Base sandbox in current directory
nix run github:taheris/wrapix

# Rust profile
nix run github:taheris/wrapix#wrapix-rust ~/myproject
```

## Profiles

| Profile | Additional Packages | Cache Mounts |
|---------|---------------------|--------------|
| base | git, ripgrep, fd, jq, vim, etc. | - |
| rust | rustc, cargo, rust-analyzer | ~/.cargo/{registry,git} |

## Custom Profiles

```nix
{
  inputs.wrapix.url = "github:taheris/wrapix";

  outputs = { nixpkgs, wrapix, ... }:
    let
      wrLib = wrapix.lib.x86_64-linux;
    in {
      packages.x86_64-linux.my-sandbox = wrLib.mkSandbox (
        wrLib.deriveProfile wrLib.profiles.rust {
          name = "my-rust";
          packages = with nixpkgs.legacyPackages.x86_64-linux; [ sqlx-cli ];
          mounts = [
            { source = "~/.config/sqlx"; dest = "~/.config/sqlx"; mode = "ro"; optional = true; }
          ];
        }
      );
    };
}
```

## Requirements

- [Nix](https://nixos.org/) with flakes enabled
- [direnv](https://direnv.net/) (automatically provisions Podman, slirp4netns, and other dependencies)

### macOS

- macOS 26+ (Tahoe)
- Apple Silicon (M1/M2/M3/M4)
- Apple [container CLI](https://github.com/apple/container) (`container system start` to enable)

## Git Push from Sandbox

The sandbox uses repo-specific deploy keys for secure git push. This keeps your personal SSH keys outside the container.

### Setup

Run *one* of the following (on the host, not in sandbox).

```bash
./scripts/setup-deploy-key           # Uses repo-hostname format (e.g., myrepo-macbook)
./scripts/setup-deploy-key mykey     # Custom key name
```

This generates an ed25519 key scoped to this repo, adds it to GitHub with write access, and configures SSH to use it.

### Configure Sandbox

Pass `deployKey` to `mkSandbox` to mount the key:

```nix
{
  packages.x86_64-linux.my-sandbox = wrLib.mkSandbox {
    profile = wrLib.profiles.rust;
    deployKey = "myproject";  # Matches key name from setup
  };
}
```

**Why deploy keys?**
- Your personal `~/.ssh` keys stay on the host, never enter the container
- Each deploy key only works for one repository
- If compromised, revoke it without affecting other access

## Linux Builder (macOS)

Build `aarch64-linux` packages on macOS using a persistent Linux container as a Nix remote builder.

```bash
# Start the builder
nix run github:taheris/wrapix#wrapix-builder -- start

# Check status (shows store size)
nix run github:taheris/wrapix#wrapix-builder -- status

# Test a build
nix build --builders 'ssh-ng://builder@localhost:2222 aarch64-linux ~/.local/share/wrapix/builder-keys/builder_ed25519 4 1' \
  --max-jobs 0 nixpkgs#hello

# Connect to builder shell
nix run github:taheris/wrapix#wrapix-builder -- ssh

# Stop the builder
nix run github:taheris/wrapix#wrapix-builder -- stop
```

**Requirements:** macOS 26+ (Tahoe), Apple Silicon

### nix-darwin Configuration

Add `wrapix-builder` to your nix-darwin config for permanent installation and automatic Nix remote builder setup:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    darwin.url = "github:LnL7/nix-darwin";
    darwin.inputs.nixpkgs.follows = "nixpkgs";
    wrapix.url = "github:taheris/wrapix";
  };

  outputs = { nixpkgs, darwin, wrapix, ... }: {
    darwinConfigurations.myhost = darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        ({ pkgs, ... }: {
          # Install wrapix-builder CLI
          environment.systemPackages = [
            wrapix.packages.aarch64-darwin.wrapix-builder
          ];

          # SSH config for wrapix-builder (port 2222)
          environment.etc."ssh/ssh_config.d/100-wrapix-builder.conf".text = ''
            Host wrapix-builder
              Hostname localhost
              Port 2222
              User builder
              HostKeyAlias wrapix-builder
              IdentityFile /Users/${builtins.getEnv "USER"}/.local/share/wrapix/builder-keys/builder_ed25519
          '';

          # Add builder to Nix's remote builders
          nix.buildMachines = [{
            hostName = "wrapix-builder";
            systems = [ "aarch64-linux" ];
            protocol = "ssh-ng";
            maxJobs = 4;
            supportedFeatures = [ "big-parallel" "benchmark" ];
          }];

          nix.distributedBuilds = true;
        })
      ];
    };
  };
}
```

After applying the config, start the builder:

```bash
# Start builder (required before Linux builds)
wrapix-builder start

# Builds now automatically use the Linux builder
nix build nixpkgs#hello --system aarch64-linux
```

The Nix store persists across restarts in `~/.local/share/wrapix/builder-nix/`, so builds are cached.

### Manual Configuration

If not using nix-darwin, add to `~/.config/nix/nix.conf`:

```ini
builders = ssh-ng://builder@localhost:2222 aarch64-linux ~/.local/share/wrapix/builder-keys/builder_ed25519 4 1 big-parallel,benchmark
```

Or get the config snippet:

```bash
wrapix-builder config
```

See [ARCHITECTURE.md](ARCHITECTURE.md#linux-builder-macos) for design details.

## Host Notifications

Get native desktop notifications when Claude needs your attention.

### Start the Daemon

Run on the host (not in sandbox):

```bash
nix run github:taheris/wrapix#wrapix-notifyd
```

The daemon listens on `~/.local/share/wrapix/notify.sock` and triggers notifications via `terminal-notifier` (macOS) or `notify-send` (Linux).

### Configure Claude Code Hooks

Add to your `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "wrapix-notify 'Claude Code' 'Waiting for input' 'Ping'"
      }]
    }]
  }
}
```

**Available events:**
- `Stop` - Claude is waiting for user input (most useful)
- `PostToolUse` - After any tool completes
- `Notification` - Claude's built-in notifications

**Example: Notify on long-running commands:**

```json
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "wrapix-notify 'Claude Code' 'Command finished'"
      }]
    }]
  }
}
```

### Test from Container

```bash
wrapix-notify "Test" "Hello from container"
```

If the daemon isn't running, the command silently succeeds (no error).

## License

MIT
