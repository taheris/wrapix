#!/usr/bin/env bash
# Worker collect — records commit metadata after a worker exits.
#
# Sets commit_range and branch_name on the bead so the gate condition
# and judge can find the worker's output. Shared by provider.sh (monitor
# background process) and integration tests.
#
# No-op if the branch has no commits beyond main (worker did nothing).
#
# Exit codes:
#   0 — metadata set (or no-op for empty branch)
#   1 — error
#
# Environment variables:
#   GC_BEAD_ID    — bead to collect (required)
#   GC_WORKSPACE  — host workspace path (required)
set -euo pipefail

BEAD_ID="${GC_BEAD_ID:?worker-collect.sh requires GC_BEAD_ID}"
WORKSPACE="${GC_WORKSPACE:?worker-collect.sh requires GC_WORKSPACE}"

BRANCH="${BEAD_ID}"

# best-effort: branch may not exist if worker was killed before first commit
merge_base="$(git -C "${WORKSPACE}" merge-base main "${BRANCH}" 2>/dev/null || echo "")"
if [[ -z "$merge_base" ]]; then
  exit 0
fi

# best-effort: merge-base exists but branch may have no commits yet
commit_count="$(git -C "${WORKSPACE}" rev-list --count "${merge_base}..${BRANCH}" 2>/dev/null || echo "0")"
if [[ "$commit_count" -eq 0 ]]; then
  exit 0
fi

bd update "${BEAD_ID}" --set-metadata "commit_range=${merge_base}..${BRANCH}"
bd update "${BEAD_ID}" --set-metadata "branch_name=${BRANCH}"
