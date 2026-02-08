#!/usr/bin/env bash
# Judge rubrics for ralph-tests.md success criteria

test_deterministic_and_fast() {
  judge_files "tests/ralph/run-tests.sh" "tests/ralph/lib/runner.sh" "tests/ralph/lib/fixtures.sh"
  judge_criterion "Tests are deterministic (no real API calls, isolated temp directories, mock claude) and fast (no network latency, instant mock responses)"
}
