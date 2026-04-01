#!/usr/bin/env bash
# Gas City judge rubrics — evaluates design quality criteria from specs/gas-city.md

test_reviewer_enforcement() {
  judge_files "lib/city/default.nix" "specs/gas-city.md"
  judge_criterion "The mkCity function generates configuration that supports a reviewer role which enforces docs/style-guidelines.md rules, with the reviewer being a persistent session role distinct from worker and scout"
}

test_provider_simplicity() {
  judge_files "lib/city/provider.sh" "lib/city/default.nix"
  judge_criterion "The provider script is a clean, minimal shell script using the exec:<script> pattern with no Go dependencies. It uses set -euo pipefail, handles all gc provider methods via a case statement, and the mkCity function reads it via builtins.readFile into pkgs.writeShellScript"
}

test_agent_abstraction() {
  judge_files "lib/city/default.nix"
  judge_criterion "The agent type is a configuration option (defaulting to 'claude') stored in the city config, allowing future provider swaps by adding new entries without changing mkCity's architecture or the container image build logic"
}
