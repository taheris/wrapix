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

### macOS Networking: gvproxy

macOS VMs use [gvproxy](https://github.com/containers/gvisor-tap-vsock) (gvisor-tap-vsock) for full TCP/UDP connectivity:

```
┌─ macOS Host ─────────────────────────────────────────────────────────────┐
│                                                                          │
│  ┌─ gvproxy ─────────────────────┐      ┌─ Linux VM ───────────────────┐ │
│  │                               │      │                              │ │
│  │  Userspace network stack      │      │  eth0 (192.168.127.2/24)     │ │
│  │  (gVisor netstack)            │      │         │                    │ │
│  │         │                     │      │         ▼                    │ │
│  │         ▼                     │      │  ┌─────────────────────┐     │ │
│  │  ┌─────────────────┐          │      │  │ VZFileHandle        │     │ │
│  │  │ vfkit socket    │◄─────────┼──────┼──│ NetworkDevice       │     │ │
│  │  │ (unixgram)      │ Ethernet │      │  │ Attachment          │     │ │
│  │  └────────┬────────┘  frames  │      │  └─────────────────────┘     │ │
│  │           │                   │      │                              │ │
│  └───────────┼───────────────────┘      └──────────────────────────────┘ │
│              │                                                           │
│              ▼                                                           │
│       ┌──────────────┐                                                   │
│       │ macOS Network│ ──────► Internet                                  │
│       └──────────────┘                                                   │
└──────────────────────────────────────────────────────────────────────────┘
```

**Why gvproxy instead of VZNATNetworkDeviceAttachment?**

Apple's `VZNATNetworkDeviceAttachment` has a critical limitation: it only routes ICMP traffic, not TCP or UDP. This means:
- `ping 1.1.1.1` works ✓
- `curl https://example.com` fails ✗
- DNS resolution fails ✗

This appears to be a bug or undocumented limitation in the Virtualization framework. The alternative (`vmnet`) requires an Apple Developer Program certificate to sign the binary with the `com.apple.vm.networking` entitlement.

**gvproxy solution:**

gvproxy provides a userspace network stack (from gVisor) that:
1. Runs as a host-side daemon
2. Creates a Unix datagram socket using the "vfkit" protocol
3. Receives raw Ethernet frames from the VM via `VZFileHandleNetworkDeviceAttachment`
4. Handles TCP/UDP/ICMP using gVisor's netstack
5. Proxies traffic through the host's network stack

This gives full internet connectivity without requiring code signing certificates.

### Networking Comparison: macOS vs Linux

| Aspect | Linux (pasta) | macOS (gvproxy) |
|--------|--------------|-----------------|
| Network mode | `--network=pasta` (Podman) | gvproxy + VZFileHandle |
| Technology | passt/pasta userspace TCP/IP | gVisor netstack |
| Connection | User namespace networking | Unix datagram socket |
| Protocol | Direct network namespace | vfkit Ethernet frames |
| Performance | Near-native | Good (userspace overhead) |

Both solutions provide full TCP/UDP/ICMP connectivity without elevated privileges. They achieve this using different userspace networking stacks appropriate to their platform's container/VM technology.

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
