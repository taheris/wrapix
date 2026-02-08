#!/usr/bin/env bash
# Judge rubrics for pre-commit.md success criteria

test_prek_hook_speed_split() {
  judge_files "lib/ralph/cmd/run.sh" ".pre-commit-config.yaml"
  judge_criterion "prek run executes only fast hooks during normal operation; slow hooks (like nix flake check) are deferred to git push"
}
