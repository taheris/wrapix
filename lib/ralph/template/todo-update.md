# Add Tasks to Existing Molecule

You are adding new tasks to an existing molecule. New requirements have been
gathered and stored separately - your job is to create tasks ONLY for those
new requirements.

{{> context-pinning}}

{{> spec-header}}

## Existing Specification

The main spec file (`specs/{{LABEL}}.md`) contains the already-implemented requirements:

```markdown
{{EXISTING_SPEC}}
```

**Do NOT create tasks for requirements in this section** - they are already implemented or have existing tasks.

## New Requirements

The following NEW requirements were gathered during `ralph plan -u` and need tasks:

```markdown
{{NEW_REQUIREMENTS}}
```

**Create tasks ONLY for the requirements above.** The existing spec is shown for context only.

## Existing Molecule

Molecule ID: {{MOLECULE_ID}}

Use `bd mol show {{MOLECULE_ID}}` to see the current tasks in this molecule.

## Instructions

1. **Analyze new requirements** - Understand what work needs to be done
2. **Create new tasks as children of the molecule**:
   ```bash
   TASK_ID=$(bd create --title="<task title>" --description="<detailed description>" \
     --type=task --labels="spec-{{LABEL}},profile:<profile>" --parent="{{MOLECULE_ID}}" --silent)
   ```
3. **Assign profile per-task** based on implementation needs:
   - Tasks touching `.rs` files or using cargo → `profile:rust`
   - Tasks touching `.py` files or using pytest/pip → `profile:python`
   - Tasks touching only `.nix`, `.sh`, `.md` files → `profile:base`
4. **Set execution order** with `bd dep add` if new tasks depend on existing ones:
   ```bash
   bd dep add <new-task> <existing-task>  # new-task waits for existing-task
   ```
5. **Merge new requirements into spec** - Integrate content from `{{NEW_REQUIREMENTS_PATH}}` into `specs/{{LABEL}}.md`

### Key Concepts

| Mechanism | Purpose | Effect |
|-----------|---------|--------|
| `--parent` | Links task to molecule | Enables `ralph status` progress tracking |
| `bd dep add` | Sets execution order | Controls what `bd ready` returns next |
| `profile:X` | Selects container profile | Determines toolchain available in `ralph run` |

## Task Breakdown Guidelines

- Each task should be **self-contained** with enough context for a fresh agent
- Consider dependencies on **existing tasks** in the molecule
- Keep tasks **focused** - one clear objective per task
- Include **test tasks** where appropriate
- **Assign profile per-task** based on what that specific task needs

## Spec Merge

After creating tasks, **integrate** the new requirements into the main spec file:

1. Read the current spec structure
2. Determine where new content belongs:
   - If it updates an existing section → **edit that section in place**
   - If it adds a new capability → **add a new section in the appropriate location**
   - If it supersedes existing content → **replace the old content**
3. Keep the spec **concise** - it should remain a single source of truth, not a changelog

Use the Edit tool to modify `specs/{{LABEL}}.md` directly. Do NOT append with `cat >>`.

The `state/{{LABEL}}.md` file will be automatically deleted after successful completion.

{{> exit-signals}}

- `RALPH_COMPLETE` - New tasks created, dependencies set, spec updated with new requirements
- `RALPH_BLOCKED: <reason>` - Cannot proceed (molecule not found, unclear requirements)
