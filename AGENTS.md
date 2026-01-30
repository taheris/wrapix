# Agent Instructions

## Specifications

Before implementing features, consult `specs/README.md`:

- **Architecture first** — Read `specs/architecture.md` for system overview
- **Check specs before coding** — Each feature has a dedicated spec file
- **Terminology** — `specs/README.md` has a terminology index

## Building

```bash
nix develop          # Enter devShell
nix build            # Build sandbox
nix build .#wrapix-rust    # With Rust profile
nix build .#wrapix-python  # With Python profile
```

## Issue Tracking (Beads)

**Use `bd` for ALL issue tracking.** Do NOT use markdown TODOs or external trackers.

### Finding Work

```bash
bd ready                        # Show unblocked issues ready to work
bd list --status=open           # All open issues
bd list --status=in_progress    # Currently active work
bd show <id>                    # Issue details with dependencies
```

### Creating Issues

```bash
bd create --title="..." --type=task --priority=2
bd create --title="..." --type=bug --priority=1
bd create --title="..." --type=feature
```

- **Priority:** 0=critical, 1=high, 2=medium (default), 3=low, 4=backlog
- **Types:** task, bug, feature, epic, question, docs

### Updating Issues

```bash
bd update <id> --status=in_progress   # Claim work (do this before starting)
bd update <id> --status=open          # Release work
bd update <id> --title="new title"    # Update title
bd update <id> --description="..."    # Update description
bd close <id>                         # Mark complete
bd close <id> --reason="explanation"  # Close with reason
```

### Dependencies

```bash
bd dep add <issue> <depends-on>   # issue depends on depends-on
bd blocked                        # Show all blocked issues
```

### Workflow

1. `bd ready` — Find available work
2. `bd update <id> --status=in_progress` — Claim it before starting
3. Implement the task
4. `bd close <id>` — Mark complete when done

## Session Protocol

### Start

```bash
git -C .git/beads-worktrees/beads pull
bd sync --import
```

Note: `bd sync --full` is buggy ([beads#812](https://github.com/steveyegge/beads/issues/812)).

### End ("land the plane")

```bash
git add <files>
bd sync
git commit -m "..."   # Hooks run: nixfmt, shellcheck, flake check, tests
git push
git -C .git/beads-worktrees/beads add -A && \
git -C .git/beads-worktrees/beads commit -m "bd sync" && \
git push origin beads
```

Work is NOT complete until both pushes succeed.

## Code Style

Hooks enforce formatting (nixfmt, shellcheck). Follow these conventions:

- **Nix:** Use `inherit` for scope; keep expressions pure
- **Shell:** `set -euo pipefail`; quote variables; prefer `[[` over `[`
- **Docs:** Specs in `specs/`; update `specs/README.md` when adding
