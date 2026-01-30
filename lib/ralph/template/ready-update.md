# Add Tasks to Existing Molecule

You are adding new tasks to an existing molecule. The spec has been updated with
new requirements that need to be implemented.

{{> context-pinning}}

{{> spec-header}}

## Existing Molecule

Molecule ID: {{MOLECULE_ID}}

Current progress:
{{MOLECULE_PROGRESS}}

## Updated Specification

{{SPEC_CONTENT}}

## New Requirements

The following new requirements were gathered during the plan-update conversation:

{{NEW_REQUIREMENTS}}

## Instructions

1. **Review existing tasks** - Use `bd mol show {{MOLECULE_ID}}` to see current tasks
2. **Create new tasks as children of the molecule** using `--parent`:
   ```bash
   TASK_ID=$(bd create --title="<task title>" --description="<detailed description>" \
     --type=task --labels="spec-{{LABEL}}" --parent="{{MOLECULE_ID}}" --silent)
   ```
3. **Set execution order** with `bd dep add` if new tasks depend on existing ones:
   ```bash
   bd dep add <new-task> <existing-task>  # new-task waits for existing-task
   ```

### Key Concepts

| Mechanism | Purpose | Effect |
|-----------|---------|--------|
| `--parent` | Links task to molecule | Enables `ralph status` progress tracking |
| `bd dep add` | Sets execution order | Controls what `bd ready` returns next |

Both are required: `--parent` for visibility, `bd dep add` for ordering.

## Task Breakdown Guidelines

- Each task should be **self-contained** with enough context for a fresh agent
- Consider dependencies on **existing tasks** in the molecule
- Keep tasks **focused** - one clear objective per task
- Include **test tasks** where appropriate

## Spec Update

After creating tasks, update the spec file (`{{SPEC_PATH}}`) to include the new requirements:
- Add new items to the Requirements section
- Add new success criteria
- Update Affected Files if needed

{{> exit-signals}}

- `RALPH_COMPLETE` - New tasks created as children of molecule, dependencies set, spec updated
- `RALPH_BLOCKED: <reason>` - Cannot proceed (molecule not found, unclear requirements)
