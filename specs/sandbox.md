# Core Sandbox

Secure container isolation for running Claude Code with filesystem and process protection.

## Problem Statement

Running AI coding assistants with unrestricted host access creates security risks. Users need isolation that:
- Protects host filesystem and processes from container actions
- Maintains correct file ownership for workspace files
- Provides full network access for research and package management
- Works consistently across Linux and macOS

## Requirements

### Functional

1. **Container Creation** - `mkSandbox` function creates runnable sandbox derivations
2. **Platform Dispatch** - Automatically selects Podman (Linux) or Apple container CLI (macOS)
3. **Workspace Mounting** - Current directory mounted at `/workspace` with read-write access
4. **User Namespace Mapping** - Files created in container have correct host UID/GID
5. **Custom Mounts** - Support additional read-only or read-write mounts
6. **Environment Variables** - Pass custom environment variables to container
7. **Deploy Keys** - SSH key injection for git push operations

### Non-Functional

1. **No Elevated Privileges** - Containers run without root or elevated capabilities
2. **Full Network Access** - Unrestricted TCP/UDP for web research (ICMP unavailable without `cap_net_raw`)
3. **Near-Native Performance** - Minimal overhead from containerization

## Platform Implementations

### Linux (Podman)

- Uses `--network=pasta` for userspace networking (open outbound, no inbound ports)
- Uses `--userns=keep-id` for UID mapping
- Mounts workspace via bind mount

### macOS (Apple Container CLI)

- Requires macOS 26+ and Apple Silicon
- Uses Virtualization.framework for lightweight VMs
- Uses vmnet for networking (open outbound, no inbound ports)
- Uses virtio-fs for workspace mounting
- Entrypoint creates user matching host UID

## Affected Files

| File | Role |
|------|------|
| `lib/sandbox/default.nix` | Platform dispatcher and mkSandbox API |
| `lib/sandbox/linux/default.nix` | Podman launcher script |
| `lib/sandbox/darwin/default.nix` | Apple container launcher script |
| `lib/sandbox/linux/entrypoint.sh` | Linux container startup |
| `lib/sandbox/darwin/entrypoint.sh` | macOS container startup |

## API

```nix
mkSandbox {
  profile = profiles.base;      # Development profile
  deployKey = "myproject";      # SSH key name for git push
  packages = [ pkgs.jq ];       # Additional packages
  env = { FOO = "bar"; };       # Environment variables
  mounts = [{                   # Additional mounts
    source = "~/.config";
    dest = "~/.config";
    mode = "ro";
  }];
}
```

## Success Criteria

- [ ] Container starts on both Linux and macOS
  [verify:wrapix](../tests/darwin/uid-test.sh)
- [ ] Files created in /workspace have correct host ownership
  [verify:wrapix](../tests/darwin/uid-test.sh)
- [ ] Claude Code can access internet for research
  [verify:wrapix](../tests/darwin/network-test.sh)
- [ ] Host filesystem outside /workspace is inaccessible
  [verify:wrapix](../tests/darwin/mount-test.sh)
- [ ] Custom mounts and environment variables work
  [verify:wrapix](../tests/darwin/mount-test.sh)

## Out of Scope

- Network filtering or firewall rules
- GPU passthrough
- Windows support
