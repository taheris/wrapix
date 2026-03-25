#!/usr/bin/env bash
# Judge rubrics for orchestration spec success criteria.

test_check_template_quality() {
  judge_files "lib/ralph/template/check.md"
  judge_criterion "Template instructs the reviewer to assess tests, code quality, and spec compliance holistically rather than using a rigid checklist; reviewer explores codebase on demand via git diff and file reads"
}

test_watch_template_quality() {
  judge_files "lib/ralph/template/watch.md"
  judge_criterion "Template instructs the agent to observe contextually based on the spec rather than pattern-matching for generic errors; agent maintains watch state across sessions"
}

test_run_template_retry_context() {
  judge_files "lib/ralph/template/run.md" "lib/ralph/template/default.nix"
  judge_criterion "The run template includes PREVIOUS_FAILURE variable in its variable list and the template system defines PREVIOUS_FAILURE as a computed variable with empty string default for retry context injection"
}

test_reviewer_context() {
  judge_files "lib/ralph/template/check.md" "lib/ralph/template/default.nix"
  judge_criterion "The check template receives spec path, beads summary (titles and status), base_commit SHA, and molecule ID; reviewer can explore the full codebase on demand rather than having all code injected into the prompt"
}
