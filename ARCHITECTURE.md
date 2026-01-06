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

```
┌─ macOS Host ─────────────────────────────────────────────────┐
│                                                              │
│  ┌─ Linux VM (Virtualization.framework) ──────────────────┐  │
│  │                                                        │  │
│  │  /entrypoint.sh:                                       │  │
│  │    1. Create user matching host UID                    │  │
│  │    2. Drop to user, exec Claude                        │  │
│  │                                                        │  │
│  │  /workspace ──► virtio-fs mount (project dir)          │  │
│  │                                                        │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  Swift CLI orchestrates VM via Apple Containerization        │
└──────────────────────────────────────────────────────────────┘
```

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
