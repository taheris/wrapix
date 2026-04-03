#!/usr/bin/env bash
# Gas City judge rubrics — evaluates design quality criteria from specs/gas-city.md

test_judge_enforcement() {
  judge_files "lib/city/default.nix" "specs/gas-city.md"
  judge_criterion "The mkCity function generates configuration that supports a judge role which enforces docs/style-guidelines.md rules, with the judge being a persistent session role distinct from worker and scout"
}

test_provider_simplicity() {
  judge_files "lib/city/provider.sh" "lib/city/default.nix"
  judge_criterion "The provider script is a clean, minimal shell script using the exec:<script> pattern with no Go dependencies. It uses set -euo pipefail, handles all gc provider methods via a case statement, and the mkCity function reads it via builtins.readFile into pkgs.writeShellScript"
}

test_agent_abstraction() {
  judge_files "lib/city/default.nix" "lib/city/agent.sh"
  judge_criterion "The agent type is a configuration option (defaulting to 'claude') stored in the city config, with a wrapix-agent wrapper script that dispatches to agent-specific CLI calls via a registry pattern. Future provider swaps require only a new case entry in agent.sh and the corresponding package in the Nix closure, without changing mkCity's architecture or the container image build logic"
}
