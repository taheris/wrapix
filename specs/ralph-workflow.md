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

1. **Spec Interview** — `ralph plan` initializes feature and conducts requirements gathering
2. **Plan Modes** — `ralph plan` requires exactly one mode flag:
   - `-n/--new`: New spec in `specs/`
   - `-h/--hidden`: New spec in `state/` (not committed)
   - `-u/--update`: Refine existing spec (combinable with `-h`)
3. **Molecule Creation** — `ralph todo` converts specs to beads molecules
4. **Issue Work** — `ralph run` processes issues (single with `--once`, continuous by default)
5. **Progress Tracking** — `ralph status` shows molecule progress
6. **Log Access** — `ralph logs` finds errors and shows context
7. **Template Validation** — `ralph check` validates all templates and partials
8. **Template Tuning** — `ralph tune` edits templates (interactive or integration mode)
9. **Template Sync** — `ralph sync` updates local templates (use `--diff` to preview changes)

### Non-Functional

1. **Context Efficiency** — Each step starts with minimal, focused context
2. **Resumable** — Work can stop and resume across sessions
3. **Observable** — Clear visibility into current state and progress via molecules
4. **Validated** — Templates statically checked at build time and after edits
5. **Isolated** — Claude-calling commands run inside wrapix containers for security and reproducibility

## Commands

### `ralph plan`

```bash
ralph plan -n <label>           # New spec in specs/
ralph plan -h <label>           # New spec in state/ (hidden)
ralph plan -u <label>           # Update existing spec in specs/
ralph plan -u -h <label>        # Update existing spec in state/
```

**Flags (exactly one mode required, except -u and -h can combine):**

| Flag | Location | Mode | Template |
|------|----------|------|----------|
| `-n/--new` | `specs/` | create | `plan-new.md` |
| `-h/--hidden` | `state/` | create | `plan-new.md` |
| `-u/--update` | auto-detect | update | `plan-update.md` |
| `-u -h` | `state/` | update | `plan-update.md` |

**Validation:**
- `-u/--update`: Error if spec doesn't exist at expected location
- No flag or invalid combination: Error with usage help

**Behavior:**
- Creates `state/current.json` with feature metadata
- Launches wrapix container with base profile
- Runs spec interview using appropriate template
- **New mode**: Writes spec to target location (`specs/` or `state/`)
- **Update mode**: Writes NEW requirements only to `state/<label>.md` (not the original spec)
- Outputs `RALPH_COMPLETE` when done

### `ralph todo`

```bash
ralph todo
```

Launches wrapix container with base profile. Reads `state/current.json` to determine mode:
- **New spec**: Creates molecule (epic + child issues) from `specs/<label>.md`
- **Update mode**: Reads NEW requirements from `state/<label>.md`, creates tasks only for those, then merges into `specs/<label>.md`

**Profile assignment:** The LLM analyzes each task's requirements and assigns appropriate `profile:X` labels based on implementation needs (e.g., tasks touching `.rs` files get `profile:rust`). This happens per-task, not per-spec.

Stores molecule ID in `state/current.json`. In update mode, cleans up `state/<label>.md` after successful merge.

### `ralph run`

```bash
ralph run                   # Continuous mode: process all issues until complete
ralph run --once            # Single-issue mode: process one issue then exit
ralph run -1                # Alias for --once
ralph run --profile=rust    # Override profile (applies to all iterations)
```

**Default (continuous) mode** — Runs on host as orchestrator:
- Queries for next ready issue from molecule
- Spawns implementation in fresh wrapix container (profile from bead label or flag)
- Waits for completion
- Repeats until all issues complete
- Handles discovered work via `bd mol bond`

**Single-issue mode (`--once` / `-1`)** — For debugging or manual control:
- Selects next ready issue from molecule
- Reads `profile:X` label from bead to determine container profile (fallback: base)
- Launches wrapix container with selected profile
- Loads step template with issue context
- Implements in fresh Claude session
- Updates issue status on completion
- Exits after one issue

### `ralph status`

```bash
ralph status
```

Shows molecule progress:
```
Ralph Status: my-feature
===============================
Molecule: bd-xyz123
Spec: specs/my-feature.md

Progress:
  [####------] 40% (4/10)

Current Position:
  [done]    Setup project structure
  [done]    Implement core feature
  [current] Write tests         <- you are here
  [ready]   Update documentation
  [blocked] Final review (waiting on tests)
```

### `ralph logs`

```bash
ralph logs              # Find most recent error, show 20 lines of context
ralph logs -n 50        # Show 50 lines of context before error
ralph logs --all        # Show full log without error filtering
```

Error-focused output: Scans for error patterns (exit code != 0, "error:", "failed"), shows context leading up to first match.

### `ralph check`

```bash
ralph check
```

Validates all templates:
- Partial files exist
- Body files parse correctly
- No syntax errors in Nix expressions
- Dry-run render with dummy values to catch placeholder typos

Exit codes: 0 = valid, 1 = errors (with details)

Also runs as part of `nix flake check`.

### `ralph tune`

**Interactive mode** (no stdin):
```bash
ralph tune
> What would you like to change?
> "Add guidance about handling blocked beads"
>
> Analyzing templates...
> This should go in step.md, section "Instructions"
>
> [makes edit to .wrapix/ralph/template/step.md]
> [runs ralph check]
> ✓ Template valid
```

**Integration mode** (stdin with diff):
```bash
ralph sync --diff | ralph tune
> Analyzing diff...
>
> Change 1/2: step.md lines 35-40
> + 6. **Blocked vs Waiting**: ...
>
> Where should this go?
>   1. Keep in step.md
>   2. Move to partial
>   3. Create new partial
> > 1
>
> Accept this change? [Y/n] y
> ✓ Change applied
```

AI-driven interview that asks questions until user accepts or abandons.

### `ralph sync`

```bash
ralph sync           # Update local templates from packaged
ralph sync --diff    # Show local template changes vs packaged (preview)
ralph sync --dry-run # Preview sync without executing
```

Synchronizes local templates with packaged versions:

1. Creates `.wrapix/ralph/template/` with fresh packaged templates
2. Moves existing customized templates to `.wrapix/ralph/backup/`
3. Copies all templates including variants and `partial/` directory

**`--diff` mode**: Shows changes between local templates and packaged versions. Pipe to `ralph tune` for integration:
```bash
ralph sync --diff | ralph tune
```

**Directory structure after sync:**
```
.wrapix/ralph/
├── config.nix
├── template/            # Fresh from packaged
│   ├── partial/
│   │   ├── context-pinning.md
│   │   ├── exit-signals.md
│   │   └── spec-header.md
│   ├── plan.md
│   ├── plan-new.md
│   ├── plan-update.md
│   ├── todo-new.md
│   ├── todo-update.md
│   └── step.md
└── backup/              # User customizations (if any)
    └── ...
```

Use `ralph sync --diff` to see what changed, then `ralph tune` to merge customizations from backup.

## Workflow Phases

```
plan → todo → run → (done)
  │       │     │       │
  │       │     │       └─ bd mol squash (archive)
  │       │     └─ Implementation + bd mol bond (discovered work)
  │       └─ Molecule creation from specs/<label>.md
  └─ Spec interview → writes specs/<label>.md

Update cycle (for existing specs):
plan --update → todo → run → (done)
      │            │
      │            ├─ Read new reqs from state/<label>.md
      │            ├─ Create tasks ONLY for new requirements
      │            ├─ Merge state/<label>.md → specs/<label>.md
      │            └─ Delete state/<label>.md
      └─ Gather NEW requirements → writes state/<label>.md
```

## Container Execution

Ralph runs Claude-calling commands inside wrapix containers for isolation and reproducibility.

| Command | Execution | Profile |
|---------|-----------|---------|
| `ralph plan` | wrapix container | base |
| `ralph todo` | wrapix container | base |
| `ralph run` | host (orchestrator) | N/A (spawns containerized work per-issue) |
| `ralph run --once` | wrapix container | from bead label or `--profile` flag (fallback: base) |
| `ralph status` | host | N/A (utility) |
| `ralph logs` | host | N/A (utility) |
| `ralph check` | host | N/A (utility) |
| `ralph tune` | host | N/A (utility) |
| `ralph sync` | host | N/A (utility) |

**Rationale:**
- `plan` and `todo` involve AI decision-making that benefits from isolation
- `run --once` performs implementation work requiring language toolchains
- `run` (continuous) is a simple orchestrator that spawns containerized steps
- Utility commands don't invoke Claude and run directly on host

## Profile Selection

Profiles determine which language toolchains are available in the wrapix container.

### Available Profiles

| Profile | Includes |
|---------|----------|
| `base` | Core tools, git, standard utilities |
| `rust` | base + Rust toolchain, cargo |
| `python` | base + Python, pip, venv |
| `debug` | base + debugging tools (see tmux-mcp spec) |

### Profile Assignment Flow

1. **`ralph todo`** — LLM analyzes each task and assigns `profile:X` label based on:
   - Files the task will touch (`.rs` → rust, `.py` → python, `.nix` → base)
   - Tools required (cargo, pytest, etc.)
   - Task description context

2. **Task creation** includes profile label:
   ```bash
   bd create --title="Implement parser" --labels "spec:my-feature,profile:rust" ...
   bd create --title="Update docs" --labels "spec:my-feature,profile:base" ...
   ```

3. **`ralph run`** reads profile from bead:
   ```bash
   # Get profile label from bead
   profile=$(bd show "$issue_id" --json | jq -r '.labels[] | select(startswith("profile:")) | split(":")[1]')
   profile="${profile:-base}"
   ```

4. **Override** via `--profile` flag takes precedence:
   ```bash
   ralph run --once --profile=rust  # Ignore bead label, use rust
   ```

### Per-Task Profiles

Different tasks in the same molecule may have different profiles. The LLM decides per-task based on what that specific task needs:

| Task | Profile |
|------|---------|
| "Implement Rust parser" | `profile:rust` |
| "Write Python test harness" | `profile:python` |
| "Update Nix build config" | `profile:base` |
| "Add documentation" | `profile:base` |

This is more accurate than spec-level detection because tasks often span multiple languages.

## Template System

### Nix-Native Templates

Templates are defined as Nix expressions with static validation:

```nix
# lib/ralph/template/default.nix
{ lib }:
let
  mkTemplate = { body, partials ? [], variables }:
    let
      resolvedPartials = map (p: builtins.readFile p) partials;
      content = builtins.readFile body;
    in {
      inherit content variables partials;
      render = vars:
        assert lib.assertMsg
          (builtins.all (v: vars ? ${v}) variables)
          "Missing required variables: ${builtins.toJSON variables}";
        lib.replaceStrings
          (map (v: "{{${v}}}") variables)
          (map (v: vars.${v}) variables)
          content;
    };
in {
  plan-new = mkTemplate {
    body = ./plan-new.md;
    partials = [ ./partial/context-pinning.md ./partial/exit-signals.md ];
    variables = [ "PINNED_CONTEXT" "LABEL" "SPEC_PATH" ];
  };
  # ... other templates
}
```

### Partials

Shared content via `{{> partial-name}}` markers:

```markdown
## Instructions

{{> context-pinning}}

1. Read the spec...
```

Resolved during template rendering.

### Template Structure

```
lib/ralph/template/
├── default.nix              # Template definitions + validation
├── partial/
│   ├── context-pinning.md   # Project context loading
│   ├── exit-signals.md      # Exit signal format
│   └── spec-header.md       # Label, spec path block
├── plan-new.md              # New spec interview
├── plan-update.md           # Update existing spec
├── todo-new.md              # Create molecule
├── todo-update.md           # Bond new tasks
└── step.md                  # Single-issue implementation
```

### Template Variables

| Variable | Source | Used By |
|----------|--------|---------|
| `PINNED_CONTEXT` | Read from `pinnedContext` file | all |
| `LABEL` | From command args | all |
| `SPEC_PATH` | Computed from label + mode | all |
| `SPEC_CONTENT` | Read from spec file | todo-new, step |
| `EXISTING_SPEC` | Read from `specs/<label>.md` | plan-update, todo-update |
| `NEW_REQUIREMENTS` | Read from `state/<label>.md` | todo-update |
| `MOLECULE_ID` | From `state/current.json` | todo-update, step |
| `ISSUE_ID` | From `bd ready` | step |
| `TITLE` | From issue | step |
| `DESCRIPTION` | From issue | step |
| `EXIT_SIGNALS` | Template-specific list | all (via partial) |

### Flake Check Integration

```nix
# flake.nix
{
  checks.${system} = {
    ralph-templates = ralph.lib.validateTemplates {
      templates = ./lib/ralph/template;
    };
  };
}
```

## Project Configuration

Projects configure ralph via `.wrapix/ralph/config.nix` (local project overrides):

```nix
# .wrapix/ralph/config.nix
{
  # Wrapix flake reference (provides container profiles)
  wrapix = "github:user/wrapix";  # or local path

  # Context pinning - file read for {{PINNED_CONTEXT}}
  pinnedContext = ./specs/README.md;

  # Spec locations
  specDir = ./specs;
  stateDir = ./state;

  # Template overlay (optional, for local customizations)
  templateDir = ./.wrapix/ralph/template;  # null = use packaged only
}
```

**Defaults** (when no config exists):
```nix
{
  wrapix = null;            # Error if container commands need it
  pinnedContext = ./specs/README.md;
  specDir = ./specs;
  stateDir = ./state;
  templateDir = null;       # Use packaged templates only
}
```

**Template loading order:**
1. Check `templateDir` (local overlay) first
2. Fall back to packaged templates

**Profile resolution:**
- Profiles (base, rust, python, debug) are defined in wrapix (see profiles.md spec)
- Ralph references profiles by name; wrapix provides the actual container configuration

## Template Content Requirements

### Partials

**`partial/context-pinning.md`:**
```markdown
## Context Pinning

First, read specs/README.md to understand project terminology:

{{PINNED_CONTEXT}}
```

**`partial/exit-signals.md`:**
```markdown
## Exit Signals

Output ONE of these at the end of your response:

{{EXIT_SIGNALS}}
```

**`partial/spec-header.md`:**
```markdown
## Current Feature

Label: {{LABEL}}
Spec file: {{SPEC_PATH}}
```

### plan-new.md

**Purpose:** Conduct spec interview for new features

**Required sections:**
1. Role statement — "You are conducting a specification interview"
2. Planning-only warning — No code, only spec output
3. `{{> context-pinning}}`
4. `{{> spec-header}}`
5. Interview guidelines — One question at a time, capture terminology, identify code locations, clarify scope, define success criteria
6. Interview flow — Describe idea → clarify → write spec → RALPH_COMPLETE
7. Spec file format — Title, problem, requirements, affected files, success criteria, out of scope
8. Implementation notes section — Optional transient context, stripped on finalize
9. `{{> exit-signals}}`

**Exit signals:** RALPH_COMPLETE, RALPH_BLOCKED, RALPH_CLARIFY

### plan-update.md

**Purpose:** Gather additional requirements for existing specs

**Required sections:**
1. Role statement — "You are refining an existing specification"
2. Planning-only warning — No code, original spec not modified
3. `{{> context-pinning}}`
4. `{{> spec-header}}`
5. Existing spec display — Show current spec from `specs/<label>.md` for reference
6. Update guidelines — Discuss NEW requirements only
7. Output — Write new requirements to `state/<label>.md` (ralph todo merges into spec)
8. `{{> exit-signals}}`

**Output file:** `state/<label>.md` contains only the NEW requirements gathered during the interview. This file is consumed by `ralph todo` which:
1. Creates tasks for only these new requirements
2. Merges the content into `specs/<label>.md`
3. Deletes `state/<label>.md`

**Exit signals:** RALPH_COMPLETE, RALPH_BLOCKED, RALPH_CLARIFY

### todo-new.md

**Purpose:** Convert spec to molecule with tasks

**Required sections:**
1. Role statement — "You are decomposing a specification into tasks"
2. `{{> context-pinning}}`
3. `{{> spec-header}}`
4. Spec content — Full spec to decompose
5. Task breakdown guidelines — Self-contained, ordered by deps, one objective per task
6. Profile assignment guidance — Assign `profile:X` per-task based on implementation needs:
   - Tasks touching `.rs` files or using cargo → `profile:rust`
   - Tasks touching `.py` files or using pytest/pip → `profile:python`
   - Tasks touching only `.nix`, `.sh`, `.md` files → `profile:base`
7. Molecule creation — Create epic, child tasks with profile labels, set dependencies
8. README update — Add molecule ID to specs/README.md
9. `{{> exit-signals}}`

**Exit signals:** RALPH_COMPLETE, RALPH_BLOCKED

### todo-update.md

**Purpose:** Add new tasks to existing molecule

**Required sections:**
1. Role statement — "You are adding tasks to an existing molecule"
2. `{{> context-pinning}}`
3. `{{> spec-header}}`
4. Existing spec — Show `specs/<label>.md` for context (what's already implemented)
5. Existing molecule info — ID, current tasks, progress
6. New requirements — Show `state/<label>.md` content (what to create tasks for)
7. Profile assignment guidance — Assign `profile:X` per-task based on implementation needs
8. Task creation — Create tasks ONLY for new requirements, bond to molecule
9. Spec merge — Append `state/<label>.md` content to `specs/<label>.md`
10. Cleanup — Delete `state/<label>.md` after successful merge
11. `{{> exit-signals}}`

**Key behavior:** Only create tasks for requirements in `state/<label>.md`. The existing spec is shown for context but should NOT generate new tasks.

**Exit signals:** RALPH_COMPLETE, RALPH_BLOCKED

### step.md

**Purpose:** Implement single issue in fresh context

**Required sections:**
1. `{{> context-pinning}}`
2. `{{> spec-header}}`
3. Issue details — ID, title, description
4. Instructions:
   1. **Understand** — Read spec and issue before changes
   2. **Test strategy** — Property-based vs unit tests
   3. **Implement** — Write code following spec
   4. **Discovered work** — Create issue, bond to molecule (sequential vs parallel)
   5. **Quality gates** — Tests pass, lint passes, changes committed
   6. **Blocked vs waiting** — Distinguish dependency blocks from true blocks:
      - Need user input? → `RALPH_BLOCKED: <reason>`
      - Need other beads done? → Add dep with `bd dep add`, output `RALPH_COMPLETE`
5. Land the plane — Follow session protocol
6. `{{> exit-signals}}`

**Exit signals:** RALPH_COMPLETE, RALPH_BLOCKED, RALPH_CLARIFY

## State Management

**`state/current.json`:**
```json
{
  "label": "my-feature",
  "update": false,
  "hidden": false,
  "spec_path": "specs/my-feature.md",
  "molecule": "bd-xyz123"
}
```

| Field | Description |
|-------|-------------|
| `label` | Feature identifier |
| `update` | Whether this is an update to existing spec |
| `hidden` | Whether spec is in `state/` (not committed) |
| `spec_path` | Full path to spec file |
| `molecule` | Beads molecule ID (set by `ralph todo`) |

**`state/<label>.md`** (update mode only):

When `ralph plan --update` runs, it writes NEW requirements to `state/<label>.md`. This file:
- Contains only the requirements gathered during the update interview
- Is separate from the original spec in `specs/<label>.md`
- Gets merged into `specs/<label>.md` by `ralph todo`
- Is deleted after successful merge

This separation ensures `ralph todo` knows exactly what's new and only creates tasks for those requirements.

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
| `lib/ralph/cmd/todo.sh` | Issue creation (renamed from ready.sh) |
| `lib/ralph/cmd/run.sh` | Issue work (merged from step.sh + loop.sh) |
| `lib/ralph/cmd/status.sh` | Progress display |
| `lib/ralph/cmd/logs.sh` | Error-focused log viewer |
| `lib/ralph/cmd/check.sh` | Template validation |
| `lib/ralph/cmd/tune.sh` | Template editing (interactive + integration) |
| `lib/ralph/cmd/sync.sh` | Template sync from packaged (includes --diff) |
| `lib/ralph/cmd/util.sh` | Shared helper functions |
| `lib/ralph/template/` | Prompt templates |
| `lib/ralph/template/default.nix` | Nix template definitions |

## Integration with Beads Molecules

Ralph uses `bd mol` for work tracking:

- **Specs are NOT molecules** — Specs are persistent markdown; molecules are work batches
- **Each `ralph todo` creates/updates a molecule** — Epic becomes molecule root
- **Update mode bonds to existing molecules** — New tasks attach to prior work
- **Molecule ID stored in current.json** — Enables `ralph status` convenience wrapper

**Key molecule commands used by Ralph:**

| Command | Used by | Purpose |
|---------|---------|---------|
| `bd create --type=epic` | `ralph todo` | Create molecule root |
| `bd mol progress` | `ralph status` | Show completion % |
| `bd mol current` | `ralph status` | Show position in DAG |
| `bd mol bond` | `ralph run` | Attach discovered work |
| `bd mol stale` | `ralph status` | Warn about orphaned molecules |

**Not used by Ralph** (user calls directly):
- `bd mol squash` — User decides when to archive
- `bd mol burn` — User decides when to abandon

## Success Criteria

- [ ] `ralph plan -n <label>` creates new spec in `specs/`
  [verify](tests/ralph/run-tests.sh::test_plan_flag_validation)
- [ ] `ralph plan -h <label>` creates new spec in `state/`
  [verify](tests/ralph/run-tests.sh::test_plan_flag_validation)
- [ ] `ralph plan -u <label>` validates spec exists before updating
  [verify](tests/ralph/run-tests.sh::test_plan_flag_validation)
- [ ] `ralph plan -u <label>` writes NEW requirements to `state/<label>.md`
  [judge](tests/judges/ralph-workflow.sh::test_plan_update_writes_new_requirements)
- [ ] `ralph plan -u -h <label>` updates hidden spec
  [judge](tests/judges/ralph-workflow.sh::test_plan_update_hidden)
- [ ] `ralph plan` runs Claude in wrapix container with base profile
  [judge](tests/judges/ralph-workflow.sh::test_plan_runs_in_container)
- [ ] `ralph todo` creates molecule and stores ID in current.json
  [verify](tests/ralph/run-tests.sh::test_run_closes_issue_on_complete)
- [ ] `ralph todo` (new mode) creates tasks from `specs/<label>.md`
  [verify](tests/ralph/run-tests.sh::test_run_closes_issue_on_complete)
- [ ] `ralph todo` (update mode) reads NEW requirements from `state/<label>.md`
  [judge](tests/judges/ralph-workflow.sh::test_todo_update_reads_new_requirements)
- [ ] `ralph todo` (update mode) creates tasks ONLY for new requirements
  [judge](tests/judges/ralph-workflow.sh::test_todo_update_creates_only_new)
- [ ] `ralph todo` (update mode) merges `state/<label>.md` into `specs/<label>.md`
  [judge](tests/judges/ralph-workflow.sh::test_todo_update_merges_state)
- [ ] `ralph todo` (update mode) deletes `state/<label>.md` after merge
  [judge](tests/judges/ralph-workflow.sh::test_todo_update_deletes_state)
- [ ] `ralph todo` runs Claude in wrapix container with base profile
  [judge](tests/judges/ralph-workflow.sh::test_todo_runs_in_container)
- [ ] `ralph todo` LLM assigns `profile:X` labels per-task based on implementation needs
  [verify](tests/ralph/run-tests.sh::test_run_profile_selection)
- [ ] `ralph run` reads `profile:X` label from bead and uses that profile
  [verify](tests/ralph/run-tests.sh::test_run_profile_selection)
- [ ] `ralph run --profile=X` overrides bead profile label
  [verify](tests/ralph/run-tests.sh::test_run_profile_selection)
- [ ] `ralph run` falls back to base profile when no label present
  [verify](tests/ralph/run-tests.sh::test_run_profile_selection)
- [ ] `ralph run --once` completes single issues with blocked-vs-waiting guidance
  [verify](tests/ralph/run-tests.sh::test_run_closes_issue_on_complete)
- [ ] `ralph run` (continuous) runs on host, spawning containerized work per issue
  [verify](tests/ralph/run-tests.sh::test_run_loop_processes_all)
- [ ] `ralph check` validates all templates and partials
  [verify](tests/ralph/run-tests.sh::test_check_valid_templates)
- [ ] `ralph tune` (interactive) identifies correct template and makes edits
  [judge](tests/judges/ralph-workflow.sh::test_tune_interactive)
- [ ] `ralph tune` (integration) ingests diff and interviews about changes
  [judge](tests/judges/ralph-workflow.sh::test_tune_integration)
- [ ] `ralph sync --diff` shows local template changes vs packaged
  [verify](tests/ralph/run-tests.sh::test_diff_local_modifications)
- [ ] `ralph sync` updates templates and backs up customizations
  [verify](tests/ralph/run-tests.sh::test_sync_backup)
- [ ] `ralph sync --dry-run` previews without executing
  [verify](tests/ralph/run-tests.sh::test_sync_dry_run)
- [ ] `nix flake check` includes template validation
  [verify](tests/ralph/run-tests.sh::test_check_exit_codes)
- [ ] Templates use Nix-native definitions with static validation
  [verify](tests/ralph/run-tests.sh::test_render_template_basic)
- [ ] Partials work via `{{> partial-name}}` markers
  [verify](tests/ralph/run-tests.sh::test_plan_template_with_partials)

## Out of Scope

- Multi-feature parallel work
- Automated testing integration
- PR creation automation
- Formula-based workflows (Ralph uses specs, not formulas)
- Cross-repo automation for template propagation (manual diff + tune)
