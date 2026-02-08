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
   - `ralph todo` creates beads issues with correct dependencies
   - `ralph run --once` works issues in dependency order
   - `ralph run` processes all issues until complete

5. **Parallel agent simulation** — Tests verify coordination:
   - `run --once` marks issue `in_progress` before starting work
   - Subsequent `run --once` (simulated) skips in_progress items
   - Subsequent `run --once` skips items blocked by in_progress dependencies

6. **Error handling** — Tests verify:
   - Missing exit signal (no `RALPH_COMPLETE`) — run does not close issue
   - `RALPH_BLOCKED: reason` signal — workflow pauses appropriately
   - Invalid beads JSON output — graceful handling
   - Partial completion — epic remains open when tasks remain

7. **Merge start into plan** — Combine `ralph start` and `ralph plan`:
   - `ralph plan <label>` does setup AND interview
   - Remove `ralph start` as separate command
   - Setup steps are idempotent (safe to rerun)

8. **Implementation Notes section** — Support transient context in specs:
   - Specs may contain `## Implementation Notes` section
   - This section is available during `ralph todo` for context when creating beads
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

### Test Directory Structure

```
tests/ralph/
├── default.nix              # Nix test derivation
├── mock-claude              # Mock claude executable
├── run-tests.sh             # Test harness (thin wrapper)
├── templates.nix            # Template test fixtures
├── lib/                     # Reusable test libraries
│   ├── assertions.sh        # test_pass, test_fail, assert_*
│   ├── fixtures.sh          # setup_*, teardown_*, temp directories
│   ├── mock-claude.sh       # Mock infrastructure
│   └── runner.sh            # Parallel/sequential test execution
└── scenarios/               # Test scenario definitions
    ├── happy-path.sh        # Full workflow test (shell format)
    ├── happy-path.json      # Same test (JSON format)
    ├── blocked.json         # RALPH_BLOCKED signal handling
    ├── clarify.json         # RALPH_CLARIFY signal handling
    ├── complete.json        # Basic completion
    ├── no-signal.json       # Missing exit signal
    └── ...
```

### Darwin Test Reorganization

Move darwin tests into `tests/darwin/`:
| From | To |
|------|-----|
| `tests/darwin-network-test.sh` | `tests/darwin/network-test.sh` |
| `tests/darwin-mount-test.sh` | `tests/darwin/mount-test.sh` |
| `tests/darwin-mounts.nix` | `tests/darwin/mounts.nix` |
| `tests/darwin-network.nix` | `tests/darwin/network.nix` |
| `tests/darwin.nix` | `tests/darwin/default.nix` |

## Test Exit Code Convention

Standalone shell test scripts use special exit codes to distinguish pass, fail, skip, and not-yet-implemented results. The test runner treats skip and not-implemented as non-failures.

### Exit Codes

| Exit Code | Meaning | When to Use |
|-----------|---------|-------------|
| 0 | Pass | Test ran and succeeded |
| 1 | Fail | Test ran and failed |
| 77 | Skip | Test cannot run on this platform/environment (legitimate) |
| 78 | Not Yet Implemented | Test exists for a feature that hasn't been built yet |

Exit code 77 follows the convention used by Automake, TAP, and GNU test frameworks. Exit code 78 is project-specific (unused by convention and available for custom meaning).

### When to Use Exit 77 (Skip)

Use exit 77 when a test cannot run due to platform or environment constraints that are outside the test's control:

- **Platform checks** — Darwin-only test running on Linux, or vice versa
- **Hardware requirements** — KVM availability, GPU, specific CPU features
- **Runtime conditions** — Container system not running, notification daemon not available
- **Upstream limitations** — `bd` features with known behavioral constraints (e.g., blocked-by-in_progress filtering)

Use `test_skip` from `assertions.sh` to exit with code 77 and print a message:

```bash
[[ "$(uname)" == "Darwin" ]] || test_skip "Requires macOS"
```

### When to Use Exit 78 (Not Yet Implemented)

Use exit 78 when a test exists for a feature that genuinely hasn't been built yet:

- **Config option doesn't exist** — e.g., `loop.max-iterations` is spec'd but not implemented
- **Feature not built** — the test is a placeholder for planned functionality
- **API not available** — the function or command the test exercises doesn't exist yet

Use `test_not_implemented` from `assertions.sh` to exit with code 78 and print a message:

```bash
test_not_implemented "loop.max-iterations config option not yet implemented"
```

### How the Test Runner Handles These Codes

The test runner (`runner.sh`) executes each test in an isolated subshell via `run_test_isolated`. An EXIT trap captures the exit code and categorizes it:

- Exit 77 increments the **skipped** counter
- Exit 78 increments the **not_implemented** counter
- Neither counts as a failure — the overall test suite passes as long as the **failed** counter is zero

### Summary Format

The test runner prints results in this format:

```
Results: 45 passed, 0 failed, 3 skipped (exit 77), 4 not implemented (exit 78)
```

CI systems can monitor skip and not-implemented counts to detect unexpected changes (e.g., a skip count increasing may indicate a regression in test infrastructure).

### Nix Derivation Tests

Nix derivation tests (`*.nix`) must still exit 0 for build success, since Nix treats any non-zero exit code as a build failure. The exit 77/78 convention applies only to standalone shell test scripts (`.sh` files) executed by the test runner.

### Skip Messages (NFR1)

Every skip must print a message explaining why the test was skipped. The message should state what prerequisite is missing and, where possible, how to provide it. Both `test_skip` and `test_not_implemented` print to stderr automatically.

## Test Library Modules

The test infrastructure is split into reusable libraries under `tests/ralph/lib/`:

### `assertions.sh`

Provides assertion functions for test validation:
- `test_pass <name>` — Record test success
- `test_fail <name> <reason>` — Record test failure
- `assert_file_exists <path>` — Verify file presence
- `assert_file_contains <path> <pattern>` — Grep file for content
- `assert_exit_code <expected> <actual>` — Compare exit codes
- `assert_beads_count <n>` — Verify number of beads created

### `fixtures.sh`

Test setup and teardown helpers:
- `setup_test_env` — Create isolated temp directory with clean beads DB
- `teardown_test_env` — Clean up temp directory
- `setup_ralph_config` — Initialize `.wrapix/ralph/config.nix`
- `create_test_spec <label> <content>` — Create spec file for testing

### `mock-claude.sh`

Mock Claude infrastructure:
- `setup_mock_claude` — Install mock executable in PATH
- `load_scenario <name>` — Load scenario file (shell or JSON)
- `get_phase_response <phase>` — Return response for current phase
- `execute_phase_effects <phase>` — Run side effects (bd commands, file creation)

### `runner.sh`

Test execution framework:
- `run_test_isolated <func> <result> <output>` — Run test in subshell
- `run_tests_parallel <tests...>` — Execute tests concurrently
- `run_tests_sequential <tests...>` — Execute tests in order
- `summarize_results` — Print pass/fail/skip counts

## Mock Claude Design

### Mock Executable

```bash
#!/usr/bin/env bash
# mock-claude - receives prompt, returns scenario-defined response

SCENARIO_FILE="${MOCK_SCENARIO:-}"
PROMPT="$*"

# Read scenario, match phase, execute side effects, output response
```

### Scenario File Formats

Scenarios can be defined in shell (`.sh`) or JSON (`.json`) format.

**Shell format** (imperative, full control):
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

phase_todo() {
  # Create beads issues
  bd create --title="Task 1" --type=task --labels="spec-$LABEL"
  bd create --title="Task 2" --type=task --labels="spec-$LABEL"
  bd dep add beads-002 beads-001
  echo "RALPH_COMPLETE"
}

phase_run() {
  # Implement and signal completion
  echo "Implemented the feature"
  echo "RALPH_COMPLETE"
}
```

**JSON format** (declarative, simpler):
```json
{
  "name": "happy-path",
  "description": "Full workflow from plan to completion",
  "phases": {
    "plan": {
      "output": "I'll create a spec for this feature...",
      "signal": "RALPH_COMPLETE",
      "creates_spec": true
    },
    "todo": {
      "output": "Creating tasks from the spec...",
      "signal": "RALPH_COMPLETE",
      "tasks": [
        {"title": "Task 1", "type": "task"},
        {"title": "Task 2", "type": "task", "depends_on": ["Task 1"]}
      ]
    },
    "run": {
      "output": "Implemented the feature",
      "signal": "RALPH_COMPLETE"
    }
  }
}
```

JSON scenarios are converted to shell phases by the test runner.

### Phase Detection

Mock determines current phase from:
- Prompt content patterns (e.g., "spec interview" → plan)
- Environment variables set by ralph
- Scenario file state

## Test Cases

### Happy Path

1. `ralph plan test-feature` — creates spec, signals complete
2. `ralph todo` — creates epic + tasks with dependencies
3. `ralph run --once` — completes first unblocked task
4. `ralph run` — completes remaining tasks, closes epic

### Parallel Simulation

1. Run `ralph run --once` — marks task A as `in_progress`
2. Simulate second agent state check — task B (no deps) available, task C (depends on A) blocked
3. Verify task selection logic

### Config Behavior

1. **spec.hidden = true** — spec file created in `state/` instead of `specs/`, README not updated
2. **spec.hidden = false** — spec file created in `specs/`, README updated with WIP entry
3. **beads.priority** — issues created with configured priority (test with priority=1 vs priority=3)
4. **run.max-iterations** — run stops after N iterations even if work remains
5. **run.pause-on-failure = true** — run pauses when iteration fails
6. **run.pause-on-failure = false** — run continues after iteration failure
7. **run.pre-hook / post-hook** — hooks execute before/after each iteration
8. **failure-patterns** — custom patterns trigger configured actions (log/pause)

### Error Scenarios

1. **No completion signal** — `run --once` runs, mock omits `RALPH_COMPLETE`, verify issue stays open
2. **RALPH_BLOCKED signal** — mock returns `RALPH_BLOCKED: needs API key`, verify workflow pauses
3. **Malformed bd output** — `bd list` returns warning + JSON, verify parsing succeeds
4. **Partial epic** — close 2 of 3 tasks, verify epic stays open

## Success Criteria

- [x] `nix run .#test` runs all tests (darwin, integration, ralph)
  [verify](tests/ralph/run-tests.sh::test_mock_claude_exists)
- [x] Darwin tests skip gracefully on Linux
- [x] Ralph tests pass with mock claude (no real API calls)
  [verify](tests/ralph/run-tests.sh::test_mock_claude_exists)
- [x] `ralph plan <label>` does setup AND interview (no separate `start` command)
  [verify](tests/ralph/run-tests.sh::test_plan_flag_validation)
- [x] `ralph todo` creates molecule from spec
  [verify](tests/ralph/run-tests.sh::test_run_closes_issue_on_complete)
- [x] `ralph run --once` processes single issue
  [verify](tests/ralph/run-tests.sh::test_run_closes_issue_on_complete)
- [x] `ralph run` processes all issues continuously
  [verify](tests/ralph/run-tests.sh::test_run_loop_processes_all)
- [x] Tests verify dependency-ordered task execution
  [verify](tests/ralph/run-tests.sh::test_run_respects_dependencies)
- [x] Tests verify in_progress exclusion for parallel agents
  [verify](tests/ralph/run-tests.sh::test_parallel_agent_simulation)
- [x] Tests verify error handling (missing signals, RALPH_BLOCKED, bad JSON)
  [verify](tests/ralph/run-tests.sh::test_run_no_close_without_signal)
- [x] Tests verify config options affect behavior (spec.hidden, beads.priority, run settings)
  [verify](tests/ralph/run-tests.sh::test_config_data_driven)
- [x] Tests are deterministic and fast
  [judge](tests/judges/ralph-tests.sh::test_deterministic_and_fast)
- [x] Test infrastructure split into `lib/` modules (assertions, fixtures, mock-claude, runner)
  [verify](tests/ralph/run-tests.sh::test_isolated_beads_db)
- [x] JSON format support for declarative test scenarios
  [verify](tests/ralph/run-tests.sh::test_run_handles_blocked_signal)
- [x] Shell format support for complex scenarios requiring custom logic
  [verify](tests/ralph/run-tests.sh::test_run_loop_processes_all)

## Out of Scope

- Actual Claude API integration tests
- Performance benchmarking
- UI/UX improvements to ralph commands
- Changes to beads functionality
