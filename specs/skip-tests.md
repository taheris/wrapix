# Skip Tests: Audit and Fix Test Skip Hygiene

Reduce illegitimate test skips, standardize exit codes, and ensure test runners provide required dependencies.

## Problem Statement

The test suite has ~90 skip points. Many are legitimate (platform-specific tests on the wrong platform), but roughly half are illegitimate — tests skipping because the test runner doesn't provide binaries or environment variables that are available in the project. These illegitimate skips exit 0, making them invisible to CI: a "passing" test suite may be silently skipping dozens of tests.

Specific problems:
- **Exit code 0 for skips** — CI cannot distinguish "passed" from "skipped"
- **Missing binaries** — `ralph-spec`, `nix`, `tmux`, `podman`, `jq`, `bd`, `ralph-run` not in test runner PATH when they should be
- **Missing env vars** — `RALPH_METADATA_DIR` not set when test runner should provide it
- **Stale skip guards** — `has_ralph_spec` check skips 18 tests for a command that exists and is in PATH
- **No convention** — No standard exit code for "skipped" vs "not yet implemented"

## Requirements

### Functional Requirements

#### FR1: Exit Code Convention

Standardize test exit codes across all test files:

| Exit Code | Meaning | When to Use |
|-----------|---------|-------------|
| 0 | Pass | Test ran and succeeded |
| 1 | Fail | Test ran and failed |
| 77 | Skip | Test cannot run on this platform/environment (legitimate) |
| 78 | Not Yet Implemented | Test exists for a feature that hasn't been built yet |

Platform checks (Darwin/Linux, macOS version, KVM availability, container system state) use exit 77. Tests for features that genuinely don't exist yet (e.g., `loop.max-iterations`) use exit 78.

#### FR2: Test Infrastructure `test_skip` and `test_not_implemented`

Update `tests/ralph/lib/assertions.sh`:
- `test_skip` should use exit code 77 (not increment a counter and continue)
- Add `test_not_implemented` function that uses exit code 78
- Both should print a clear message to stderr

Update `tests/ralph/lib/runner.sh`:
- `print_test_summary` should report skip (77) and not-implemented (78) counts separately
- Test runner should recognize exit codes 77 and 78 as non-failures

#### FR3: Fix Test Runners to Provide Required Binaries

Ensure test Nix derivations include all required binaries in `nativeBuildInputs` or PATH:

| Test File(s) | Missing Dependency | Fix Location |
|-------------|-------------------|--------------|
| `tests/ralph/test-spec.sh` (18 skips) | `ralph-spec` | `tests/default.nix` ralph integration runner |
| `tests/tmux-mcp/*.sh` (10 skips) | `tmux`, `tmux-debug-mcp` | `tests/tmux-mcp.nix` integration test VM |
| `tests/tmux-mcp/e2e/*.sh` (10 skips) | `nix`, `podman` | `tests/tmux-mcp.nix` e2e test VM |
| `tests/default.nix` test-ralph (2 skips) | `bd`, `ralph-run` | `tests/default.nix` test runner PATH |
| `tests/tmux-mcp/run-integration.sh` (1 skip) | `jq` | `tests/tmux-mcp.nix` integration test VM |
| `tests/notify-test.sh` (1 skip) | notification socket | test runner should start `wrapix-notifyd` or skip is illegitimate |

After fixing, remove the `command -v` guards and `has_ralph_spec` checks from these test files.

#### FR4: Fix Test Runners to Provide Required Environment Variables

| Test File | Missing Env Var | Fix Location |
|-----------|----------------|--------------|
| `tests/ralph/run-tests.sh` (4 skips) | `RALPH_METADATA_DIR` | `tests/default.nix:114` already sets it for integration runner; ensure all test paths use it |

#### FR5: Convert Legitimate Skips to Exit 77

All platform-dependent skips should use exit 77 instead of exit 0:

- Darwin-only tests on Linux (`tests/darwin/*.sh`, `tests/darwin/*.nix`)
- Linux-only tests on Darwin (`tests/smoke.nix`)
- macOS 26+ version checks (`tests/darwin/*.nix`, `tests/builder-test.sh`)
- KVM availability checks (`tests/default.nix`, `tests/tmux-mcp.nix`)
- Container system state checks (`tests/darwin/*.nix`)
- Console user checks (`tests/darwin/*.nix`)
- `bd` upstream limitation skips (`tests/ralph/run-tests.sh` — blocked-by-in_progress filtering, task selection)
- `bd mol bond` runtime conditional skips (`tests/ralph/run-tests.sh`)
- `SKIP_IMAGE_TEST` env var override (`tests/smoke.nix`)

#### FR6: Convert Not-Yet-Implemented Skips to Exit 78

These tests are for features that genuinely don't exist yet. Use exit 78:

| Test | Feature | Location |
|------|---------|----------|
| `loop.max-iterations` | Config option to cap loop iterations | `tests/ralph/run-tests.sh:1735` |
| `loop.pause-on-failure=false` | Config option to continue on step failure | `tests/ralph/run-tests.sh:1847` |
| `failure-patterns` | Custom error pattern detection in output | `tests/ralph/run-tests.sh:2302` |
| `bd mol current position markers` | Ad-hoc epic support in beads | `tests/ralph/run-tests.sh:303` |

#### FR7: Test Runner Summary Reports Skip Breakdown

When test runners report results, they should show:
```
Results: 45 passed, 0 failed, 3 skipped (exit 77), 4 not implemented (exit 78)
```

CI systems can then alert on unexpected skip count changes.

### Non-Functional Requirements

#### NFR1: No Silent Skips

Every skip must print a message explaining why the test was skipped. The message should include what prerequisite is missing and how to provide it.

#### NFR2: Backwards Compatible

Existing `nix flake check` and `nix run .#test` invocations should continue to work. Exit code 77 and 78 should not cause the overall test suite to report failure.

## Affected Files

| File | Changes |
|------|---------|
| `tests/ralph/lib/assertions.sh` | Add `test_not_implemented`, update `test_skip` to use exit 77 |
| `tests/ralph/lib/runner.sh` | Handle exit 77/78 in runner, update summary reporting |
| `tests/default.nix` | Add `ralph-spec` to integration test PATH; fix env var propagation |
| `tests/tmux-mcp.nix` | Ensure `tmux`, `jq`, `tmux-debug-mcp` in integration VM; `nix`, `podman` in e2e VM |
| `tests/ralph/test-spec.sh` | Remove all `has_ralph_spec` guards |
| `tests/ralph/run-tests.sh` | Convert `test_skip` calls to `test_skip`/`test_not_implemented` as appropriate; remove `RALPH_METADATA_DIR` guards |
| `tests/tmux-mcp/test_*.sh` | Remove `command -v tmux` and `command -v tmux-debug-mcp` guards |
| `tests/tmux-mcp/e2e/test_*.sh` | Remove `command -v nix` and `command -v podman` guards |
| `tests/tmux-mcp/run-integration.sh` | Remove `command -v` prerequisite checks |
| `tests/darwin/*.sh` | Change `exit 0` to `exit 77` on platform checks |
| `tests/darwin/*.nix` | Change `exit 0` to `exit 77` on platform/version/container checks |
| `tests/smoke.nix` | Change `exit 0` to `exit 77` on platform checks and SKIP_IMAGE_TEST |
| `tests/builder-test.sh` | Standardize to exit 77 (currently uses exit 1 for platform skip) |
| `tests/notify-test.sh` | Remove socket skip guard or change to exit 77 if daemon truly optional |
| `specs/ralph-tests.md` | Document exit code convention (FR1) |
| `specs/pre-commit.md` | No changes needed (hooks don't use skip convention) |

## Success Criteria

- [ ] All test skips use exit 77 (platform) or exit 78 (not implemented), never exit 0
  [verify](tests/ralph/run-tests.sh::test_skip_exit_codes)
- [ ] `ralph-spec` tests in `test-spec.sh` run without skipping (18 tests fixed)
  [verify](tests/ralph/test-spec.sh::test_spec_annotation_counts)
- [ ] `test_skip` function in assertions.sh produces exit code 77
  [verify](tests/ralph/run-tests.sh::test_skip_exit_codes)
- [ ] `test_not_implemented` function exists and produces exit code 78
  [verify](tests/ralph/run-tests.sh::test_skip_exit_codes)
- [ ] Test summary distinguishes passed/failed/skipped/not-implemented counts
  [judge](tests/judges/skip-tests.sh::test_summary_format)
- [ ] No test file uses `exit 0` to indicate a skip
  [verify](tests/ralph/run-tests.sh::test_no_exit_0_skips)
- [ ] Binary availability guards removed from tests where binaries are provided by runner
  [judge](tests/judges/skip-tests.sh::test_no_illegitimate_skips)
- [ ] `nix flake check` treats exit 77 and 78 as non-failures
  [verify](tests/ralph/run-tests.sh::test_skip_exit_codes)
- [ ] `tests/builder-test.sh` uses exit 77 (not exit 1) for platform skip
  [verify](tests/ralph/run-tests.sh::test_skip_exit_codes)

## Out of Scope

- Changing test logic or assertions (only skip behavior)
- Adding new tests (only fixing existing skip hygiene)
- Fixing upstream `bd` limitations (these remain legitimate skips)
- Notification daemon lifecycle management (just fix the skip code for now)
- CI pipeline configuration (this spec standardizes exit codes; CI config is separate)
