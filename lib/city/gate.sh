#!/usr/bin/env bash
# Convergence gate condition script — bridges worker→reviewer handoff.
#
# Called by gc convergence with gate_mode=condition. After a worker completes,
# this script reads the commit range from bead metadata, nudges the reviewer
# session, polls for the review verdict, and returns the result.
#
# Exit codes:
#   0 — reviewer approved (convergence terminates successfully)
#   1 — reviewer rejected (convergence iterates or escalates)
#
# Environment variables (set by formula env configuration):
#   GC_BEAD_ID       — bead being reviewed (required)
#   GC_POLL_INTERVAL — seconds between verdict polls (default: 10)
#   GC_POLL_TIMEOUT  — max seconds to wait for verdict (default: 600)
set -euo pipefail

BEAD_ID="${GC_BEAD_ID:?gate.sh requires GC_BEAD_ID}"
POLL_INTERVAL="${GC_POLL_INTERVAL:-10}"
POLL_TIMEOUT="${GC_POLL_TIMEOUT:-600}"

# ---------------------------------------------------------------------------
# Step 1: Read commit_range from bead metadata
# ---------------------------------------------------------------------------

commit_range="$(bd meta get "$BEAD_ID" commit_range 2>/dev/null)" || commit_range=""

if [[ -z "$commit_range" ]]; then
  echo "gate: no commit_range set on bead $BEAD_ID — worker may not have committed" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Nudge the reviewer session with the commit range
# ---------------------------------------------------------------------------

gc nudge reviewer --message "Review bead $BEAD_ID — commit range: $commit_range"

# ---------------------------------------------------------------------------
# Step 3: Poll bead metadata for review_verdict
# ---------------------------------------------------------------------------

elapsed=0
verdict=""

while [[ "$elapsed" -lt "$POLL_TIMEOUT" ]]; do
  verdict="$(bd meta get "$BEAD_ID" review_verdict 2>/dev/null)" || verdict=""

  if [[ "$verdict" == "approve" ]] || [[ "$verdict" == "reject" ]]; then
    break
  fi

  sleep "$POLL_INTERVAL"
  elapsed=$((elapsed + POLL_INTERVAL))
done

# ---------------------------------------------------------------------------
# Step 4: Return exit code based on verdict
# ---------------------------------------------------------------------------

case "$verdict" in
  approve)
    echo "gate: bead $BEAD_ID approved by reviewer"
    exit 0
    ;;
  reject)
    echo "gate: bead $BEAD_ID rejected by reviewer"
    exit 1
    ;;
  *)
    echo "gate: timed out waiting for review verdict on bead $BEAD_ID (${POLL_TIMEOUT}s)" >&2
    exit 1
    ;;
esac
