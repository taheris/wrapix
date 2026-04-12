#!/usr/bin/env bash
# Convergence gate condition script — bridges worker→judge handoff.
#
# Called by gc convergence with gate_mode=condition. After a worker completes,
# this script checks whether the worker container has exited, computes
# commit_range metadata if missing, nudges the judge session, polls for the
# review verdict, and returns the result.
#
# This script is idempotent: safe to call repeatedly and after crashes.
# It owns the full worker→judge handoff — no background processes needed.
#
# Exit codes:
#   0 — judge approved (convergence terminates successfully)
#   1 — judge rejected (convergence iterates or escalates)
#
# Environment variables (set by formula env configuration):
#   GC_BEAD_ID       — bead being reviewed (required)
#   GC_CITY_NAME     — city name for container naming (required)
#   GC_WORKSPACE     — host workspace path (required)
#   GC_POLL_INTERVAL — seconds between verdict polls (default: 10)
#   GC_POLL_TIMEOUT  — max seconds to wait for verdict (default: 600)
set -euo pipefail

BEAD_ID="${GC_BEAD_ID:?gate.sh requires GC_BEAD_ID}"
CITY_NAME="${GC_CITY_NAME:?gate.sh requires GC_CITY_NAME}"
WORKSPACE="${GC_WORKSPACE:?gate.sh requires GC_WORKSPACE}"
POLL_INTERVAL="${GC_POLL_INTERVAL:-10}"
POLL_TIMEOUT="${GC_POLL_TIMEOUT:-600}"

CONTAINER_NAME="gc-${CITY_NAME}-worker-${BEAD_ID}"
BRANCH="gc-${BEAD_ID}"

# ---------------------------------------------------------------------------
# Step 1: Ensure commit_range metadata exists (compute if missing)
# ---------------------------------------------------------------------------

commit_range="$(bd show "$BEAD_ID" --json 2>/dev/null | jq -r '.[0].metadata.commit_range // empty' 2>/dev/null)" || commit_range=""

if [[ -z "$commit_range" ]]; then
  # Check whether the worker container is still running
  running="$(podman inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" || running="false"

  if [[ "$running" == "true" ]]; then
    echo "gate: worker container $CONTAINER_NAME still running for bead $BEAD_ID" >&2
    exit 1
  fi

  # Worker has exited — compute metadata from the branch
  merge_base="$(git -C "$WORKSPACE" merge-base main "$BRANCH" 2>/dev/null)" || merge_base=""

  if [[ -z "$merge_base" ]]; then
    echo "gate: no merge-base for branch $BRANCH — worker may not have committed" >&2
    exit 1
  fi

  # Check that the branch has commits beyond the merge-base
  branch_head="$(git -C "$WORKSPACE" rev-parse "$BRANCH" 2>/dev/null)" || branch_head=""
  if [[ "$merge_base" == "$branch_head" ]]; then
    echo "gate: branch $BRANCH has no commits beyond main — worker produced no changes" >&2
    exit 1
  fi

  commit_range="${merge_base}..${BRANCH}"
  bd update "$BEAD_ID" --set-metadata "commit_range=${commit_range}"
  bd update "$BEAD_ID" --set-metadata "branch_name=${BRANCH}"
  echo "gate: computed commit_range=${commit_range} for bead $BEAD_ID"
fi

# ---------------------------------------------------------------------------
# Step 2: Nudge the judge session with the commit range
# ---------------------------------------------------------------------------

gc session nudge judge "Review bead $BEAD_ID — commit range: $commit_range"

# ---------------------------------------------------------------------------
# Step 3: Poll bead metadata for review_verdict
# ---------------------------------------------------------------------------

elapsed=0
verdict=""

while [[ "$elapsed" -lt "$POLL_TIMEOUT" ]]; do
  verdict="$(bd show "$BEAD_ID" --json 2>/dev/null | jq -r '.[0].metadata.review_verdict // empty' 2>/dev/null)" || verdict=""

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
    echo "gate: bead $BEAD_ID approved by judge"
    exit 0
    ;;
  reject)
    echo "gate: bead $BEAD_ID rejected by judge"
    exit 1
    ;;
  *)
    echo "gate: timed out waiting for review verdict on bead $BEAD_ID (${POLL_TIMEOUT}s)" >&2
    exit 1
    ;;
esac
