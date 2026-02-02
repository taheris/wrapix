# Beads Issue Tracking

Lightweight issue tracker with first-class dependency support for AI agent workflows.

## Problem Statement

AI coding agents need persistent issue tracking that:
- Survives across sessions and context windows
- Tracks dependencies between tasks
- Syncs between host and container environments
- Integrates with git workflows
- Provides a CLI interface suitable for agent use

## Requirements

### Functional

1. **Issue CRUD** - Create, read, update, delete issues via `bd` CLI
2. **Dependencies** - First-class support for blocking relationships
3. **Ready Queue** - `bd ready` shows unblocked work
4. **Status Tracking** - Issues move through open → in_progress → closed
5. **Priority Levels** - P0 (critical) through P4 (backlog)
6. **Issue Types** - task, bug, feature, epic, question, docs
7. **Sync** - `bd sync` commits changes to git branch

### Non-Functional

1. **Agent-Friendly** - CLI designed for AI agent consumption
2. **Portable** - Works in containers via mounted `.beads/` directory
3. **Conflict-Free** - Dolt-native sync handles concurrent edits

## CLI Commands

| Command | Purpose |
|---------|---------|
| `bd ready` | Show issues ready to work (no blockers) |
| `bd list --status=open` | List all open issues |
| `bd show <id>` | Show issue details with dependencies |
| `bd create --title="..." --type=task --priority=2` | Create issue |
| `bd update <id> --status=in_progress` | Update issue |
| `bd close <id>` | Close issue |
| `bd dep add <issue> <depends-on>` | Add dependency |
| `bd sync` | Sync with git remote |

## Storage

```
.beads/
├── config.yaml      # Repository configuration
├── metadata.json    # Database metadata
├── dolt/            # Dolt database (primary storage)
└── dolt-remote/     # Dolt remote for container sync
```

### Sync Modes

| Mode | Description |
|------|-------------|
| JSONL | Export/import via `.beads/issues.jsonl` |
| Dolt-native | Use Dolt remotes for sync (preferred) |

## Workflow Integration

### Agent Session Pattern

```bash
bd sync                              # Pull latest
bd ready                             # Find work
bd update <id> --status=in_progress  # Claim
# ... do work ...
bd close <id>                        # Complete
bd sync                              # Push changes
```

### Ralph Integration

Ralph uses beads for issue tracking:
- `ralph todo` creates issues from specs via `bd create`
- `ralph run` finds work via `bd ready`
- Issues link to specs via description field

## Configuration

Key settings in `.beads/config.yaml`:

| Setting | Purpose |
|---------|---------|
| `issue-prefix` | Prefix for issue IDs (e.g., "wx" → "wx-1") |
| `sync-branch` | Git branch for beads commits |
| `sync.mode` | Sync mode: `dolt-native` or JSONL |
| `federation.remote` | Dolt remote URL for container sync |

## Affected Files

| File | Role |
|------|------|
| `.beads/config.yaml` | Repository configuration |
| `.beads/dolt/` | Dolt database storage |
| `CLAUDE.md` | Agent instructions for beads usage |

## Success Criteria

- [ ] Issues persist across agent sessions
- [ ] Dependencies correctly block `bd ready` output
- [ ] `bd sync` works in container environment
- [ ] Priority and status filtering works
- [ ] Issues can be created with descriptions

## Out of Scope

- Beads CLI implementation (external tool)
- Web UI for issue management
- Integration with external trackers (Jira, Linear)
