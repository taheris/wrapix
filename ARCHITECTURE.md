# Architecture

## Design Principles

1. **Defense in depth**: Multiple layers (container/VM isolation + network filtering)
2. **Kernel-enforced network control**: iptables rules cannot be bypassed by userspace code
3. **Least privilege**: Claude container has zero capabilities
4. **Blocklist over allowlist**: Block known-bad sites, allow everything else (developers need web access)
5. **Platform parity**: Same security model on both platforms, same OCI images

## Linux: 3-Container Pod

```
┌─ Podman Pod (shared network namespace) ─────────────────────────┐
│                                                                 │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────────┐        │
│  │    Init     │   │    Squid    │   │     Claude      │        │
│  │  container  │   │   sidecar   │   │    container    │        │
│  │             │   │             │   │                 │        │
│  │ • NET_ADMIN │   │ • no caps   │   │ • no caps       │        │
│  │ • iptables  │   │ • port 3128 │   │ • --userns=keep │        │
│  │ • exits     │   │ • blocklist │   │ • interactive   │        │
│  └─────────────┘   └─────────────┘   └─────────────────┘        │
│         │                 ▲                   │                 │
│         │    iptables     │    all traffic    │                 │
│         └────redirects────┴───────────────────┘                 │
│                                                                 │
│  Network: slirp4netns (isolated from host)                      │
└─────────────────────────────────────────────────────────────────┘
```

**Why 3 containers?** Security separation. The Claude container never has capabilities - even if compromised, it cannot modify iptables rules.

## macOS: Single VM

```
┌─ macOS Host ─────────────────────────────────────────────────┐
│                                                              │
│  ┌─ Linux VM (Virtualization.framework) ──────────────────┐  │
│  │                                                        │  │
│  │  /entrypoint.sh (runs as root, then drops privs):      │  │
│  │    1. iptables rules (transparent proxy)               │  │
│  │    2. Start Squid (blocklist filtering)                │  │
│  │    3. Create user matching host UID                    │  │
│  │    4. Drop to user, exec Claude                        │  │
│  │                                                        │  │
│  │  /workspace ──► virtio-fs mount (project dir)          │  │
│  │  ~/.cargo/registry ──► virtio-fs mount (ro, cache)     │  │
│  │                                                        │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  Swift CLI orchestrates VM via Apple Containerization        │
└──────────────────────────────────────────────────────────────┘
```

**Why single entrypoint?** VMs provide strong isolation already. No need for container separation inside VM - simpler architecture.

## Network Security

### Threat Model

Claude can execute arbitrary code and read the web. It may attempt to:
- Unset proxy environment variables
- Make direct socket connections
- Exfiltrate data to paste sites, webhooks, file sharing
- Use DNS for data exfiltration
- Tunnel over ICMP or alternative protocols

### How Filtering Works

```
Claude makes request → iptables intercepts → Squid checks blocklist
                              ↓                        ↓
                    (kernel-enforced,           Block: 403
                     cannot bypass)             Allow: tunnel through
```

1. iptables redirects ports 80/443 to Squid (port 3128)
2. iptables drops all other outbound traffic
3. DNS allowed only to container's resolver
4. Squid checks domain against blocklist
5. HTTPS: Squid sees hostname via CONNECT/SNI (not URL paths - TLS is opaque)

### What Gets Blocked

| Category | Examples | Reason |
|----------|----------|--------|
| Paste sites | pastebin.com, hastebin.com | Data exfiltration |
| File sharing | transfer.sh, file.io | Malware/exfil |
| URL shorteners | bit.ly, tinyurl.com | Redirect attacks |
| Webhook catchers | webhook.site, requestbin.com | Data exfiltration |
| Risky TLDs | .tk, .ml, .ga, .cf | High abuse rates |
| Raw IPs | http://1.2.3.4/ | Bypass DNS filtering |
| WebSockets | Upgrade: websocket | Tunnel bypass |

### What Gets Allowed

Everything else: search engines, documentation, package registries, GitHub, Stack Overflow, etc.

### Why This Cannot Be Bypassed

| Attack | Protection |
|--------|------------|
| `unset http_proxy` | iptables redirect is kernel-enforced |
| Direct socket | Redirected to Squid |
| `curl --noproxy '*'` | iptables ignores curl flags |
| DNS tunneling | Only container's resolver allowed |
| ICMP tunneling | All non-HTTP dropped |
| Alternative ports | Only 80/443, rest dropped |

### Audit Logging

Squid logs all requests in JSON format:
```json
{"timestamp":"...","method":"CONNECT","url":"github.com:443","status":200,"action":"TCP_TUNNEL"}
{"timestamp":"...","method":"CONNECT","url":"pastebin.com:443","status":403,"action":"DENIED"}
```
