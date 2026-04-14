#!/usr/bin/env bash
# Judge merge — merges an approved worker branch to main.
#
# Attempts fast-forward merge first. If main has advanced, rebases the
# branch onto main and re-runs prek before merging. Rejects back to a
# new worker iteration on rebase conflicts or prek failures.
#
# Always cleans up the worktree and branch, whether merged or rejected.
#
# Exit codes:
#   0 — merged successfully
#   1 — rejected (conflicts or prek failure, metadata set on bead)
#   2 — fatal error (missing env, bad state)
#
# Environment variables:
#   GC_BEAD_ID    — bead to merge (required)
#   GC_WORKSPACE  — host workspace path (required)
set -euo pipefail

BEAD_ID="${GC_BEAD_ID:?judge-merge.sh requires GC_BEAD_ID}"
WORKSPACE="${GC_WORKSPACE:?judge-merge.sh requires GC_WORKSPACE}"

BRANCH="gc-${BEAD_ID}"
WORKTREE="${WORKSPACE}/.wrapix/worktree/${BRANCH}"

# ---------------------------------------------------------------------------
# Cleanup — always runs
# ---------------------------------------------------------------------------

stashed=false

cleanup() {
  # Worktree is removed before merge attempt; guard handles edge cases
  if [[ -d "$WORKTREE" ]]; then
    rm -rf "$WORKTREE"
    # best-effort: bookkeeping after rm -rf already removed the directory
    git -C "$WORKSPACE" worktree prune 2>/dev/null || true
  fi
  # Checkout main BEFORE deleting the branch — git refuses to delete the
  # branch that HEAD points to, so the delete silently fails if we're
  # still on it (e.g. after rebase --abort leaves HEAD on the branch).
  if ! git -C "$WORKSPACE" checkout main 2>&1; then
    echo "judge-merge: WARNING: checkout main failed in cleanup" >&2
  fi
  if git -C "$WORKSPACE" rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
    # Try soft delete, then force — branch may have unmerged commits on reject path
    git -C "$WORKSPACE" branch -d "$BRANCH" 2>/dev/null || \
      git -C "$WORKSPACE" branch -D "$BRANCH" 2>/dev/null || \
      echo "judge-merge: WARNING: could not delete branch $BRANCH" >&2
  fi
  if [[ "$stashed" == true ]]; then
    if ! git -C "$WORKSPACE" stash pop -q 2>&1; then
      echo "judge-merge: WARNING: stash pop failed — working tree may be dirty" >&2
    fi
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Reject helper — sets metadata and returns to open
# ---------------------------------------------------------------------------

reject() {
  local reason="$1"
  # These writes are critical — without them the bead stays in_progress
  # and the gate polls indefinitely or dispatch re-sends the same work.
  bd update "$BEAD_ID" --set-metadata "review_verdict=reject" ||
    echo "judge-merge: ERROR: failed to set review_verdict=reject on $BEAD_ID" >&2
  bd update "$BEAD_ID" --set-metadata "merge_failure=${reason}" ||
    echo "judge-merge: ERROR: failed to set merge_failure on $BEAD_ID" >&2
  bd update "$BEAD_ID" --status=open --notes="Judge: merge rejected — ${reason}" ||
    echo "judge-merge: ERROR: failed to reopen $BEAD_ID" >&2
}

# ---------------------------------------------------------------------------
# Merge
# ---------------------------------------------------------------------------

# Free the branch from the worktree — git won't allow checkout of a branch
# that's checked out in a linked worktree. The worktree was the worker's
# scratch space; the branch tip has all the commits we need.
if [[ -d "$WORKTREE" ]]; then
  rm -rf "$WORKTREE"
  # best-effort: bookkeeping after rm -rf already removed the directory
  git -C "$WORKSPACE" worktree prune 2>/dev/null || true
fi

git -C "$WORKSPACE" checkout main

# Try fast-forward first (non-zero = not fast-forwardable, not an error)
if git -C "$WORKSPACE" merge --ff-only "$BRANCH" 2>/dev/null; then
  echo "judge-merge: fast-forward merged $BRANCH"
  exit 0
fi

# Main advanced — rebase branch onto main.
# Stash any dirty tracked files (e.g. city.toml modified by entrypoint)
# so git rebase doesn't fail on an unclean working tree.
if ! git -C "$WORKSPACE" diff --quiet 2>/dev/null; then
  git -C "$WORKSPACE" stash push -q && stashed=true
fi

git -C "$WORKSPACE" checkout "$BRANCH"

rebase_err=$(mktemp)
if ! git -C "$WORKSPACE" rebase main 2>"$rebase_err"; then
  conflict_details="$(cat "$rebase_err" 2>/dev/null || echo "rebase conflicts")"
  rm -f "$rebase_err"
  git -C "$WORKSPACE" rebase --abort 2>/dev/null || true
  reject "Rebase conflicts: ${conflict_details}"
  echo "judge-merge: rejected $BRANCH — rebase conflicts"
  exit 1
fi
rm -f "$rebase_err"

# Run prek if available (pre-commit checks after rebase)
if command -v prek >/dev/null 2>&1; then
  prek_out=$(mktemp)
  if ! (cd "$WORKSPACE" && prek run --stage pre-commit) >"$prek_out" 2>&1; then
    prek_details="$(cat "$prek_out" 2>/dev/null || echo "prek failure")"
    rm -f "$prek_out"
    git -C "$WORKSPACE" checkout main
    reject "Tests failed after rebase: ${prek_details}"
    echo "judge-merge: rejected $BRANCH — prek failed after rebase"
    exit 1
  fi
  rm -f "$prek_out"
fi

# Rebase succeeded, merge via fast-forward
git -C "$WORKSPACE" checkout main
if ! git -C "$WORKSPACE" merge --ff-only "$BRANCH" 2>/dev/null; then
  reject "Fast-forward failed after rebase (unexpected)"
  echo "judge-merge: rejected $BRANCH — post-rebase ff failed"
  exit 1
fi

echo "judge-merge: rebased and merged $BRANCH"
exit 0
