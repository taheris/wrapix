# Wrapix

Cross-platform sandbox for Claude Code.

## Overview

A secure sandbox for running Claude Code on Linux and macOS. Network access is filtered through an iptables-enforced transparent proxy that blocks known exfiltration vectors while allowing legitimate development work.

- **Linux**: Podman rootless containers (3-container pod pattern)
- **macOS**: Apple Containerization framework (lightweight VMs)

See [ARCHITECTURE.md](ARCHITECTURE.md) for design details and security model.

## Usage

```bash
# Base sandbox in current directory
nix run github:taheris/wrapix

# Language-specific profile
nix run github:taheris/wrapix#wrapix-rust ~/myproject
nix run github:taheris/wrapix#wrapix-go ~/myproject
nix run github:taheris/wrapix#wrapix-python ~/myproject
nix run github:taheris/wrapix#wrapix-js ~/myproject
```

## Profiles

| Profile | Packages | Cache Mounts |
|---------|----------|--------------|
| base | git, ripgrep, fd, jq, vim | - |
| rust | rustc, cargo, rust-analyzer | ~/.cargo/{registry,git} |
| go | go, gopls | ~/go/pkg/mod |
| python | python, pip, poetry | ~/.cache/{pip,pypoetry,uv} |
| js | node, npm, yarn, bun | ~/.npm, ~/.yarn, ~/.bun |
| nix | nix, alejandra | - |
| devops | docker-cli, kubectl, terraform | ~/.kube, ~/.aws |

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

### Linux

- Podman (rootless)
- slirp4netns
- User namespaces enabled
- subuid/subgid configured:
  ```
  # /etc/subuid and /etc/subgid
  myuser:100000:65536
  ```

### macOS

- macOS 26+ (Tahoe)
- Apple Silicon (M1/M2/M3/M4)
- Xcode 26 CLI tools

## License

MIT
