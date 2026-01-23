# Architecture

This document describes the design and security model of Wrapix.

## Design Principles

1. **Container isolation is the security boundary** - Filesystem and process isolation protect the host
2. **Least privilege** - Containers run without elevated capabilities
3. **User namespace mapping** - Files created in `/workspace` have correct host ownership
4. **Open network** - Full internet access for web research, git, package managers

## Platform Implementations

### Linux: Podman Rootless Container

```
┌─ Podman Container ──────────────────────────────────────────┐
│                                                             │
│  Claude Code                                                │
│                                                             │
│  • --network=pasta (full network access)                    │
│  • --userns=keep-id (correct file ownership)                │
│  • No elevated capabilities                                 │
│  • /workspace mounted read-write                            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

Uses **pasta** networking for full TCP/UDP/ICMP connectivity without privileges.

### macOS: Apple Container CLI

macOS uses Apple's [container CLI](https://github.com/apple/container) which runs Linux containers as lightweight VMs via the Virtualization framework.

```
┌─ macOS Host ─────────────────────────────────────────────────┐
│                                                              │
│  ┌─ Linux VM (container CLI + Virtualization.framework) ──┐  │
│  │                                                        │  │
│  │  /entrypoint.sh:                                       │  │
│  │    1. Create user matching host UID                    │  │
│  │    2. Drop to user, exec Claude                        │  │
│  │                                                        │  │
│  │  /workspace ──► virtio-fs mount (project dir)          │  │
│  │                                                        │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  container CLI manages VM lifecycle, networking, storage     │
└──────────────────────────────────────────────────────────────┘
```

The container CLI provides:
- **VM Management** - Lightweight VMs via Virtualization.framework
- **Networking** - Automatic connectivity via vmnet
- **Storage** - OCI images and virtio-fs mounts

### Networking Comparison

| Aspect | Linux (pasta) | macOS (container) |
|--------|---------------|-------------------|
| Network mode | `--network=pasta` | vmnet bridge |
| Technology | passt/pasta userspace TCP/IP | macOS Virtualization.framework |
| Performance | Near-native | Near-native |

Both provide full TCP/UDP/ICMP connectivity without elevated privileges.

## Security Model

### Protected

| Boundary | How |
|----------|-----|
| Filesystem | Only `/workspace` is accessible from the host |
| Processes | Cannot see or interact with host processes |
| User namespace | Files created have correct host UID |
| Capabilities | Cannot perform privileged operations |

### Not Protected

- **Network traffic is unrestricted** - Claude has full internet access for research

This is intentional: the sandbox enables autonomous work with web research capabilities. The security boundary is the container itself, not network filtering.

## Components

### Host Notifications

Native desktop notifications when Claude needs attention.

**Transport**:
- **Linux**: Unix socket mounted from host (`/run/wrapix/notify.sock`)
- **macOS**: TCP to gateway IP (port 5959) - VirtioFS cannot pass Unix sockets

```
┌─ Container ──────────────────────────┐
│                                      │
│  Claude Code                         │
│    └─ Hook: Stop, PostToolUse        │
│         └─ wrapix-notify "msg"       │
│              │                       │
│              ├─ Darwin? → TCP:5959   │
│              └─ Linux → Unix socket  │
│                                      │
└──────────────┬───────────────────────┘
               │ TCP (Darwin) or mounted socket (Linux)
               ▼
┌─ Host ───────────────────────────────┐
│                                      │
│  wrapix-notifyd                      │
│    ├─ Linux: Unix socket only        │
│    └─ macOS: TCP:5959 + Unix socket  │
│    └─ Triggers native notifications  │
│         ├─ Linux: notify-send        │
│         └─ macOS: terminal-notifier  │
│                                      │
└──────────────────────────────────────┘
```

**Protocol**: Newline-delimited JSON

```json
{"title": "Claude Code", "message": "Task completed", "sound": "Ping", "session_id": "0:1.0"}
```

**Focus-Aware Suppression**: Notifications are suppressed when the terminal is focused.

- Launcher registers tmux session ID with window ID (niri) or app name (Darwin)
- Session files stored in `$XDG_RUNTIME_DIR/wrapix/sessions/` (Linux) or `$XDG_DATA_HOME/wrapix/sessions/` (Darwin)
- Daemon checks if session's window is focused before showing notification

| Variable | Description |
|----------|-------------|
| `WRAPIX_NOTIFY_ALWAYS=1` | Disable focus checking |
| `WRAPIX_NOTIFY_VERBOSE=1` | Debug logging |

### Linux Builder (macOS)

A Linux container for Nix remote builds via `ssh-ng://`. The Nix store persists via VirtioFS volume mount.

```
┌─ macOS Host ─────────────────────────────────────────────────────┐
│                                                                  │
│  nix-daemon ──► ssh-ng://builder@localhost:2222                  │
│                        │                                         │
│  ┌─ wrapix-builder ────┼─────────────────────────────────────┐   │
│  │                     ▼                                     │   │
│  │  sshd (:22)          nix-daemon                           │   │
│  │  /nix ◄── VirtioFS mount ◄── ~/.local/share/wrapix/       │   │
│  │                                  ├── builder-nix/         │   │
│  └──────────────────────────────────└── builder-keys/        │   │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

On first start, the entrypoint copies `/nix-image/*` to initialize the store.

| Component | Location |
|-----------|----------|
| CLI | `lib/builder/default.nix` |
| Image | `lib/sandbox/builder/image.nix` |
| Entrypoint | `lib/sandbox/builder/entrypoint.sh` |

## Source Layout

```
lib/
├── default.nix              # Top-level API: mkSandbox, deriveProfile, profiles
├── sandbox/
│   ├── default.nix          # Platform dispatcher, image builder
│   ├── profiles.nix         # Built-in profiles (base, rust)
│   ├── image.nix            # OCI image builder
│   ├── linux/               # Podman implementation
│   └── darwin/              # Apple container implementation
├── builder/
│   └── default.nix          # Linux builder CLI
└── notify/
    ├── daemon.nix           # Host notification daemon
    └── client.nix           # Container notification client
```
