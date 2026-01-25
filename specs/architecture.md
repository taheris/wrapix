# Architecture

Wrapix is a secure sandbox for running [Claude Code](https://claude.ai/code) in isolated containers. It provides container isolation on Linux (Podman) and macOS (Apple container CLI), with tooling for notifications, remote builds, and AI-driven workflows.

## Design Principles

1. **Container isolation is the security boundary** - Filesystem and process isolation protect the host
2. **Least privilege** - Containers run without elevated capabilities
3. **User namespace mapping** - Files created in `/workspace` have correct host ownership
4. **Open network** - Full internet access for web research, git, package managers

## Platform Support

| Platform | Container Technology | Networking |
|----------|---------------------|------------|
| Linux | Podman rootless | pasta (userspace TCP/IP) |
| macOS | Apple container CLI + Virtualization.framework | vmnet bridge |

Both platforms provide full network connectivity without elevated privileges. The `/workspace` directory is mounted read-write with correct file ownership.

## Source Layout

```
lib/
├── default.nix          # Top-level API: mkSandbox, deriveProfile, profiles
├── sandbox/             # Container isolation (see sandbox.md)
│   ├── default.nix      # Platform dispatcher
│   ├── profiles.nix     # Built-in profiles (see profiles.md)
│   ├── image.nix        # OCI image builder (see image-builder.md)
│   ├── linux/           # Podman implementation
│   └── darwin/          # Apple container implementation
├── builder/             # Linux builder for macOS (see linux-builder.md)
├── notify/              # Desktop notifications (see notifications.md)
├── ralph/               # AI workflow orchestration (see ralph-workflow.md)
└── util/                # Shared utilities
```

## Security Model

**Protected**: Filesystem (only `/workspace` accessible), processes (isolated), user namespace (correct UID), capabilities (none elevated)

**Not protected**: Network traffic is unrestricted by design for autonomous work with web research.

## Component Overview

| Component | Purpose | Entry Point |
|-----------|---------|-------------|
| Sandbox | Container creation and lifecycle | `mkSandbox` |
| Profiles | Pre-configured dev environments | `profiles.{base,rust,python}` |
| Image Builder | OCI image generation via Nix | `lib/sandbox/image.nix` |
| Notifications | Desktop alerts when Claude waits | `wrapix-notify`, `wrapix-notifyd` |
| Linux Builder | Remote Nix builds on macOS | `wrapix-builder` |
| Ralph | Spec-driven AI workflow | `ralph {start,plan,ready,step,loop}` |

See individual spec files for detailed requirements and implementation notes.
