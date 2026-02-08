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
   - Criteria with no annotation show as SKIP
   - Links should be clickable in editors and GitHub

2. **`ralph status --verify`** — Run all `[verify]` tests from the current spec's success criteria:
   ```
   Ralph Verify: notifications (wx-q6x)
   ======================================
     [PASS] Notification appears within 2s
            tests/notify-test.sh::test_notification_timing (exit 0)
     [SKIP] Clear visibility into current state (judge only)
     [SKIP] Works on both Linux and macOS (no check defined)

   1 passed, 0 failed, 2 skipped
   ```

3. **`ralph status --judge`** — Run all `[judge]` evaluations from the current spec's success criteria:
   ```
   Ralph Judge: notifications (wx-q6x)
   =====================================
     [SKIP] Notification appears within 2s (verify only)
     [PASS] Clear visibility into current state
            "ralph status displays progress %, per-issue status,
             and blocked/awaiting indicators"
     [SKIP] Works on both Linux and macOS (no check defined)

   1 passed, 0 failed, 2 skipped
   ```

4. **`ralph status --verify --judge`** — Run both.

5. **Judge test infrastructure** — Judge tests live in `tests/judges/` and define rubrics:
   ```bash
   test_clear_visibility() {
     judge_files "lib/ralph/cmd/status.sh"
     judge_criterion "Output includes progress percentage, per-issue status indicators (done/running/blocked/awaiting), and dependency information"
   }
   ```
   - `judge_files` specifies which source files the LLM reads
   - `judge_criterion` specifies what the LLM evaluates
   - The runner invokes an LLM with files + criterion, returns PASS/FAIL + short reasoning

6. **`ralph status --watch` / `-w`** — Auto-refreshing live view:
   - Top: molecule progress (refreshes periodically)
   - Bottom: live tail of agent output if `ralph run` is active
   - Works standalone (shows status + recent activity even when nothing is running)
   - Uses tmux split for layout

7. **Awaiting input convention** — Tracker-agnostic label for human-blocked items:
   - When agent emits `RALPH_CLARIFY`, orchestrator adds `awaiting:input` label to bead
   - Question stored in bead notes
   - `ralph status` surfaces awaiting items distinctly:
     ```
     [awaiting] wx-q6x-10  Cross-platform CI
                  "Should CI use GitHub Actions or Buildkite?" (2h ago)
     ```
   - `ralph run` skips beads with `awaiting:input` label (not truly ready)
   - Human answers, label removed, bead becomes ready again
   - Convention works with any tracker that supports labels/tags

8. **Unified `ralph status`** — Absorb watch and verify into existing command:
   - `ralph status` (no flags): progress + recent errors + awaiting items (fast, instant)
   - `ralph status --watch` / `-w`: auto-refreshing + live agent tail
   - `ralph status --verify`: run shell tests from spec annotations
   - `ralph status --judge`: run LLM evaluations from spec annotations
   - `ralph status --verify --judge`: run both

### Non-Functional

1. **Fast default** — `ralph status` with no flags must be instant (no tests, no LLM calls)
2. **Clickable links** — `[verify]` and `[judge]` annotations render as clickable links in GitHub, VS Code, and terminal markdown viewers
3. **Tracker-agnostic** — `awaiting:input` convention uses labels, not custom status fields, so it works with any issue tracker
4. **Parseable annotations** — `[verify](path::fn)` and `[judge](path::fn)` patterns are easy to extract programmatically from spec markdown

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

## Affected Files

| File | Role |
|------|------|
| `lib/ralph/cmd/status.sh` | Enhanced with --verify, --judge, --watch flags |
| `lib/ralph/cmd/run.sh` | Awaiting:input label handling in orchestrator loop |
| `lib/ralph/cmd/util.sh` | Annotation parsing helpers, judge runner utilities |
| `specs/*.md` | Add `[verify]` and `[judge]` annotations to existing success criteria |
| `tests/judges/` | New directory for judge rubric test files |

## Success Criteria

- [ ] `[verify]` and `[judge]` annotations parse correctly from spec success criteria
- [ ] `ralph status --verify` runs shell tests and reports PASS/FAIL/SKIP
- [ ] `ralph status --judge` invokes LLM with rubric and reports PASS/FAIL/SKIP
- [ ] `ralph status --verify --judge` runs both
- [ ] Criteria with no annotation show as SKIP
- [ ] `ralph status` (no flags) remains instant with no test/LLM execution
- [ ] `ralph status --watch` creates tmux split with auto-refresh
- [ ] `ralph status --watch` works standalone (no active ralph run required)
- [ ] `RALPH_CLARIFY` adds `awaiting:input` label to bead
- [ ] `ralph run` skips beads with `awaiting:input` label
- [ ] `ralph status` displays awaiting items with question text and age
- [ ] Judge test files define rubrics via `judge_files` and `judge_criterion`
- [ ] Annotations are clickable links in GitHub and VS Code

## Out of Scope

- Deprecating `ralph logs` (keep as-is for now)
- Auto-updating `- [ ]` to `- [x]` in specs based on verify/judge results
- Web-based dashboard or GUI
- Cross-spec verification (verify one spec at a time)
- Judge model selection (use whatever model ralph is configured with)
