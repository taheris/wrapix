# Profiles System

Pre-configured development environments with language-specific toolchains.

## Problem Statement

Different projects require different toolchains. Users need:
- Ready-to-use environments for common languages
- A consistent base of essential tools
- Ability to extend profiles with additional packages
- Proper environment variable configuration for each toolchain

## Requirements

### Functional

1. **Base Profile** - Core tools included in all environments
2. **Language Profiles** - Pre-configured Rust and Python environments
3. **Profile Extension** - `deriveProfile` API to extend existing profiles
4. **Package Bundling** - Profiles specify packages to include in container image
5. **Environment Configuration** - Profiles set required environment variables
6. **Mount Specifications** - Profiles can define default mounts (e.g., cargo cache)

### Non-Functional

1. **Minimal Base** - Base profile includes only essential tools
2. **Reproducible** - Same profile produces same environment via Nix

## Built-in Profiles

### Base Profile

Core tools for any development environment:

| Package | Purpose |
|---------|---------|
| git | Version control |
| ripgrep | Fast text search |
| fd | Fast file finder |
| jq | JSON processing |
| vim | Text editor |
| openssh | SSH client |
| nix | Package manager |

### Rust Profile

Extends base with Rust toolchain:

| Package | Purpose |
|---------|---------|
| rustup | Rust toolchain manager |
| gcc | C compiler for linking |
| openssl | TLS library |
| pkg-config | Library discovery |
| postgresql.lib | Database client libs |

Environment: `RUSTUP_HOME`, `CARGO_HOME`, `OPENSSL_DIR`

### Python Profile

Extends base with Python toolchain:

| Package | Purpose |
|---------|---------|
| python3 | Python interpreter |
| uv | Fast package installer |
| ruff | Linter and formatter |

## Affected Files

| File | Role |
|------|------|
| `lib/sandbox/profiles.nix` | Profile definitions |
| `lib/default.nix` | Exports `profiles` and `deriveProfile` |

## API

```nix
# Use built-in profile
mkSandbox { profile = profiles.rust; }

# Extend profile with additional packages
mkSandbox {
  profile = deriveProfile profiles.rust {
    packages = [ pkgs.sqlx-cli ];
    env = { DATABASE_URL = "postgres://localhost/db"; };
  };
}
```

## Success Criteria

- [ ] Base profile provides functional development environment
- [ ] Rust profile can compile and run Rust projects
- [ ] Python profile can run Python scripts with dependencies
- [ ] deriveProfile correctly merges packages and environment
- [ ] Profiles are composable (can extend extended profiles)

## Out of Scope

- Language-specific project scaffolding
- IDE configuration beyond Claude Code
- Version pinning for language toolchains
