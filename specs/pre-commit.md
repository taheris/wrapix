# Pre-commit Hooks and Ralph Run Integration

Unified hook system for git workflow validation and ralph run automation.

## Problem Statement

Current state:
- ~~Basic prek setup exists but lacks stage separation (fast vs slow checks)~~ Done
- Ralph loop hooks (`pre-hook`, `post-hook`) defined in config but not implemented
- LLMs may skip quality gates defined in templates
- No enforcement mechanism for tests/linting between steps
- "Land the plane" protocol is manual and error-prone

### Hook Ownership

prek owns all `.git/hooks/` shims. Beads (bd) hooks run as prek-managed local hooks
in `.pre-commit-config.yaml` via `bd hooks run <stage>`. The `.git/hooks/` directory
is `chmod 555` to prevent `bd hooks install` from overwriting prek's shims.

To update hooks:
```bash
chmod 755 .git/hooks/ && prek install -f && chmod 555 .git/hooks/
```

## Requirements

### Functional Requirements

#### FR1: prek Stage Separation

Configure `.pre-commit-config.yaml` with staged hooks:

| Stage | Hooks | Purpose |
|-------|-------|---------|
| pre-commit | bd sync, nixfmt, shellcheck, builtin hooks | Fast validation on every commit |
| prepare-commit-msg | bd agent trailers | Add agent identity to commits |
| post-checkout | bd import | Import JSONL after branch switch |
| post-merge | bd import | Import JSONL after pull/merge |
| pre-push | bd stale check, nix flake check, tests | Slow validation before sharing |

Builtin hooks to add:
- `trailing-whitespace`
- `end-of-file-fixer`
- `check-merge-conflict`

#### FR2: Ralph Run Hook Points

Implement four hook points in ralph run:

```
ralph run [feature]
├── [pre-loop]     → Before any work starts
│
├── while has_work:
│   ├── [pre-step]  → Before each step
│   ├── step        → Claude works on one bead
│   └── [post-step] → After each step
│
└── [post-loop]     → After all work complete
```

#### FR3: Hook Configuration Schema

Update `config.nix` with simplified hook structure:

```nix
{
  hooks = {
    pre-loop = "prek run";
    pre-step = "bd sync";
    post-step = "prek run && git add -A && bd sync";
    post-loop = ''
      bd sync
      git diff --quiet || { echo "Error: worktree is dirty; commit or stash before pushing" >&2; exit 1; }
    '';
  };

  hooks-on-failure = "block";  # block | warn | skip
}
```

#### FR4: Template Variable Substitution

Hooks support these variables:

| Variable | Description | Available In |
|----------|-------------|--------------|
| `{{LABEL}}` | Feature label | All hooks |
| `{{ISSUE_ID}}` | Current bead ID | pre-step, post-step |
| `{{STEP_COUNT}}` | Current iteration number | pre-step, post-step |
| `{{STEP_EXIT_CODE}}` | Exit code from ralph-step | post-step only |

#### FR5: Failure Handling

`hooks-on-failure` options:

| Action | Behavior |
|--------|----------|
| `block` | Stop loop, exit with error code |
| `warn` | Log warning to stderr, continue |
| `skip` | Silently continue |

Default: `block` (fail fast, require human intervention)

#### FR6: Step Template Update

Update `step.md` to reference hook enforcement:

```markdown
## Quality Gates
Before outputting RALPH_COMPLETE:
- [ ] Tests written and passing
- [ ] Lint checks pass
- [ ] Changes staged (`git add`)

Post-step hooks verify compliance automatically.
```

### Non-Functional Requirements

#### NFR1: Consumer Repo Assumptions

- Wrapix is a library; consumer repos have their own test setups
- Assume consumer repos have prek installed and configured
- Default hooks use `prek run`, not repo-specific test commands

#### NFR2: LLM-Friendly Output

Consumer repos should configure their test runners with quiet mode for LLM environments:
- Default: Show only failures
- `--verbose` flag: Full output for human operators
- Detection via `RALPH_MODE` environment variable (optional)

## Affected Files

| File | Changes |
|------|---------|
| `.pre-commit-config.yaml` | Add stages, builtin hooks |
| `lib/ralph/cmd/run.sh` | Implement hook execution |
| `lib/ralph/template/config.nix` | New hooks schema |
| `lib/ralph/template/step.md` | Update quality gates section |
| `tests/ralph/run-tests.sh` | Update hook tests (remove skip) |
| `tests/ralph/scenarios/hook-test.sh` | Expand test coverage |

## Success Criteria

- [ ] `prek run` executes only fast hooks; slow hooks run on `git push`
  [judge](tests/judges/pre-commit.sh::test_prek_hook_speed_split)
- [ ] Ralph loop executes hooks at all four points
  [verify](tests/ralph/run-tests.sh::test_default_config_has_hooks)
- [ ] Loop pauses on hook failure when `hooks-on-failure = "block"`
  [verify](tests/ralph/run-tests.sh::test_config_data_driven)
- [ ] Existing tests pass; hook tests no longer skipped
  [verify](tests/ralph/run-tests.sh::test_default_config_has_hooks)
- [ ] Template variables substituted correctly in hook commands
  [verify](tests/ralph/run-tests.sh::test_render_template_basic)

## Out of Scope

- Custom per-feature hook overrides (use config.nix)
- Hook retry logic (may add later)
- Parallel hook execution
- Test runner quiet mode implementation (repo-specific)
