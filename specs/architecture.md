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
│   ├── default.nix      # Platform dispatcher, MCP integration
│   ├── profiles.nix     # Built-in profiles (see profiles.md)
│   ├── image.nix        # OCI image builder (see image-builder.md)
│   ├── linux/           # Podman implementation
│   └── darwin/          # Apple container implementation
├── mcp/                 # MCP server registry (see tmux-mcp.md)
│   ├── default.nix      # Server registry: { tmux-debug = ...; }
│   └── tmux/            # tmux-debug MCP server
│       ├── default.nix  # Server definition: { name, package, mkServerConfig }
│       └── mcp-server.nix
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
| MCP Servers | Optional capabilities via `mcp` parameter | `mcp.tmux-debug` |
| Image Builder | OCI image generation via Nix | `lib/sandbox/image.nix` |
| Notifications | Desktop alerts when Claude waits | `wrapix-notify`, `wrapix-notifyd` |
| Linux Builder | Remote Nix builds on macOS | `wrapix-builder` |
| Ralph | Spec-driven AI workflow | `ralph {start,plan,ready,step,loop}` |

## MCP Integration

MCP (Model Context Protocol) servers extend sandbox capabilities without profile proliferation. The `mcp` parameter in `mkSandbox` accepts a set of server names to options:

```nix
# Enable with defaults
mkSandbox {
  profile = profiles.rust;
  mcp.tmux-debug = { };
}

# Enable with audit logging
mkSandbox {
  profile = profiles.rust;
  mcp.tmux-debug.audit = "/workspace/audit.log";
}
```

The registry at `lib/mcp/default.nix` maps server names to definitions. Each definition provides:
- `name`: Server identifier
- `package`: Nix package for the MCP binary
- `mkServerConfig`: Function generating Claude settings from user options

See [tmux-mcp.md](./tmux-mcp.md) for the tmux-debug server specification.

See individual spec files for detailed requirements and implementation notes. Security tradeoffs and mitigations are documented in [security-review.md](./security-review.md).
