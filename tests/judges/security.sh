#!/usr/bin/env bash
set -euo pipefail

test_agent_transcript_audit_fit() {
  judge_files "docs/architecture.md" "specs/security.md" "lib/sandbox/linux/entrypoint.sh" "lib/sandbox/darwin/entrypoint.sh"
  judge_criterion "Runtime-provided agent transcripts are fit-for-purpose audit content for the stated policy-leakage threat model without overstating direct mode. PASS only if the threat model is explicitly limited to a misbehaving but non-adversarial agent; Claude and Pi transcript locations preserve intent/reasoning and outcomes needed for post-hoc review; external direct runners own any transcript they persist; Wrix's placeholder direct runner is not claimed to synthesize transcript content; and the metadata index makes sessions and available transcripts findable."
}

test_scoped_component_diagnostics_policy() {
  judge_files "specs/security.md" "specs/tmux-mcp.md" "lib/mcp/tmux/default.nix" "lib/mcp/tmux/tmux-mcp/src/audit/mod.rs"
  judge_criterion "The security and tmux-mcp contracts consistently preserve the .wrix/log session index plus any runtime-provided agent transcript as Wrix's authoritative security audit surface while allowing only explicit, default-off component diagnostics. PASS only if Wrix does not automatically enable, index, synthesize, or aggregate the diagnostics; tmux-mcp owns configuration, format, and emission; the enabling operator owns the destination, access control, retention, and deletion; and the tmux contract discloses that unredacted commands, keystrokes, and optional full captures may contain credentials or other secrets."
}
