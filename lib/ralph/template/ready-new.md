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
2. **Create the epic** - Use `bd create --type=epic --title="<feature name>" --labels="spec-{{LABEL}}"`
3. **Create child tasks** - For each piece of work:
   ```bash
   bd create --title="<task title>" --description="<detailed description>" --type=task --labels="spec-{{LABEL}}"
   ```
4. **Set dependencies** - Use `bd dep add <issue> <depends-on>` for sequential work
5. **Create molecule** - Use `bd mol create <epic-id>` to create the molecule
6. **Bond tasks** - Use `bd mol bond <epic-id> <task-id>` for each child task

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
