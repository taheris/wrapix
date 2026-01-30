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

## Issue Tracking (Beads)

**Use `bd` for ALL issue tracking.** Do NOT use markdown TODOs or external trackers.

### Syncing Beads

The `bd sync --full` command is legacy and has bugs ([beads#812](https://github.com/steveyegge/beads/issues/812)). Use manual git operations instead:

**Pull (session start):**
```bash
git -C .git/beads-worktrees/beads pull
bd sync --import
```

**Push (session end):**
```bash
bd sync
git -C .git/beads-worktrees/beads add -A
git -C .git/beads-worktrees/beads commit -m "bd sync: $(date '+%Y-%m-%d %H:%M:%S')"
git push origin beads
```

### Essential Commands

```bash
bd ready                             # Show unblocked work
bd show <id>                         # Issue details
bd create --title="..." --type=task  # Create issue
bd update <id> --status=in_progress  # Claim work
bd close <id>                        # Complete work
```

### Key Concepts

- **Priority:** P0=critical, P1=high, P2=medium, P3=low, P4=backlog
- **Types:** task, bug, feature, epic, question, docs
- **Dependencies:** `bd dep add <issue> <depends-on>`

## Session Protocol

**When ending a session or when the user says "land the plane":**

```bash
git add <files>         # Stage code changes
bd sync                 # Export beads to JSONL
git commit -m "..."     # Commit (prek hooks run: nixfmt, shellcheck, flake check, tests)
git push                # Push code to remote
# Push beads separately:
git -C .git/beads-worktrees/beads add -A
git -C .git/beads-worktrees/beads commit -m "bd sync: $(date '+%Y-%m-%d %H:%M:%S')"
git push origin beads
```

**Rules:**
- Pre-commit hooks run automatically: nixfmt, shellcheck, nix flake check, tests
- Work is NOT complete until both `git push` and `git push origin beads` succeed
- NEVER stop before pushing

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
