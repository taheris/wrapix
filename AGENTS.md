# Agent Instructions

## Specifications

Before implementing features, consult `specs/README.md`. Key points:

- **Architecture first** — Read `specs/architecture.md` for system overview
- **Check specs before coding** — Each feature has a dedicated spec file
- **Specs describe intent** — Code describes reality; verify against both
- **Terminology** — `specs/README.md` has a terminology index

## Commands

### Building with Nix

- **Enter devShell:** `nix develop`
- **Build sandbox:** `nix build`
- **Build with Rust:** `nix build .#wrapix-rust`
- **Build with Python:** `nix build .#wrapix-python`
- **Run directly:** `nix run github:taheris/wrapix`

### Formatting

- **Format Nix:** `nix fmt`
- **Check format:** `nix flake check`

## Issue Tracking (Beads)

**Use `bd` for ALL issue tracking.** Do NOT use markdown TODOs or external trackers.

### Essential Commands

```bash
bd ready                             # Show unblocked work
bd show <id>                         # Issue details
bd create --title="..." --type=task  # Create issue
bd update <id> --status=in_progress  # Claim work
bd close <id>                        # Complete work
bd sync                              # Sync with remote
```

### Workflow

1. `bd sync` — Pull latest issues
2. `bd ready` — Find actionable work
3. `bd update <id> --status=in_progress` — Claim it
4. Implement the task
5. `bd close <id>` — Mark complete
6. `bd sync` — Push changes

### Key Concepts

- **Priority:** P0=critical, P1=high, P2=medium, P3=low, P4=backlog
- **Types:** task, bug, feature, epic, question, docs
- **Dependencies:** `bd dep add <issue> <depends-on>`

## Session Protocol

**When ending a session or when the user says "land the plane", complete ALL steps:**

```bash
git status              # Check changes
git add <files>         # Stage code
git commit -m "..."     # Commit
bd sync                 # Sync beads
git push                # Push to remote
git status              # Verify "up to date"
```

**Rules:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing
- If push fails, resolve and retry

## Code Style

### Nix

- Use `nixfmt` for formatting (run `nix fmt`)
- Use `inherit` to bring names into scope: `inherit (lib) mkOption;`
- Keep expressions pure; side effects only in builders

### Shell Scripts

- Use `shellcheck` to lint scripts
- Use `set -euo pipefail` at the top
- Quote variables: `"$VAR"` not `$VAR`
- Use `${VAR:-default}` for optional variables
- Prefer `[[` over `[` for conditionals

### Documentation

- Specs go in `specs/` — one per feature
- Update `specs/README.md` when adding specs
- Keep architecture.md as a high-level overview
