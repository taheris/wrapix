#!/usr/bin/env bash
# Judge rubrics for skip-tests success criteria

test_summary_distinguishes_counts() {
  judge_files "tests/ralph/lib/runner.sh"
  judge_criterion "Test summary distinguishes passed/failed/skipped/not-implemented counts as four separate categories with independent counters, and the summary output shows all four values"
}

test_binary_guards_removed() {
  judge_files "tests/tmux-mcp/test_lib.sh" "tests/tmux-mcp/e2e/test_sandbox_debug_profile.sh" "tests/tmux-mcp/e2e/test_mcp_in_sandbox.sh" "tests/tmux-mcp/e2e/test_mcp_audit_config.sh" "tests/tmux-mcp/e2e/test_filesystem_isolation.sh" "tests/tmux-mcp/e2e/test_profile_composition.sh"
  judge_criterion "Binary availability guards (command -v / which checks that skip or exit early when binaries like tmux-debug-mcp, nix, or podman are missing) have been removed from tests where those binaries are provided by the runner environment"
}
