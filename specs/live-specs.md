# Live Specs

Specs become queryable, verifiable, and observable — not just static documentation.

## Problem Statement

Specs in `specs/` are static markdown files. Once written, there's no structured way to ask "does this feature actually work?" or "what needs my attention?" You have to mentally join `bd show`, `git log`, test output, and the spec itself to get a full picture.

Meanwhile, `ralph status` shows molecule progress but not whether the implementation is correct, `ralph logs` shows errors but not what's blocked on human input, and there's no live view when `ralph run` is active.

The "frontend dissolves" insight: instead of building dashboards and status pages, make the spec itself the interface. Queries, verification, and observation are commands that read structured annotations in specs.

## Requirements

### Functional

1. **Spec annotations** — Success criteria in specs support `[verify]` and `[judge]` links:
   ```markdown
   - [ ] Notification appears within 2s
     [verify](tests/notify-test.sh::test_notification_timing)
   - [ ] Clear visibility into current state
     [judge](tests/judges/notify.sh::test_clear_visibility)
   - [ ] Works on both Linux and macOS
   ```
   - `[verify](path::function)` points to a shell test (exit code pass/fail)
   - `[judge](path::function)` points to an LLM evaluation rubric
   - Criteria with no annotation are unannotated
   - Links are clickable in editors and GitHub (standard markdown link syntax)

2. **`ralph spec`** — Fast annotation index across all spec files:
   ```
   Ralph Specs
   ============================
     notifications.md     3 verify, 1 judge, 2 unannotated
     sandbox.md           0 verify, 0 judge, 5 unannotated
     ralph-workflow.md    2 verify, 0 judge, 8 unannotated

   Total: 5 verify, 1 judge, 15 unannotated
   ```
   - Reads spec files and parses annotations; no test execution or LLM calls
   - `--verbose`: expand to per-criterion detail showing each criterion and its annotation type

3. **`ralph spec --verify`** — Run all `[verify]` tests from the current spec's success criteria:
   ```
   Ralph Verify: notifications (wx-q6x)
   ======================================
     [PASS] Notification appears within 2s
            tests/notify-test.sh::test_notification_timing (exit 0)
     [SKIP] Clear visibility into current state (judge only)
     [SKIP] Works on both Linux and macOS (no annotation)

   1 passed, 0 failed, 2 skipped
   ```
   - Runs on the host (user is responsible for having required tools)

4. **`ralph spec --judge`** — Run all `[judge]` evaluations from the current spec's success criteria:
   ```
   Ralph Judge: notifications (wx-q6x)
   =====================================
     [SKIP] Notification appears within 2s (verify only)
     [PASS] Clear visibility into current state
            "ralph status displays progress %, per-issue status,
             and blocked/awaiting indicators"
     [SKIP] Works on both Linux and macOS (no annotation)

   1 passed, 0 failed, 2 skipped
   ```
   - Runs on the host; invokes LLM with source files + criterion

5. **`ralph spec --all`** — Run both verify and judge checks (shorthand for `--verify --judge`).

6. **Judge test infrastructure** — Judge tests live in `tests/judges/` and define rubrics:
   ```bash
   test_clear_visibility() {
     judge_files "lib/ralph/cmd/status.sh"
     judge_criterion "Output includes progress percentage, per-issue status indicators (done/running/blocked/awaiting), and dependency information"
   }
   ```
   - `judge_files` specifies which source files the LLM reads
   - `judge_criterion` specifies what the LLM evaluates
   - The runner invokes an LLM with files + criterion, returns PASS/FAIL + short reasoning

7. **`ralph sync --deps`** — Print required nix packages for verify and judge tests:
   - Scans annotations in the current spec
   - Determines what tools/packages the test files need
   - Outputs a list suitable for `nix shell` or profile construction

8. **`ralph status --watch` / `-w`** — Auto-refreshing live view:
   - Top pane: molecule progress (refreshes periodically)
   - Bottom pane: live tail of agent output if `ralph run` is active
   - Works standalone (shows status + recent activity even when nothing is running)
   - Uses tmux split for layout
   - **Requires tmux** — errors with a clear message if not in a tmux session
   - Individual underlying commands (`ralph status`, `ralph logs`) remain usable outside tmux

9. **Awaiting input convention** — Tracker-agnostic label for human-blocked items:
   - When agent emits `RALPH_CLARIFY`, orchestrator adds `awaiting:input` label to bead
   - Question stored in bead notes
   - `ralph status` surfaces awaiting items distinctly:
     ```
     [awaiting] wx-q6x-10  Cross-platform CI
                  "Should CI use GitHub Actions or Buildkite?" (2h ago)
     ```
   - `ralph run` skips beads with `awaiting:input` label (not truly ready)
   - Human answers, removes label, bead becomes ready again
   - Convention works with any tracker that supports labels/tags

### Non-Functional

1. **Fast default** — `ralph spec` and `ralph status` with no flags must be instant (no tests, no LLM calls)
2. **Clickable links** — `[verify]` and `[judge]` annotations use standard markdown link syntax, rendering as clickable links in GitHub, VS Code, and terminal markdown viewers
3. **Tracker-agnostic** — `awaiting:input` convention uses labels, not custom status fields, so it works with any issue tracker
4. **Parseable annotations** — `[verify](path::fn)` and `[judge](path::fn)` patterns are easy to extract programmatically from spec markdown
5. **Host execution** — `ralph spec --verify` and `ralph spec --judge` run on the host, not in wrapix containers; users are responsible for having required tools available (use `ralph sync --deps` to check)

## Design

### Annotation parsing

Scan success criteria sections for `[verify](...)` and `[judge](...)` links on lines following `- [ ]` or `- [x]` items. Extract path and optional function name from the link target (split on `::`).

### Verify runner

For each `[verify]` annotation:
- Parse `path::function` from the link
- If function specified: invoke the test file with the function name as argument
- If file only: run the entire test file
- PASS on exit 0, FAIL on non-zero
- Capture stdout/stderr for the report

### Judge runner

For each `[judge]` annotation:
- Parse `path::function` from the link
- Source the judge test file and call the function to get `judge_files` and `judge_criterion`
- Read the specified source files
- Invoke LLM with: source file contents + criterion text
- LLM returns PASS/FAIL + short reasoning
- Display reasoning in output

### Watch mode

- Create tmux split: top pane runs `watch -n5 ralph status`, bottom pane tails agent log
- If no active `ralph run` session: bottom pane shows recent git log + last errors
- Standalone-capable: useful even when nothing is running
- Errors immediately if `$TMUX` is not set

### Awaiting input flow

```
ralph run (orchestrator)
  → agent emits RALPH_CLARIFY: "question text"
  → orchestrator: bd update <id> --labels "awaiting:input"
  → orchestrator: bd update <id> --notes "Question: <text>"
  → orchestrator skips this bead in future iterations
  → human: bd update <id> --labels "-awaiting:input"
  → human: bd update <id> --notes "Answer: <text>"
  → bead becomes ready again
```

## Command Summary

Updated `ralph` command structure with live-specs additions:

```
Spec-Driven Workflow Commands:
  plan            (unchanged)
  todo            (unchanged)
  run             Execute work items (+ awaiting:input handling)
    --once/-1       Execute single issue then exit
    --profile=X     Override container profile
  status          Show current workflow state
    --watch/-w      Live tmux view (requires tmux)
  spec            Query spec annotations
    --verify        Run [verify] shell tests
    --judge         Run [judge] LLM evaluations
    --all           Run both verify and judge
    --verbose       Show per-criterion detail

Template Commands:
  check           (unchanged)
  sync            Update local templates from packaged
    --diff          Show local template changes vs packaged
    --deps          Show required nix packages for verify/judge tests
  tune            (unchanged)

Utility Commands:
  logs            (unchanged, extended independently)
  edit            (unchanged)
```

## Affected Files

| File | Role |
|------|------|
| `lib/ralph/cmd/ralph.sh` | Add `spec` subcommand dispatch |
| `lib/ralph/cmd/spec.sh` | New: annotation parsing, verify/judge runners, index display |
| `lib/ralph/cmd/status.sh` | Add `--watch` flag, surface awaiting items in default output |
| `lib/ralph/cmd/run.sh` | Awaiting:input label handling in orchestrator loop |
| `lib/ralph/cmd/sync.sh` | Add `--deps` flag |
| `lib/ralph/cmd/util.sh` | Annotation parsing helpers, judge runner utilities |
| `specs/*.md` | Add `[verify]` and `[judge]` annotations to existing success criteria |
| `tests/judges/` | New directory for judge rubric test files |

## Success Criteria

- [ ] `[verify]` and `[judge]` annotations parse correctly from spec success criteria
- [ ] `ralph spec` lists all spec files with annotation counts (verify/judge/unannotated)
- [ ] `ralph spec --verbose` shows per-criterion detail
- [ ] `ralph spec --verify` runs shell tests and reports PASS/FAIL/SKIP
- [ ] `ralph spec --judge` invokes LLM with rubric and reports PASS/FAIL/SKIP
- [ ] `ralph spec --all` runs both verify and judge
- [ ] Criteria with no annotation show as SKIP in verify/judge output
- [ ] `ralph spec` and `ralph status` with no flags remain instant (no test/LLM execution)
- [ ] `ralph status --watch` creates tmux split with auto-refresh
- [ ] `ralph status --watch` errors clearly when not in tmux
- [ ] `ralph status --watch` works standalone (no active ralph run required)
- [ ] `RALPH_CLARIFY` in orchestrator adds `awaiting:input` label to bead
- [ ] `ralph run` skips beads with `awaiting:input` label
- [ ] `ralph status` displays awaiting items with question text and age
- [ ] Judge test files define rubrics via `judge_files` and `judge_criterion`
- [ ] `ralph sync --deps` lists required nix packages for current spec's tests
- [ ] Annotations are clickable links in GitHub and VS Code

## Out of Scope

- Deprecating `ralph logs` (stays as-is, extended independently)
- Auto-updating `- [ ]` to `- [x]` in specs based on verify/judge results
- Web-based dashboard or GUI
- Cross-spec verification (verify one spec at a time)
- Judge model selection (use whatever model ralph is configured with)
- Running verify/judge inside wrapix containers (host execution only)
