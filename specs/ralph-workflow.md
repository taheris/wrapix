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
2. **Issue Creation** - `ralph ready` converts specs to beads issues
3. **Single-Issue Work** - `ralph step` works on one issue in fresh context
4. **Continuous Work** - `ralph loop` processes issues until complete
5. **Progress Tracking** - `ralph status` shows workflow state
6. **Log Access** - `ralph logs` shows recent command output
7. **Prompt Tuning** - `ralph tune` edits prompt templates

### Non-Functional

1. **Context Efficiency** - Each step starts with minimal, focused context
2. **Resumable** - Work can stop and resume across sessions
3. **Observable** - Clear visibility into current state and progress

## Workflow Phases

```
plan → ready → loop/step
  │       │        │
  │       │        └─ Implementation
  │       └─ Issue creation
  └─ Feature initialization + Spec interview
```

### 1. Plan

```bash
ralph plan my-feature
```

Combines workspace setup and spec interview into a single idempotent command:

- **Setup** (idempotent — safe to rerun):
  - Creates feature workspace directory if not exists
  - Initializes state files (`state/label`, `state/config.toml`)
  - Creates `specs/my-feature.md` (or hidden in `state/` if configured)
- **Interview**:
  - Substitutes template placeholders fresh each run
  - Conducts spec-gathering conversation with AI
  - Writes requirements to spec file
  - Outputs `RALPH_COMPLETE` when done

### 2. Ready

```bash
ralph ready
```

- Reads completed spec
- Creates beads issues with dependencies
- Links issues to spec file
- Sets appropriate priorities

### 3. Step / Loop

```bash
ralph step    # Work on single issue
ralph loop    # Work until all issues complete
```

- Selects issue from `bd ready`
- Loads step prompt with issue context
- Implements in fresh Claude session
- Updates issue status on completion

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

## Integration with Beads

Ralph uses `bd` (beads) for issue tracking:

- `ralph ready` creates issues with `bd create`
- `ralph step/loop` finds work with `bd ready`
- Issues link to specs via description
- Dependencies model implementation order

## Success Criteria

- [ ] `ralph plan <label>` initializes workspace and produces complete specifications
- [ ] `ralph ready` creates correct beads issues
- [ ] `ralph step` completes single issues
- [ ] `ralph loop` processes all ready issues
- [ ] `ralph status` shows accurate progress

## Out of Scope

- Multi-feature parallel work
- Automated testing integration
- PR creation automation
