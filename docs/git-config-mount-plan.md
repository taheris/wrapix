# Fix git config mounts for Home Manager symlinks

## Problem

The `~/.config/git` mount doesn't work when the host uses Home Manager. The mounted directory contains symlinks to Nix store paths that don't exist inside the container:

```
~/.config/git/config → /nix/store/...-home-manager-files/.config/git/config
```

Git falls back to `.git/config` in the workspace, or fails to find user identity.

## Options

### Option 1: Resolve symlinks in wrapper script

Modify the sandbox launcher to resolve symlinks before mounting:

```bash
# Instead of mounting ~/.config/git directly
RESOLVED=$(readlink -f ~/.config/git/config)
# Mount the resolved path
```

**Pros:** Simple, no container changes
**Cons:** Wrapper script complexity, breaks if config has nested symlinks

### Option 2: Mount Nix store read-only

Add `/nix/store` as a read-only mount so symlinks resolve.

```nix
{ source = "/nix/store"; dest = "/nix/store"; mode = "ro"; }
```

**Pros:** All Nix symlinks work automatically
**Cons:** Exposes entire Nix store (large attack surface), large mount

### Option 3: Copy config at container start

Entrypoint script copies resolved git config:

```bash
if [[ -L ~/.config/git/config ]]; then
  cp "$(readlink -f ~/.config/git/config)" /tmp/git-config
  export GIT_CONFIG_GLOBAL=/tmp/git-config
fi
```

**Pros:** Clean isolation
**Cons:** Config changes on host not reflected, adds startup time

### Option 4: Environment variables

Pass git identity via environment instead of config files:

```nix
env = {
  GIT_AUTHOR_NAME = "$(git config user.name)";
  GIT_AUTHOR_EMAIL = "$(git config user.email)";
  GIT_COMMITTER_NAME = "$(git config user.name)";
  GIT_COMMITTER_EMAIL = "$(git config user.email)";
};
```

**Pros:** Simple, explicit, no file mounting needed
**Cons:** Only covers identity, not other git config (aliases, etc.)

### Option 5: Mount both locations with fallback

Mount `~/.gitconfig` (legacy) and `~/.config/git/` with the wrapper resolving symlinks for files that need it:

```nix
baseMounts = [
  { source = "~/.gitconfig"; dest = "~/.gitconfig"; mode = "ro"; optional = true; }
  { source = "~/.config/git/config:resolved"; dest = "~/.config/git/config"; mode = "ro"; optional = true; }
];
```

**Pros:** Supports all config locations
**Cons:** Requires wrapper logic for `:resolved` directive

## Recommendation

**Option 4 (environment variables)** for user identity - it's the most important use case and simplest to implement.

Combined with **Option 5** for users who need full git config (aliases, etc.) - implement a `:resolved` mount directive that follows symlinks.

## Implementation steps

1. Add git identity environment variables to profile (quick win)
2. Design `:resolved` mount directive syntax
3. Implement symlink resolution in Linux wrapper
4. Implement symlink resolution in macOS wrapper
5. Update documentation
