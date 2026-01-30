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

### Non-Functional

1. **Context Efficiency** — Each step starts with minimal, focused context
2. **Resumable** — Work can stop and resume across sessions
3. **Observable** — Clear visibility into current state and progress via molecules
4. **Validated** — Templates statically checked at build time and after edits

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
- Runs spec interview using appropriate template
- Outputs `RALPH_COMPLETE` when done

### `ralph ready`

```bash
ralph ready
```

Reads `state/current.json` to determine mode:
- **New spec**: Creates molecule (epic + child issues)
- **Update mode**: Loads existing molecule, diffs spec to find new work, bonds new tasks

Stores molecule ID in `state/current.json`.

### `ralph step`

```bash
ralph step
```

- Selects next ready issue from molecule
- Loads step template with issue context
- Implements in fresh Claude session
- Updates issue status on completion

### `ralph loop`

```bash
ralph loop
```

- Runs `ralph step` repeatedly until all issues complete
- Uses project sandbox configuration (see Project Configuration)
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
| `SPEC_CONTENT` | Read from spec file | ready-*, step |
| `EXISTING_SPEC` | Read from existing spec | plan-update |
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

Projects configure ralph via `.ralph/config.nix`:

```nix
# .ralph/config.nix
{
  # Sandbox flake reference (for ralph loop)
  sandbox = ".#packages.x86_64-linux.default";

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
  sandbox = null;           # Error if ralph loop needs it
  pinnedContext = ./specs/README.md;
  specDir = ./specs;
  stateDir = ./state;
  templateDir = null;       # Use packaged templates only
}
```

**Template loading order:**
1. Check `templateDir` (local overlay) first
2. Fall back to packaged templates

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
2. Planning-only warning — No code, no spec edits during conversation
3. `{{> context-pinning}}`
4. `{{> spec-header}}`
5. Existing spec display — Show current spec for reference
6. Update guidelines — Discuss NEW requirements only
7. Output — Summarize new requirements (ralph ready handles spec update)
8. `{{> exit-signals}}`

**Exit signals:** RALPH_COMPLETE, RALPH_BLOCKED, RALPH_CLARIFY

### ready-new.md

**Purpose:** Convert spec to molecule with tasks

**Required sections:**
1. Role statement — "You are decomposing a specification into tasks"
2. `{{> context-pinning}}`
3. `{{> spec-header}}`
4. Spec content — Full spec to decompose
5. Task breakdown guidelines — Self-contained, ordered by deps, one objective per task
6. Molecule creation — Create epic, child tasks, set dependencies
7. README update — Add molecule ID to specs/README.md
8. `{{> exit-signals}}`

**Exit signals:** RALPH_COMPLETE, RALPH_BLOCKED

### ready-update.md

**Purpose:** Add new tasks to existing molecule

**Required sections:**
1. Role statement — "You are adding tasks to an existing molecule"
2. `{{> context-pinning}}`
3. `{{> spec-header}}`
4. Existing molecule info — ID, current tasks, progress
5. New requirements — From plan-update conversation
6. Task creation — Create tasks, bond to molecule, set dependencies
7. Spec update — Append new requirements to spec file
8. `{{> exit-signals}}`

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
- [ ] `ralph plan -u -h <label>` updates hidden spec
- [ ] `ralph ready` creates molecule and stores ID in current.json
- [ ] `ralph ready` in update mode bonds new tasks to existing molecule
- [ ] `ralph step` completes single issues with blocked-vs-waiting guidance
- [ ] `ralph loop` uses project sandbox from `.ralph/config.nix`
- [ ] `ralph check` validates all templates and partials
- [ ] `ralph tune` (interactive) identifies correct template and makes edits
- [ ] `ralph tune` (integration) ingests diff and interviews about changes
- [ ] `ralph diff` shows local template changes vs packaged
- [ ] `nix flake check` includes template validation
- [ ] Templates use Nix-native definitions with static validation
- [ ] Partials work via `{{> partial-name}}` markers

## Out of Scope

- Multi-feature parallel work
- Automated testing integration
- PR creation automation
- Formula-based workflows (Ralph uses specs, not formulas)
- Cross-repo automation for template propagation (manual diff + tune)
