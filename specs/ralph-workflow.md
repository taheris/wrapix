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
3. **Molecule Creation** — `ralph ready` converts specs to beads molecules
4. **Single-Issue Work** — `ralph step` works on one issue in fresh context
5. **Continuous Work** — `ralph loop` processes issues until complete
6. **Progress Tracking** — `ralph status` shows molecule progress
7. **Log Access** — `ralph logs` shows recent command output
8. **Template Validation** — `ralph check` validates all templates and partials
9. **Template Tuning** — `ralph tune` edits templates (interactive or integration mode)
10. **Template Diff** — `ralph diff` shows local template changes vs packaged
11. **Template Sync** — `ralph sync` updates local templates from packaged versions

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

### `ralph ready`

```bash
ralph ready
```

Launches wrapix container with base profile. Reads `state/current.json` to determine mode:
- **New spec**: Creates molecule (epic + child issues) from `specs/<label>.md`
- **Update mode**: Reads NEW requirements from `state/<label>.md`, creates tasks only for those, then merges into `specs/<label>.md`

**Profile assignment:** The LLM analyzes each task's requirements and assigns appropriate `profile:X` labels based on implementation needs (e.g., tasks touching `.rs` files get `profile:rust`). This happens per-task, not per-spec.

Stores molecule ID in `state/current.json`. In update mode, cleans up `state/<label>.md` after successful merge.

### `ralph step`

```bash
ralph step                  # Use profile from bead label (or base)
ralph step --profile=rust   # Override profile
```

- Selects next ready issue from molecule
- Reads `profile:X` label from bead to determine container profile (fallback: base)
- Launches wrapix container with selected profile
- Loads step template with issue context
- Implements in fresh Claude session
- Updates issue status on completion

### `ralph loop`

```bash
ralph loop
```

Runs on host as orchestrator (not in container):
- Queries for next ready issue from molecule
- Spawns `ralph step` in fresh wrapix container (profile per-step)
- Waits for step completion
- Repeats until all issues complete
- Handles discovered work via `bd mol bond`

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
ralph logs           # Recent output
ralph logs -f        # Follow mode
```

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
> [makes edit to .ralph/template/step.md]
> [runs ralph check]
> ✓ Template valid
```

**Integration mode** (stdin with diff):
```bash
ralph diff | ralph tune
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

### `ralph diff`

```bash
ralph diff           # Show local template changes vs packaged
ralph diff step      # Show diff for specific template
```

Pipe to `ralph tune` for integration:
```bash
ralph diff | ralph tune
```

### `ralph sync`

```bash
ralph sync           # Update local templates from packaged
ralph sync --dry-run # Preview changes without executing
```

Synchronizes local templates with packaged versions:

1. Creates `.ralph/template/` with fresh packaged templates
2. Moves existing customized templates to `.ralph/backup/`
3. Copies all templates including variants and `partial/` directory

**Directory structure after sync:**
```
.ralph/
├── config.nix
├── template/            # Fresh from packaged
│   ├── partial/
│   │   ├── context-pinning.md
│   │   ├── exit-signals.md
│   │   └── spec-header.md
│   ├── plan.md
│   ├── plan-new.md
│   ├── plan-update.md
│   ├── ready.md
│   ├── ready-new.md
│   ├── ready-update.md
│   └── step.md
└── backup/              # User customizations (if any)
    └── ...
```

Use `ralph diff` to see what changed, then `ralph tune` to merge customizations from backup.

## Workflow Phases

```
plan → ready → loop/step → (done)
  │       │        │          │
  │       │        │          └─ bd mol squash (archive)
  │       │        └─ Implementation + bd mol bond (discovered work)
  │       └─ Molecule creation from specs/<label>.md
  └─ Spec interview → writes specs/<label>.md

Update cycle (for existing specs):
plan --update → ready → loop/step → (done)
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
| `ralph ready` | wrapix container | base |
| `ralph step` | wrapix container | from bead label or `--profile` flag (fallback: base) |
| `ralph loop` | host | N/A (orchestrates containerized steps) |
| `ralph status` | host | N/A (utility) |
| `ralph logs` | host | N/A (utility) |
| `ralph check` | host | N/A (utility) |
| `ralph tune` | host | N/A (utility) |
| `ralph diff` | host | N/A (utility) |
| `ralph sync` | host | N/A (utility) |

**Rationale:**
- `plan` and `ready` involve AI decision-making that benefits from isolation
- `step` performs implementation work requiring language toolchains
- `loop` is a simple orchestrator that spawns containerized steps
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

1. **`ralph ready`** — LLM analyzes each task and assigns `profile:X` label based on:
   - Files the task will touch (`.rs` → rust, `.py` → python, `.nix` → base)
   - Tools required (cargo, pytest, etc.)
   - Task description context

2. **Task creation** includes profile label:
   ```bash
   bd create --title="Implement parser" --labels "spec:my-feature,profile:rust" ...
   bd create --title="Update docs" --labels "spec:my-feature,profile:base" ...
   ```

3. **`ralph step`** reads profile from bead:
   ```bash
   # Get profile label from bead
   profile=$(bd show "$issue_id" --json | jq -r '.labels[] | select(startswith("profile:")) | split(":")[1]')
   profile="${profile:-base}"
   ```

4. **Override** via `--profile` flag takes precedence:
   ```bash
   ralph step --profile=rust  # Ignore bead label, use rust
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
├── ready-new.md             # Create molecule
├── ready-update.md          # Bond new tasks
└── step.md                  # Single-issue implementation
```

### Template Variables

| Variable | Source | Used By |
|----------|--------|---------|
| `PINNED_CONTEXT` | Read from `pinnedContext` file | all |
| `LABEL` | From command args | all |
| `SPEC_PATH` | Computed from label + mode | all |
| `SPEC_CONTENT` | Read from spec file | ready-new, step |
| `EXISTING_SPEC` | Read from `specs/<label>.md` | plan-update, ready-update |
| `NEW_REQUIREMENTS` | Read from `state/<label>.md` | ready-update |
| `MOLECULE_ID` | From `state/current.json` | ready-update, step |
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

Projects configure ralph via `.ralph/config.nix` (local project overrides):

```nix
# .ralph/config.nix
{
  # Wrapix flake reference (provides container profiles)
  wrapix = "github:user/wrapix";  # or local path

  # Context pinning - file read for {{PINNED_CONTEXT}}
  pinnedContext = ./specs/README.md;

  # Spec locations
  specDir = ./specs;
  stateDir = ./state;

  # Template overlay (optional, for local customizations)
  templateDir = ./.ralph/template;  # null = use packaged only
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
7. Output — Write new requirements to `state/<label>.md` (ralph ready merges into spec)
8. `{{> exit-signals}}`

**Output file:** `state/<label>.md` contains only the NEW requirements gathered during the interview. This file is consumed by `ralph ready` which:
1. Creates tasks for only these new requirements
2. Merges the content into `specs/<label>.md`
3. Deletes `state/<label>.md`

**Exit signals:** RALPH_COMPLETE, RALPH_BLOCKED, RALPH_CLARIFY

### ready-new.md

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

### ready-update.md

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
| `molecule` | Beads molecule ID (set by `ralph ready`) |

**`state/<label>.md`** (update mode only):

When `ralph plan --update` runs, it writes NEW requirements to `state/<label>.md`. This file:
- Contains only the requirements gathered during the update interview
- Is separate from the original spec in `specs/<label>.md`
- Gets merged into `specs/<label>.md` by `ralph ready`
- Is deleted after successful merge

This separation ensures `ralph ready` knows exactly what's new and only creates tasks for those requirements.

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
| `lib/ralph/cmd/check.sh` | Template validation |
| `lib/ralph/cmd/tune.sh` | Template editing (interactive + integration) |
| `lib/ralph/cmd/diff.sh` | Template diff |
| `lib/ralph/cmd/sync.sh` | Template sync from packaged |
| `lib/ralph/cmd/util.sh` | Shared helper functions |
| `lib/ralph/template/` | Prompt templates |
| `lib/ralph/template/default.nix` | Nix template definitions |

## Integration with Beads Molecules

Ralph uses `bd mol` for work tracking:

- **Specs are NOT molecules** — Specs are persistent markdown; molecules are work batches
- **Each `ralph ready` creates/updates a molecule** — Epic becomes molecule root
- **Update mode bonds to existing molecules** — New tasks attach to prior work
- **Molecule ID stored in current.json** — Enables `ralph status` convenience wrapper

**Key molecule commands used by Ralph:**

| Command | Used by | Purpose |
|---------|---------|---------|
| `bd create --type=epic` | `ralph ready` | Create molecule root |
| `bd mol progress` | `ralph status` | Show completion % |
| `bd mol current` | `ralph status` | Show position in DAG |
| `bd mol bond` | `ralph step` | Attach discovered work |
| `bd mol stale` | `ralph status` | Warn about orphaned molecules |

**Not used by Ralph** (user calls directly):
- `bd mol squash` — User decides when to archive
- `bd mol burn` — User decides when to abandon

## Success Criteria

- [ ] `ralph plan -n <label>` creates new spec in `specs/`
- [ ] `ralph plan -h <label>` creates new spec in `state/`
- [ ] `ralph plan -u <label>` validates spec exists before updating
- [ ] `ralph plan -u <label>` writes NEW requirements to `state/<label>.md`
- [ ] `ralph plan -u -h <label>` updates hidden spec
- [ ] `ralph plan` runs Claude in wrapix container with base profile
- [ ] `ralph ready` creates molecule and stores ID in current.json
- [ ] `ralph ready` (new mode) creates tasks from `specs/<label>.md`
- [ ] `ralph ready` (update mode) reads NEW requirements from `state/<label>.md`
- [ ] `ralph ready` (update mode) creates tasks ONLY for new requirements
- [ ] `ralph ready` (update mode) merges `state/<label>.md` into `specs/<label>.md`
- [ ] `ralph ready` (update mode) deletes `state/<label>.md` after merge
- [ ] `ralph ready` runs Claude in wrapix container with base profile
- [ ] `ralph ready` LLM assigns `profile:X` labels per-task based on implementation needs
- [ ] `ralph step` reads `profile:X` label from bead and uses that profile
- [ ] `ralph step --profile=X` overrides bead profile label
- [ ] `ralph step` falls back to base profile when no label present
- [ ] `ralph step` completes single issues with blocked-vs-waiting guidance
- [ ] `ralph loop` runs on host, spawning containerized `ralph step` per issue
- [ ] `ralph check` validates all templates and partials
- [ ] `ralph tune` (interactive) identifies correct template and makes edits
- [ ] `ralph tune` (integration) ingests diff and interviews about changes
- [ ] `ralph diff` shows local template changes vs packaged
- [ ] `ralph sync` updates templates and backs up customizations
- [ ] `ralph sync --dry-run` previews without executing
- [ ] `nix flake check` includes template validation
- [ ] Templates use Nix-native definitions with static validation
- [ ] Partials work via `{{> partial-name}}` markers

## Out of Scope

- Multi-feature parallel work
- Automated testing integration
- PR creation automation
- Formula-based workflows (Ralph uses specs, not formulas)
- Cross-repo automation for template propagation (manual diff + tune)
