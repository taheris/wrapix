#!/usr/bin/env bash
set -euo pipefail

test_agent_transcript_audit_fit() {
  judge_files "specs/security.md" "lib/sandbox/linux/entrypoint.sh" "lib/sandbox/darwin/entrypoint.sh"
  judge_criterion "The selected agent's own persisted transcript is fit-for-purpose audit content for the stated policy-leakage threat model. PASS only if the threat model is explicitly limited to a misbehaving but non-adversarial agent, the selected transcript locations preserve intent/reasoning and outcomes needed for post-hoc policy-leakage review, the metadata index makes each transcript findable, and the spec does not claim this mechanism detects an adversarial agent that hides actions from its transcript."
}
