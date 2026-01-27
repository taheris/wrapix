# Ralph Integration Tests

Integration tests for the ralph workflow with unified test infrastructure.

## Problem Statement

The ralph workflow orchestrates AI-driven feature development but lacks automated tests. Manual testing is slow and doesn't catch regressions. Additionally, existing test targets (`.#test-darwin`, `.#test-integration`) are fragmented and don't include ralph coverage.

## Requirements

### Functional

1. **Unified test command** — `nix run .#test` runs all tests:
   - Existing darwin tests (skipped on non-darwin)
   - Existing integration tests
   - New ralph integration tests

2. **Mock Claude interface** — Tests use a mock `claude` executable that:
   - Receives prompts via command-line arguments
   - Reads scenario files to determine responses
   - Executes side effects (creates files, runs `bd` commands)
   - Outputs responses with appropriate exit signals

3. **Scenario-driven tests** — Each test case defines:
   - Initial state (label, spec content if applicable)
   - Mock responses for each phase
   - Expected end state (files, beads issues, exit codes)

4. **Full workflow coverage** — Tests verify:
   - `ralph plan <label>` creates spec file with `RALPH_COMPLETE` signal
   - `ralph ready` creates beads issues with correct dependencies
   - `ralph step` works issues in dependency order
   - `ralph loop` processes all issues until complete

5. **Parallel agent simulation** — Tests verify coordination:
   - `step` marks issue `in_progress` before starting work
   - Subsequent `step` (simulated) skips in_progress items
   - Subsequent `step` skips items blocked by in_progress dependencies

6. **Error handling** — Tests verify:
   - Missing exit signal (no `RALPH_COMPLETE`) — step does not close issue
   - `RALPH_BLOCKED: reason` signal — workflow pauses appropriately
   - Invalid beads JSON output — graceful handling
   - Partial completion — epic remains open when tasks remain

7. **Merge start into plan** — Combine `ralph start` and `ralph plan`:
   - `ralph plan <label>` does setup AND interview
   - Remove `ralph start` as separate command
   - Setup steps are idempotent (safe to rerun)

8. **Implementation Notes section** — Support transient context in specs:
   - Specs may contain `## Implementation Notes` section
   - This section is available during `ralph ready` for context when creating beads
   - Section is stripped when spec is finalized to `specs/<feature>.md`
   - Useful for capturing bugs, gotchas, and implementation hints that don't belong in permanent docs

### Non-Functional

1. **Deterministic** — Tests produce consistent results (no real API calls)
2. **Fast** — Mock responses are instant, no network latency
3. **Isolated** — Each test runs in clean temporary directory
4. **Skip-aware** — Darwin tests skip gracefully on Linux
5. **Clean beads** — Tests use isolated beads database, no test beads persist after run

## Affected Files

| File | Change |
|------|--------|
| `lib/ralph/cmd/start.sh` | Remove (merge into plan.sh) |
| `lib/ralph/cmd/plan.sh` | Absorb start.sh logic |
| `lib/ralph/cmd/ralph.sh` | Remove `start` command routing |
| `specs/ralph-workflow.md` | Update to reflect merged command |
| `flake.nix` | Add `.#test` that combines all test targets |

### Test Directory Reorganization

Move darwin tests into `tests/darwin/`:
| From | To |
|------|-----|
| `tests/darwin-network-test.sh` | `tests/darwin/network-test.sh` |
| `tests/darwin-mount-test.sh` | `tests/darwin/mount-test.sh` |
| `tests/darwin-mounts.nix` | `tests/darwin/mounts.nix` |
| `tests/darwin-network.nix` | `tests/darwin/network.nix` |
| `tests/darwin.nix` | `tests/darwin/default.nix` |

New ralph test files in `tests/ralph/`:
| File | Purpose |
|------|---------|
| `tests/ralph/default.nix` | Nix test derivation |
| `tests/ralph/mock-claude` | Mock claude executable |
| `tests/ralph/scenarios/` | Test scenario definitions |
| `tests/ralph/run-tests.sh` | Test harness script |

## Mock Claude Design

### Mock Executable

```bash
#!/usr/bin/env bash
# mock-claude - receives prompt, returns scenario-defined response

SCENARIO_FILE="${MOCK_SCENARIO:-}"
PROMPT="$*"

# Read scenario, match phase, execute side effects, output response
```

### Scenario File Format

```bash
# scenarios/happy-path.sh

phase_plan() {
  # Create spec file
  cat > "$SPEC_PATH" << 'EOF'
# Test Feature
...
EOF
  echo "RALPH_COMPLETE"
}

phase_ready() {
  # Create beads issues
  bd create --title="Task 1" --type=task --labels="spec-$LABEL"
  bd create --title="Task 2" --type=task --labels="spec-$LABEL"
  bd dep add beads-002 beads-001
  echo "RALPH_COMPLETE"
}

phase_step() {
  # Implement and signal completion
  echo "Implemented the feature"
  echo "RALPH_COMPLETE"
}
```

### Phase Detection

Mock determines current phase from:
- Prompt content patterns (e.g., "spec interview" → plan)
- Environment variables set by ralph
- Scenario file state

## Test Cases

### Happy Path

1. `ralph plan test-feature` — creates spec, signals complete
2. `ralph ready` — creates epic + tasks with dependencies
3. `ralph step` — completes first unblocked task
4. `ralph loop` — completes remaining tasks, closes epic

### Parallel Simulation

1. Run `ralph step` — marks task A as `in_progress`
2. Simulate second agent state check — task B (no deps) available, task C (depends on A) blocked
3. Verify task selection logic

### Config Behavior

1. **spec.hidden = true** — spec file created in `state/` instead of `specs/`, README not updated
2. **spec.hidden = false** — spec file created in `specs/`, README updated with WIP entry
3. **beads.priority** — issues created with configured priority (test with priority=1 vs priority=3)
4. **loop.max-iterations** — loop stops after N iterations even if work remains
5. **loop.pause-on-failure = true** — loop pauses when step fails
6. **loop.pause-on-failure = false** — loop continues after step failure
7. **loop.pre-hook / post-hook** — hooks execute before/after each iteration
8. **failure-patterns** — custom patterns trigger configured actions (log/pause)

### Error Scenarios

1. **No completion signal** — `step` runs, mock omits `RALPH_COMPLETE`, verify issue stays open
2. **RALPH_BLOCKED signal** — mock returns `RALPH_BLOCKED: needs API key`, verify workflow pauses
3. **Malformed bd output** — `bd list` returns warning + JSON, verify parsing succeeds
4. **Partial epic** — close 2 of 3 tasks, verify epic stays open

## Success Criteria

- [ ] `nix run .#test` runs all tests (darwin, integration, ralph)
- [ ] Darwin tests skip gracefully on Linux
- [ ] Ralph tests pass with mock claude (no real API calls)
- [ ] `ralph plan <label>` replaces `ralph start` + `ralph plan`
- [ ] Tests verify dependency-ordered task execution
- [ ] Tests verify in_progress exclusion for parallel agents
- [ ] Tests verify error handling (missing signals, RALPH_BLOCKED, bad JSON)
- [ ] Tests verify config options affect behavior (spec.hidden, beads.priority, loop settings)
- [ ] Tests are deterministic and fast

## Out of Scope

- Actual Claude API integration tests
- Performance benchmarking
- UI/UX improvements to ralph commands
- Changes to beads functionality
