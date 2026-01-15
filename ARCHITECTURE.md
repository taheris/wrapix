# Architecture

## Design Principles

1. **Container isolation is the security boundary**: Filesystem and process isolation protect the host
2. **Least privilege**: Claude container runs without elevated capabilities
3. **User namespace mapping**: Files created in /workspace have correct host ownership
4. **Open network**: Full internet access for web research, git, package managers

## Linux: Single Container

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

## macOS: Single VM

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

### Container CLI Features

The `container` CLI provides:
- **VM Management**: Creates and manages lightweight VMs via Virtualization.framework
- **Networking**: Handles network connectivity automatically via vmnet
- **Storage**: Manages OCI images and virtio-fs mounts
- **Visibility**: Running containers appear in `container list`

### Networking Comparison: macOS vs Linux

| Aspect | Linux (pasta) | macOS (container) |
|--------|--------------|-------------------|
| Network mode | `--network=pasta` (Podman) | vmnet (container CLI) |
| Technology | passt/pasta userspace TCP/IP | macOS networking |
| Connection | User namespace networking | Default bridge network |
| Performance | Near-native | Near-native |

Both solutions provide full TCP/UDP/ICMP connectivity without elevated privileges.

## Security Model

### What Container Isolation Provides

| Protection | How |
|------------|-----|
| Filesystem isolation | Only /workspace is accessible |
| Process isolation | Cannot see or interact with host processes |
| User namespace | Files created have correct host UID |
| No capabilities | Cannot perform privileged operations |

### What Is NOT Protected

- Network traffic is unrestricted
- Claude has full internet access for research

This is intentional: the sandbox is meant to allow autonomous work with web research capabilities. The security boundary is the container itself, not network filtering.

## Host Notifications

Claude Code can trigger native desktop notifications on the host machine from inside the container via a Unix socket.

```
┌─ Container ──────────────────────────┐
│                                      │
│  Claude Code                         │
│    └─ Hook: Stop, PostToolUse, etc.  │
│         └─ wrapix-notify "msg"       │
│              └─ writes to socket     │
│                                      │
└──────────────┬───────────────────────┘
               │ mounted socket
               ▼
┌─ Host ───────────────────────────────┐
│                                      │
│  wrapix-notifyd                      │
│    └─ Listens on Unix socket         │
│    └─ Triggers native notifications  │
│         ├─ Linux: notify-send        │
│         └─ macOS: terminal-notifier  │
│                                      │
└──────────────────────────────────────┘
```

### Components

| Component | Location | Description |
|-----------|----------|-------------|
| `wrapix-notifyd` | Host | Daemon listening on `~/.local/share/wrapix/notify.sock` |
| `wrapix-notify` | Container | Client that sends JSON to the socket |

### Protocol

The client sends newline-delimited JSON to the socket:

```json
{"title": "Claude Code", "message": "Task completed", "sound": "Ping"}
```

- `title`: Notification title (default: "Claude Code")
- `message`: Notification body
- `sound`: macOS sound name (optional, ignored on Linux)

## Linux Builder (macOS)

The `wrapix-builder` provides a persistent Linux build environment for Nix remote builds on macOS. It runs as a separate container from the ephemeral Claude Code sessions.

```
┌─ macOS Host ─────────────────────────────────────────────────────┐
│                                                                  │
│  nix-daemon                                                      │
│    └─ ssh-ng://builder@localhost:2222                            │
│                        │                                         │
│                        │ SSH (port 2222)                         │
│                        ▼                                         │
│  ┌─ wrapix-builder Container (persistent) ────────────────────┐  │
│  │                                                            │  │
│  │  sshd (:22)          nix-daemon                            │  │
│  │    └─ builder user     └─ handles build requests           │  │
│  │                                                            │  │
│  │  /nix ◄── VirtioFS mount (persistent store)                │  │
│  │                                                            │  │
│  └────────────────────────────────────────────────────────────┘  │
│                        ▲                                         │
│                        │ VirtioFS                                │
│  Persistent Storage:   │                                         │
│    ~/.local/share/wrapix/                                        │
│      ├── builder-nix/  ◄┘  (Nix store)                           │
│      └── builder-keys/     (SSH keys)                            │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Key Differences from Claude Code Containers

| Aspect | Claude Code Container | Builder Container |
|--------|----------------------|-------------------|
| Lifecycle | Ephemeral (`--rm`) | Persistent |
| Naming | `wrapix-$$` (PID-based) | `wrapix-builder` (static) |
| Purpose | Interactive AI coding | Nix remote builds |
| Store | Ephemeral | Persistent via VirtioFS |
| Services | Claude Code | sshd + nix-daemon |
| Network | vmnet (outbound) | vmnet + port 2222 (inbound SSH) |

### Architecture Decisions

1. **Separate from mkSandbox**: The builder has its own image, entrypoint, and launcher—no modifications to the existing sandbox code
2. **SSH-based protocol**: Uses `ssh-ng://` for compatibility with existing Nix remote builder configuration
3. **Persistent store**: VirtioFS mounts `~/.local/share/wrapix/builder-nix/` as `/nix` for store persistence across restarts
4. **Port binding**: SSH exposed on localhost:2222 (no dynamic IP management needed)

### Components

| Component | Location | Description |
|-----------|----------|-------------|
| `wrapix-builder` | `lib/builder/default.nix` | CLI for start/stop/status/ssh/config |
| Builder image | `lib/sandbox/builder/image.nix` | OCI image with sshd + nix |
| Entrypoint | `lib/sandbox/builder/entrypoint.sh` | Starts sshd + nix-daemon |
