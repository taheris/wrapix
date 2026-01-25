# Linux Builder

Remote Nix builds for macOS via Linux container.

## Problem Statement

macOS users need to build `aarch64-linux` packages for:
- Container images that run Linux
- Cross-platform CI/CD pipelines
- Testing Linux-specific code

Apple Silicon Macs can run Linux VMs efficiently, but setting up a Nix remote builder is complex.

## Requirements

### Functional

1. **Container Lifecycle** - Start/stop Linux builder container
2. **Persistent Nix Store** - `/nix` survives container restarts
3. **SSH Access** - Remote builds via `ssh-ng://` protocol
4. **Route Configuration** - Network setup for nix-daemon access
5. **Key Management** - Automatic SSH key generation and trust
6. **nix-darwin Integration** - Config snippet for permanent setup

### Non-Functional

1. **Minimal Overhead** - Uses Apple container CLI (lightweight VM)
2. **Automatic Initialization** - First start copies initial Nix store
3. **Secure** - SSH keys stored in user data directory

## Architecture

```
macOS Host                         Linux Builder Container
----------                         -----------------------
nix-daemon                         sshd (:22)
    │                                  │
    └─ ssh-ng://builder@localhost:2222 ┘
                                       │
                                   nix-daemon
                                       │
                                   /nix (VirtioFS mount)
                                       │
~/.local/share/wrapix/builder-nix/ ◄───┘
```

## Commands

| Command | Description |
|---------|-------------|
| `wrapix-builder start` | Start builder container |
| `wrapix-builder stop` | Stop and remove container |
| `wrapix-builder status` | Show builder state |
| `wrapix-builder ssh [cmd]` | Connect or run remote command |
| `wrapix-builder setup` | Configure routes and SSH (sudo) |
| `wrapix-builder config` | Print nix-darwin config snippet |

## Storage Layout

```
~/.local/share/wrapix/
├── builder-nix/      # Persistent /nix store
└── builder-keys/     # SSH keys
    ├── host_ed25519
    └── client_ed25519
```

## Setup Process

1. `wrapix-builder start` - Creates container with VirtioFS mount
2. First start copies `/nix-image/*` to initialize store
3. `wrapix-builder setup` - Adds route and SSH known_hosts (sudo)
4. Add to `~/.config/nix/nix.conf`:
   ```
   builders = ssh-ng://builder@localhost:2222 aarch64-linux
   ```

## Affected Files

| File | Role |
|------|------|
| `lib/builder/default.nix` | CLI script and package |
| `lib/builder/hostkey.nix` | SSH key generation |
| `lib/sandbox/builder/image.nix` | Builder container image |
| `lib/sandbox/builder/entrypoint.sh` | Builder startup script |

## Success Criteria

- [ ] `nix build --system aarch64-linux` works on macOS
- [ ] Nix store persists across container restarts
- [ ] SSH connection is secure (key-based auth)
- [ ] nix-darwin config enables permanent setup
- [ ] Builder can be stopped and restarted cleanly

## Out of Scope

- x86_64-linux builds (would require emulation)
- Multi-user builder access
- Remote builders over network (localhost only)
