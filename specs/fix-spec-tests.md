# Fix Spec Test Failures

Fix the 53 failing tests reported by `ralph spec --all` across 12 specs.

## Problem Statement

`ralph spec --all` reports 53 failures and 45 passes across 12 specs. The failures fall into distinct root-cause categories, with one infrastructure bug (`runner.sh` trap scoping) responsible for the majority. Fixing these issues is necessary to make the verify/judge pipeline trustworthy and actionable.

## Requirements

### FR1: Fix `run_test_isolated` trap variable scoping (Critical — ~30 failures)

The EXIT trap handler `_rti_write_results()` in `tests/ralph/lib/runner.sh:66` references local variables (`$result_file`, `$test_func`) from its enclosing function `run_test_isolated()`. When the trap fires after the function returns, these locals are out of scope and `set -u` (from the parent shell at `run-tests.sh:5`) causes `result_file: unbound variable`. The result file is never written, which cascades into:

- Exit code 2 for tests invoked via `ralph spec --verify` (spec.sh calls `run-tests.sh <function_name>`, which calls `run_test_isolated`, then tries to `grep` the missing result file)
- Exit code 1 for tests run directly via `run-tests.sh` in parallel/sequential mode (aggregation logic falls through to CRASHED branch)

**Affected tests (all in `run-tests.sh`):**
- test_isolated_beads_db, test_parse_spec_annotations, test_sync_deps_basic
- test_spec_short_flag_v, _j, _a, _s, test_spec_verbose_no_short_v, test_spec_short_compose
- test_spec_nonzero_exit, test_spec_skip_empty
- test_mock_claude_exists, test_default_config_has_hooks, test_render_template_basic
- test_run_closes_issue_on_complete, test_run_no_close_without_signal
- test_run_handles_blocked_signal, test_run_handles_clarify_signal
- test_run_respects_dependencies, test_run_loop_processes_all
- test_parallel_agent_simulation, test_plan_flag_validation
- test_discovered_work, test_config_data_driven

**Fix:** Remove `local` from `result_file`, `test_func`, and `output_file` in `run_test_isolated()`. The function already runs in a subshell (runner.sh lines 156 and 246 wrap it in `(...)`), so global variables won't leak. This ensures the EXIT trap handler can access them after the function returns.

### FR2: Handle exit 77/78 as SKIP in `run_verify_test()`

`spec.sh:run_verify_test()` (line 58) treats any non-zero exit as FAIL. This misreports:
- Exit 77 (skip) — darwin tests on Linux, notify tests without daemon
- Exit 78 (not implemented) — features not yet built

**Fix:** Update `run_verify_test()` to:
- Report exit 77 as `[SKIP]` with reason text from test output, increment `skipped` counter
- Report exit 78 as `[SKIP]` (not implemented) with reason text, increment `skipped` counter
- Only increment `failed` and set `has_failure` for other non-zero exits

### FR3: Create missing `tests/judges/skip-tests.sh`

Two success criteria in `specs/skip-tests.md` reference `tests/judges/skip-tests.sh` which does not exist:

- "Test summary distinguishes passed/failed/skipped/not-implemented counts"
- "Binary availability guards removed from tests where binaries are provided by runner"

**Fix:** Create `tests/judges/skip-tests.sh` with `judge_files` and `judge_criterion` rubrics for both criteria.

### FR4: Run tmux-mcp verify tests inside a wrapix container (8 failures)

The tmux-mcp tests (`tests/tmux-mcp/*.sh`) need `tmux-debug-mcp` and `tmux`, which are provided inside wrapix containers but not on the host. Per the skip-tests spec, tests should not add binary guards — the runner provides dependencies. Since `ralph spec --verify` is the runner here, it needs to provide the environment.

The `wrapix-debug` flake output already includes the right profile (`base` + `mcp.tmux-debug`), so the infrastructure exists. The tmux-mcp tests are testing wrapix container debugging anyway — running them inside a container is the correct execution context.

**Fix:** Extend `run_verify_test()` in `spec.sh` to support container execution:

1. Add a new annotation syntax: `[verify:wrapix](path::function)` — runs the test inside a wrapix container instead of on the host. The container profile is determined by what's needed (e.g., `wrapix-debug` for tmux-mcp tests).

2. When `run_verify_test()` encounters a `:container` annotation:
   - Build/use the appropriate wrapix sandbox (e.g., `nix run .#wrapix-debug`)
   - Copy the test script into the container workspace
   - Execute it inside the container
   - Capture exit code and output as normal

3. Update `[verify]` annotations in `specs/tmux-mcp.md` to use `[verify:wrapix]`.

4. If the container can't be built (nix not available, build fails), the test should **fail with a clear message** explaining why — not skip silently.

**Affected annotations (update to `[verify:wrapix]`):**
- `specs/tmux-mcp.md` — 8 annotations pointing to `tests/tmux-mcp/*.sh`
- `specs/profiles.md` — 1 annotation pointing to `tests/tmux-mcp/e2e/test_profile_composition.sh`

### FR5: Binary-not-found should fail with a message

When a test fails because a required binary is not available, the failure message should clearly state what's missing and how to get it. This applies to any test that fails with exit 127 (command not found) or where the test output indicates a missing binary.

Currently, tests that fail because of missing binaries show generic "exit 1" or "exit 127" with no guidance. The test output already contains the error message (e.g., "Cannot find tmux-debug-mcp binary") but `run_verify_test()` only shows it in `--verbose` mode.

**Fix:** When a verify test fails, always show the last few lines of test output (not just in verbose mode). This ensures the "binary not found" message is visible without requiring `--verbose`. Keep verbose mode for showing full output.

## Affected Files

| File | Change |
|------|--------|
| `tests/ralph/lib/runner.sh` | Fix trap variable scoping in `run_test_isolated()` (FR1) |
| `lib/ralph/cmd/spec.sh` | Handle exit 77/78 as SKIP (FR2); support `[verify:wrapix]` (FR4); show failure output (FR5) |
| `lib/ralph/cmd/util.sh` | Parse `[verify:wrapix]` annotation type (FR4) |
| `tests/judges/skip-tests.sh` | Create with judge rubrics (FR3) |
| `specs/tmux-mcp.md` | Update `[verify]` to `[verify:wrapix]` (FR4) |
| `specs/profiles.md` | Update `[verify]` to `[verify:wrapix]` for profile composition test (FR4) |

## Success Criteria

- [ ] `run_test_isolated()` trap handler correctly writes result files when running in subshells
  [verify](tests/ralph/run-tests.sh::test_mock_claude_exists)
- [ ] `ralph spec --verify` reports exit 77 as `[SKIP]` instead of `[FAIL]`
  [verify](tests/ralph/test-spec.sh::test_spec_verify)
- [ ] `ralph spec --verify` reports exit 78 as `[SKIP]` instead of `[FAIL]`
  [verify](tests/ralph/test-spec.sh::test_spec_verify)
- [ ] `tests/judges/skip-tests.sh` exists and defines rubrics
- [ ] `[verify:wrapix]` annotations run tests inside a wrapix container
- [ ] tmux-mcp verify tests pass when run via `[verify:wrapix]`
- [ ] When a binary is missing, test fails with a message saying what binary and how to build it
- [ ] `ralph spec --verify` shows failure reason on FAIL (not just in verbose mode)
- [ ] `ralph spec --all` failure count drops significantly (remaining = darwin platform skips + legitimate not-implemented)

## Out of Scope

- Fixing actual feature bugs exposed once the test infrastructure works (those are separate issues)
- Changing the test logic for tests that correctly report `exit 78` (not yet implemented)
- Running darwin tests in containers (these genuinely require macOS kernel)
- Fixing `test_config_data_driven` (exit 78) — correctly reporting a not-yet-implemented feature
- General-purpose container execution for all verify tests (only where it makes sense, like tmux-mcp)
