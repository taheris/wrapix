# Wrapix

Cross-platform sandbox for Claude Code.

## Overview

A secure sandbox for running Claude Code on Linux and macOS. Container isolation provides filesystem and process protection while allowing full network access for web research and development.

- **Linux**: Podman rootless container with user namespace mapping
- **macOS**: Apple Containerization framework (lightweight VM)

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
| base | git, ripgrep, fd, jq, vim, jujutsu, etc. | - |
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
- Xcode 26 CLI tools

## Git Push from Sandbox

The sandbox uses repo-specific deploy keys for secure git push. This keeps your personal SSH keys outside the container.

```bash
# Run once per repo (from host, not sandbox)
./scripts/setup-deploy-key owner/repo
```

This generates an ed25519 key scoped to that single repository, adds it to GitHub with write access, and configures SSH to use it.

**Why deploy keys?**
- Your personal `~/.ssh` keys stay on the host, never enter the container
- Each deploy key only works for one repository
- If compromised, revoke it without affecting other access

## License

MIT
