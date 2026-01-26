# Ralph Workflow

Spec-driven AI orchestration for feature development.

## Problem Statement

AI coding assistants work best with:
- Clear specifications before implementation
- Focused, single-issue work sessions
- Progress tracking across sessions
- Consistent prompts and context

Ralph provides a structured workflow that guides AI through spec creation, issue breakdown, and implementation.

## Requirements

### Functional

1. **Spec Interview** - `ralph plan <label>` initializes feature and conducts requirements gathering
2. **Spec Update** - `ralph plan --update <label>` refines existing specs for additional work
3. **Molecule Creation** - `ralph ready` converts specs to beads molecules
4. **Single-Issue Work** - `ralph step` works on one issue in fresh context
5. **Continuous Work** - `ralph loop` processes issues until complete
6. **Progress Tracking** - `ralph status` wraps `bd mol` commands for unified view
7. **Log Access** - `ralph logs` shows recent command output
8. **Prompt Tuning** - `ralph tune` edits prompt templates

### Non-Functional

1. **Context Efficiency** - Each step starts with minimal, focused context
2. **Resumable** - Work can stop and resume across sessions
3. **Observable** - Clear visibility into current state and progress via molecules

## Workflow Phases

```
plan → ready → loop/step → (done)
  │       │        │          │
  │       │        │          └─ bd mol squash (archive)
  │       │        └─ Implementation + bd mol bond (discovered work)
  │       └─ Molecule creation
  └─ Spec interview

Update cycle (for existing specs):
plan --update → ready → loop/step → (done)
      │            │
      │            └─ Bond new tasks to existing molecule
      └─ Refine spec, gather new requirements
```

### 1. Plan

```bash
ralph plan my-feature           # New spec
ralph plan --update my-feature  # Update existing spec
```

Combines workspace setup and spec interview into a single idempotent command:

- **Setup** (idempotent — safe to rerun):
  - Creates feature workspace directory if not exists
  - Initializes state files (`state/current.json`)
  - Creates `specs/my-feature.md` (or hidden in `state/` if configured)
- **Interview**:
  - Substitutes template placeholders fresh each run
  - Conducts spec-gathering conversation with AI
  - Writes requirements to spec file
  - Outputs `RALPH_COMPLETE` when done

**Update Mode** (`--update`):
- For specs that have already been implemented but need additional work
- During planning: discuss and capture NEW requirements only
- Do NOT write to spec file during planning conversation
- `ralph ready` updates spec and creates/bonds new tasks

### 2. Ready

```bash
ralph ready
```

- Reads completed spec
- **New spec**: Creates molecule (epic + child issues)
- **Update mode**: Bonds new tasks to existing molecule
- Stores molecule ID in `state/current.json`
- Sets appropriate priorities and dependencies

**Molecule tracking in current.json:**
```json
{
  "label": "my-feature",
  "molecule": "bd-xyz123",
  "update": false
}
```

### 3. Step / Loop

```bash
ralph step    # Work on single issue
ralph loop    # Work until all issues complete
```

- Selects issue from `bd ready` within the molecule
- Loads step prompt with issue context
- Implements in fresh Claude session
- Updates issue status on completion

**Discovered work** during implementation:
```bash
# Sequential (blocks current work)
bd mol bond <molecule> <new-issue> --type sequential

# Parallel (independent work)
bd mol bond <molecule> <new-issue> --type parallel
```

### 4. Status

```bash
ralph status
```

Convenience wrapper that calls `bd mol` commands with the current molecule:

```
Ralph Status: my-feature
===============================
Molecule: bd-xyz123
Spec: specs/my-feature.md

Progress:
  ▓▓▓▓▓▓▓▓░░ 80% (8/10)
  Rate: 2.5 steps/hour
  ETA: ~48 min

Current Position:
  [done]    Setup project structure
  [done]    Implement core feature
  [current] Write tests         ← you are here
  [ready]   Update documentation
  [blocked] Final review (waiting on tests)
```

Under the hood:
```bash
MOLECULE=$(jq -r '.molecule' "$CURRENT_FILE")
bd mol progress "$MOLECULE"
bd mol current "$MOLECULE"
bd mol stale --quiet
```

### 5. Cleanup

Users call `bd mol` directly for cleanup operations:

```bash
bd mol squash <molecule> --summary "..."  # Archive completed work
bd mol burn <molecule>                     # Abandon failed work
bd mol stale                               # Find orphaned molecules
```

## Prompt Templates

Located in `lib/ralph/template/`:

| Template | Phase | Purpose |
|----------|-------|---------|
| `plan.md` | plan | Spec gathering (planning only, no implementation) |
| `ready.md` | ready | Spec-to-issues conversion |
| `step.md` | step/loop | Single-issue implementation |

## Spec File Format

```markdown
# Feature Name

Overview of the feature.

## Problem Statement

Why this feature is needed.

## Requirements

### Functional
1. Requirement one
2. Requirement two

### Non-Functional
1. Performance requirement

## Affected Files

| File | Role |
|------|------|
| `path/to/file.nix` | Description |

## Success Criteria

- [ ] Criterion one
- [ ] Criterion two

## Out of Scope

- Thing not included
```

## Affected Files

| File | Role |
|------|------|
| `lib/ralph/cmd/ralph.sh` | Main dispatcher |
| `lib/ralph/cmd/plan.sh` | Feature initialization + spec interview |
| `lib/ralph/cmd/ready.sh` | Issue creation |
| `lib/ralph/cmd/step.sh` | Single-issue work |
| `lib/ralph/cmd/loop.sh` | Continuous work |
| `lib/ralph/cmd/status.sh` | Progress display |
| `lib/ralph/cmd/logs.sh` | Log viewer |
| `lib/ralph/cmd/util.sh` | Shared helper functions |
| `lib/ralph/template/` | Prompt templates |

## Integration with Beads Molecules

Ralph uses `bd mol` (beads molecules) for work tracking:

- **Specs are NOT molecules** - Specs are persistent markdown files; molecules are work batches
- **Each `ralph ready` creates a molecule** - The epic becomes the molecule root
- **Update mode bonds to existing molecules** - New tasks attach to prior work
- **Molecule ID stored in current.json** - Enables `ralph status` convenience wrapper

**Key molecule commands used by Ralph:**

| Command | Used by | Purpose |
|---------|---------|---------|
| `bd create --type=epic` | `ralph ready` | Create molecule root |
| `bd mol progress` | `ralph status` | Show completion %, rate, ETA |
| `bd mol current` | `ralph status` | Show position in DAG |
| `bd mol bond` | `ralph step` | Attach discovered work |
| `bd mol stale` | `ralph status` | Warn about orphaned molecules |

**Not used by Ralph** (user calls directly):
- `bd mol pour/wisp` - Ralph doesn't use formulas
- `bd mol squash` - User decides when to archive
- `bd mol burn` - User decides when to abandon

## Success Criteria

- [ ] `ralph plan <label>` initializes workspace and produces complete specifications
- [ ] `ralph plan --update <label>` refines existing specs without overwriting
- [ ] `ralph ready` creates molecule and stores ID in current.json
- [ ] `ralph ready` in update mode bonds new tasks to existing molecule
- [ ] `ralph step` completes single issues and can bond discovered work
- [ ] `ralph loop` processes all ready issues in molecule
- [ ] `ralph status` shows molecule progress via `bd mol` commands

## Out of Scope

- Multi-feature parallel work
- Automated testing integration
- PR creation automation
- Formula-based workflows (Ralph uses specs, not formulas)
