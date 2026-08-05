#!/usr/bin/env bash
set -euo pipefail

test_public_flag_help_quality() {
  judge_files \
    "crates/wrix-cli/src/command/mod.rs" \
    "crates/wrix-cli/src/init.rs" \
    "crates/wrix-sandbox/src/command/mod.rs" \
    "crates/wrix-service/src/command/mod.rs" \
    "crates/wrix-cache/src/command/mod.rs" \
    "crates/wrix-beads/src/command/mod.rs"
  judge_criterion "Every public wrix root and subcommand flag has concise user-facing help that explains its current effect. PASS only when descriptions identify required inputs, defaults, and incompatible options wherever that information changes how an operator should invoke the command; descriptions must not claim constraints that the parser does not enforce."
}
