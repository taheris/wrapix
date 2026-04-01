#!/usr/bin/env bash
# Gas City judge rubrics — evaluates design quality criteria from specs/gas-city.md

test_reviewer_enforcement() {
  judge_files "lib/city/default.nix" "specs/gas-city.md"
  judge_criterion "The mkCity function generates configuration that supports a reviewer role which enforces docs/style-guidelines.md rules, with the reviewer being a persistent session role distinct from worker and scout"
}

test_provider_simplicity() {
  judge_files "lib/city/default.nix"
  judge_criterion "The provider script reference is a clean shell script path using the exec:<script> pattern with no Go dependencies, and the mkCity function generates it via pkgs.writeShellScript"
}

test_agent_abstraction() {
  judge_files "lib/city/default.nix"
  judge_criterion "The agent type is a configuration option (defaulting to 'claude') stored in the city config, allowing future provider swaps by adding new entries without changing mkCity's architecture or the container image build logic"
}
