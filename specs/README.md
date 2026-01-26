# Project Specifications

| Spec | Code | Purpose |
|------|------|---------|
| [architecture.md](./architecture.md) | — | Design principles and security model |
| [sandbox.md](./sandbox.md) | `lib/sandbox/default.nix` | Platform-agnostic container isolation |
| [profiles.md](./profiles.md) | `lib/sandbox/profiles.nix` | Pre-configured development environments |
| [image-builder.md](./image-builder.md) | `lib/sandbox/image.nix` | Nix-based OCI image creation |
| [notifications.md](./notifications.md) | `lib/notify/` | Desktop notifications with focus suppression |
| [linux-builder.md](./linux-builder.md) | `lib/builder/default.nix` | Remote Nix builds for macOS |
| [ralph-workflow.md](./ralph-workflow.md) | `lib/ralph/` | Spec-driven AI orchestration |
| [beads.md](./beads.md) | `.beads/` | Issue tracking with dependency support |

## Terminology Index

| Term | Definition |
|------|------------|
| **Sandbox** | Isolated container environment for running Claude Code |
| **Profile** | Pre-configured set of packages and environment variables |
| **Deploy Key** | SSH key for git push operations from container |
| **pasta** | Linux userspace networking for Podman containers |
| **virtio-fs** | Shared filesystem for macOS container VMs |
| **Ralph** | Workflow orchestrator for spec-to-implementation |
| **Beads** | Issue tracking system used by Ralph |
| **Focus-aware** | Notification suppression when terminal is focused |
