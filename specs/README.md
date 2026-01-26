# Project Specifications

| Spec | Code | Purpose |
|------|------|---------|
| [architecture.md](./architecture.md) | — | Design principles and security model |
| [beads.md](./beads.md) | `.beads/` | Issue tracking with dependency support |
| [image-builder.md](./image-builder.md) | `lib/sandbox/image.nix` | Nix-based OCI image creation |
| [linux-builder.md](./linux-builder.md) | `lib/builder/default.nix` | Remote Nix builds for macOS |
| [notifications.md](./notifications.md) | `lib/notify/` | Desktop notifications with focus suppression |
| [profiles.md](./profiles.md) | `lib/sandbox/profiles.nix` | Pre-configured development environments |
| [ralph-tests.md](./ralph-tests.md) | `tests/ralph/` | Integration tests for ralph workflow |
| [ralph-workflow.md](./ralph-workflow.md) | `lib/ralph/` | Spec-driven AI orchestration |
| [sandbox.md](./sandbox.md) | `lib/sandbox/default.nix` | Platform-agnostic container isolation |

## Terminology Index

| Term | Definition |
|------|------------|
| **Beads** | Issue tracking system used by Ralph |
| **Deploy Key** | SSH key for git push operations from container |
| **Focus-aware** | Notification suppression when terminal is focused |
| **pasta** | Linux userspace networking for Podman containers |
| **Profile** | Pre-configured set of packages and environment variables |
| **Ralph** | Workflow orchestrator for spec-to-implementation |
| **Sandbox** | Isolated container environment for running Claude Code |
| **virtio-fs** | Shared filesystem for macOS container VMs |
