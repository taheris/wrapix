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

1. **Feature Initialization** - `ralph start` creates feature workspace
2. **Spec Interview** - `ralph plan` conducts requirements gathering
3. **Issue Creation** - `ralph ready` converts specs to beads issues
4. **Single-Issue Work** - `ralph step` works on one issue in fresh context
5. **Continuous Work** - `ralph loop` processes issues until complete
6. **Progress Tracking** - `ralph status` shows workflow state
7. **Log Access** - `ralph logs` shows recent command output
8. **Prompt Tuning** - `ralph tune` edits prompt templates

### Non-Functional

1. **Context Efficiency** - Each step starts with minimal, focused context
2. **Resumable** - Work can stop and resume across sessions
3. **Observable** - Clear visibility into current state and progress

## Workflow Phases

```
start → plan → ready → loop/step
  │       │       │        │
  │       │       │        └─ Implementation
  │       │       └─ Issue creation
  │       └─ Spec interview
  └─ Feature initialization
```

### 1. Start

```bash
ralph start my-feature
```

- Creates `specs/my-feature.md`
- Updates `specs/README.md`
- Sets up feature context

### 2. Plan

```bash
ralph plan
```

- Loads plan prompt template
- Conducts spec-gathering conversation
- Writes requirements to spec file
- Outputs `INTERVIEW_COMPLETE` when done

### 3. Ready

```bash
ralph ready
```

- Reads completed spec
- Creates beads issues with dependencies
- Links issues to spec file
- Sets appropriate priorities

### 4. Step / Loop

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
| `lib/ralph/ralph.sh` | Main dispatcher |
| `lib/ralph/start.sh` | Feature initialization |
| `lib/ralph/plan.sh` | Spec interview |
| `lib/ralph/ready.sh` | Issue creation |
| `lib/ralph/step.sh` | Single-issue work |
| `lib/ralph/loop.sh` | Continuous work |
| `lib/ralph/status.sh` | Progress display |
| `lib/ralph/logs.sh` | Log viewer |
| `lib/ralph/tune.sh` | Template editor |
| `lib/ralph/template/` | Prompt templates |

## Integration with Beads

Ralph uses `bd` (beads) for issue tracking:

- `ralph ready` creates issues with `bd create`
- `ralph step/loop` finds work with `bd ready`
- Issues link to specs via description
- Dependencies model implementation order

## Success Criteria

- [ ] `ralph start` creates valid spec structure
- [ ] `ralph plan` produces complete specifications
- [ ] `ralph ready` creates correct beads issues
- [ ] `ralph step` completes single issues
- [ ] `ralph loop` processes all ready issues
- [ ] `ralph status` shows accurate progress

## Out of Scope

- Multi-feature parallel work
- Automated testing integration
- PR creation automation
