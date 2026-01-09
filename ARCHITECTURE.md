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
