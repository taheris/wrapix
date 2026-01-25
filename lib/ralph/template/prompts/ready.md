# Task Decomposition

Convert a specification into implementable beads tasks.

## Context Pinning

First, read specs/README.md for project terminology and context:

{{PINNED_CONTEXT}}

## Current Specification

Label: {{LABEL}}
Spec file: {{SPEC_PATH}}

## Instructions

1. **Read the spec file** at {{SPEC_PATH}} thoroughly
2. **Create a parent epic bead** for this specification
3. **Break down into ordered tasks** as child beads
4. **Add dependencies** where tasks depend on each other
5. **Update specs/README.md** with the epic bead ID

## Task Breakdown Guidelines

- Each task should be self-contained with enough context for a fresh agent
- Order tasks by dependencies (what must be done first)
- Keep tasks focused - one clear objective per task
- Include test tasks where appropriate
- Consider: setup, implementation, tests, documentation

## Output Format

First, create the epic bead:
```bash
bd create --title="{{SPEC_TITLE}}" --type=epic --priority={{PRIORITY}} --labels="rl-{{LABEL}}"
```

Then, for each implementation task:
```bash
bd create --title="Task title" --description="Description with context" --type=task --priority=N --labels="rl-{{LABEL}}"
```

Add dependencies between tasks:
```bash
bd dep add <dependent-task> <depends-on-task>
```

## Update specs/README.md

After creating the epic, update the WIP table entry with the bead ID:
```markdown
| [{{SPEC_NAME}}.md](./{{SPEC_NAME}}.md) | beads-XXXXXX | Brief purpose |
```

## Exit Signals

- `READY_COMPLETE` - All tasks created, dependencies set, README updated
- `BLOCKED: <reason>` - Cannot decompose spec (missing information, unclear requirements)
