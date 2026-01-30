# Task Decomposition

You are decomposing a specification into implementable tasks. Your goal is to
create a beads molecule (epic + child issues) that breaks down the work.

{{> context-pinning}}

{{> spec-header}}

## Specification Content

{{SPEC_CONTENT}}

## Task Breakdown Guidelines

- Each task should be **self-contained** with enough context for a fresh agent
- Order tasks by **dependencies** (what must be done first)
- Keep tasks **focused** - one clear objective per task
- Include **test tasks** where appropriate
- Consider: setup, implementation, tests, documentation

## Instructions

1. **Analyze the spec** - Understand all requirements and affected files
2. **Create the epic** (molecule root):
   ```bash
   MOLECULE_ID=$(bd create --type=epic --title="<feature name>" --labels="spec-{{LABEL}}" --silent)
   ```
3. **Store the molecule ID** in current.json:
   ```bash
   jq --arg mol "$MOLECULE_ID" '.molecule = $mol' {{CURRENT_FILE}} > {{CURRENT_FILE}}.tmp && mv {{CURRENT_FILE}}.tmp {{CURRENT_FILE}}
   ```
4. **Create child tasks** with `--parent` to link them to the molecule:
   ```bash
   TASK_ID=$(bd create --title="<task title>" --description="<detailed description>" \
     --type=task --labels="spec-{{LABEL}}" --parent="$MOLECULE_ID" --silent)
   ```
5. **Set execution order** with `bd dep add` for tasks that must run sequentially:
   ```bash
   bd dep add <later-task> <earlier-task>  # later-task waits for earlier-task
   ```

### Key Concepts

| Mechanism | Purpose | Effect |
|-----------|---------|--------|
| `--parent` | Links task to molecule | Enables `ralph status` progress tracking |
| `bd dep add` | Sets execution order | Controls what `bd ready` returns next |

Both are required: `--parent` for visibility, `bd dep add` for ordering.

## Output Format

After creating all tasks:

1. List the epic ID and all task IDs created
2. Show the dependency graph
3. Confirm the molecule was created

## README Update

After creating the molecule, update `specs/README.md`:
- Find the row for this spec
- Update the Beads column with the molecule ID (epic ID)

{{> exit-signals}}

- `RALPH_COMPLETE` - All tasks created, dependencies set, molecule created
- `RALPH_BLOCKED: <reason>` - Cannot decompose spec (missing information, unclear requirements)
