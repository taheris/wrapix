# Security Considerations

Security tradeoffs and mitigations in wrapix.

## Keys

### Deploy Keys

Deploy keys enable git push from sandboxed containers. They are generated without passphrases to support automated, non-interactive use by AI agents.

**Tradeoffs:**
- **Convenience**: No passphrase prompt enables autonomous git operations
- **Risk**: If `~/.ssh/deploy_keys` is compromised, keys are immediately usable

**Mitigations:**
- Directory permissions: 700 (owner-only access)
- Key permissions: 600 (private) / 644 (public)
- Keys are repository-scoped (limited blast radius)
- Deploy keys have write access only to the specific repository

**Alternative**: For higher-security environments, manually add passphrases to generated keys and use `ssh-agent` for caching.

### Builder SSH Keys

The Linux builder generates SSH keys in the Nix store for remote build authentication. These keys are also passphraseless for automated use.

**Why keys are in the Nix store:**
- Same derivation produces same store path, enabling reproducible builds
- `publicHostKey` must be available when nix-darwin evaluates `buildMachines`
- Client key must be readable by root for nix-daemon remote builds

**Tradeoffs:**
- Files in `/nix/store` are world-readable (typically 444/555 permissions)
- On multi-user systems, other local users could theoretically read the private keys

**Mitigations:**
- SSH port bound to localhost only (not network-accessible)
- Password authentication disabled
- Keys are machine-local (not transferred or shared)
- Keys only grant access to the local builder container

**Multi-user risk assessment:** The attack requires a local user to read the key from the Nix store and connect to the builder on localhost. Impact is limited to resource usage (CPU/memory), not data access. For single-user workstations (the typical use case), this is not a concern.

### Key Rotation

| Key Type | Frequency | Triggers |
|----------|-----------|----------|
| Deploy keys | 90 days | Personnel changes, suspected compromise |
| Builder SSH keys | 180 days | Machine rebuild, suspected compromise |

**Rotating deploy keys:**
```bash
setup-deploy-key -f  # Overwrites existing, updates GitHub
```

**Rotating builder SSH keys:**
```bash
wrapix-builder stop
# Edit lib/builder/hostkey.nix (change comment to invalidate derivation)
nix build
wrapix-builder start
sudo wrapix-builder setup
```

Builder keys are localhost-only, so rotation urgency is lower than deploy keys which have network access to GitHub.

## Mounts

### OAuth Token

The `CLAUDE_CODE_OAUTH_TOKEN` is passed to containers via environment variable for Claude Code authentication.

**Exposure vectors:**
- Other processes in the container can read `/proc/$pid/environ`
- Process listing tools may display environment variables
- Container introspection APIs can enumerate environment variables

**Mitigations:**
- Container runs as a single, non-root user (no other processes expected)
- Token is already present in the host environment (no new exposure surface)
- Container is isolated from host and other containers
- Token is session-scoped with limited validity

**Alternative**: A secrets file mount (`/run/secrets/oauth_token`) could prevent `/proc` exposure but adds complexity for marginal benefit.

## Nix

### Nixpkgs Channel

Wrapix uses the `nixos-unstable` channel rather than a stable release.

**Why unstable is appropriate:**
- **Ephemeral containers**: Wrapix runs development tasks, not persistent production services
- **Package availability**: Some packages (e.g., `ty`) are unavailable in stable releases
- **Tool currency**: Current linters and formatters are more valuable than backported fixes
- **Container isolation**: The primary security boundary, not package versions
- **Lock file**: `flake.lock` pins specific commits; updates are deliberate

| Package | unstable | nixos-25.05 |
|---------|----------|-------------|
| ty      | 0.0.13   | 0.0.1-alpha |
| ruff    | 0.14.x   | 0.11.x      |
| uv      | 0.9.x    | 0.7.x       |

**Alternative**: Fork the flake and pin to a stable channel, accepting older or missing tools.

### Sandbox Disabled

Nix's build sandbox is disabled inside containers (`lib/sandbox/image.nix:26-30`).

**Why:**
1. **Nested sandboxing not possible**: Nix's sandbox uses Linux namespaces. Inside a rootless container, these kernel features are restricted. Enabling it fails with permission errors.

2. **Outer container is the security boundary**: The wrapix container provides isolation (rootless execution, user namespace mapping, filesystem isolation). Nix sandbox would be redundant.

3. **Performance**: Sandbox adds overhead with no additional security benefit when the outer container already isolates.

**Blast radius of a malicious flake:**
- Cannot access host filesystem (only `/workspace` mounted)
- Cannot escalate privileges (rootless)
- Cannot persist beyond container lifetime (ephemeral)
- Same access as any other code in the sandbox, including Claude Code itself

**Recommendation**: Only run `nix build` on flakes you trust, just as you should only open projects you trust.
