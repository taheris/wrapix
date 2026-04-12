#!/usr/bin/env bash
# Post-gate order — event-gated order triggered by convergence.terminated.
#
# Lightweight coordinator: notifies judge to merge (for approved convergences),
# handles deploy bead creation, escalation routing, and notifications.
# The judge owns the actual git operations (merge, rebase, cleanup).
#
# Exit codes:
#   0 — post-gate actions completed successfully
#   1 — error during post-gate processing
#
# Environment variables (set by gc order / city config):
#   GC_BEAD_ID          — bead that went through convergence (required)
#   GC_TERMINAL_REASON  — why convergence ended: "approved" or other (required)
#   GC_WORKSPACE        — host workspace path (required)
#   GC_CITY_NAME        — city name for notification context (required)
set -euo pipefail

BEAD_ID="${GC_BEAD_ID:?post-gate.sh requires GC_BEAD_ID}"
TERMINAL_REASON="${GC_TERMINAL_REASON:?post-gate.sh requires GC_TERMINAL_REASON}"
WORKSPACE="${GC_WORKSPACE:?post-gate.sh requires GC_WORKSPACE}"
CITY_NAME="${GC_CITY_NAME:?post-gate.sh requires GC_CITY_NAME}"

BRANCH="gc-${BEAD_ID}"
WORKTREE_PATH=".wrapix/worktree/gc-${BEAD_ID}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

notify() {
  wrapix-notify "Gas City" "$1" 2>/dev/null || true
}

# Clean up worktree and branch for a bead. Used by escalation path only —
# for approved convergences, the judge handles cleanup after merge.
cleanup_branch() {
  local branch="$1" worktree="$2"

  # Remove worktree directory directly — git worktree remove may fail because
  # provider.sh rewrites .git to a container-internal path (/mnt/git/...).
  if [[ -d "$worktree" ]]; then
    rm -rf "$worktree"
    git -C "$WORKSPACE" worktree prune 2>/dev/null || true
  fi

  if git -C "$WORKSPACE" rev-parse --verify "$branch" >/dev/null 2>&1; then
    git -C "$WORKSPACE" branch -d "$branch" 2>/dev/null || \
      git -C "$WORKSPACE" branch -D "$branch" 2>/dev/null || true
  fi
}

# Check if docs/orchestration.md has an Auto-deploy section.
has_auto_deploy() {
  local orch_file="${WORKSPACE}/docs/orchestration.md"
  [[ -f "$orch_file" ]] && grep -qE '^#+\s+Auto-deploy' "$orch_file"
}

# Check if the judge classified the change as low-risk.
is_low_risk() {
  local risk
  risk="$(bd show "$BEAD_ID" --json 2>/dev/null | jq -r '.[0].metadata.risk_classification // empty' 2>/dev/null)" || risk=""
  [[ "$risk" == "low" ]]
}

# ---------------------------------------------------------------------------
# Escalation (terminal_reason != approved)
# ---------------------------------------------------------------------------

handle_escalation() {
  echo "post-gate: convergence escalated for bead $BEAD_ID (reason: $TERMINAL_REASON)"

  # Mark bead with escalation metadata so the mayor can find and present it
  bd update "$BEAD_ID" --set-metadata "escalated=true" 2>/dev/null || true
  bd update "$BEAD_ID" --set-metadata "escalation_reason=$TERMINAL_REASON" 2>/dev/null || true
  bd update "$BEAD_ID" --notes="Convergence escalated: $TERMINAL_REASON — needs human review via mayor" 2>/dev/null || true

  # Flag for human review — mayor picks this up via bd human list
  bd label add "$BEAD_ID" human 2>/dev/null || true

  # Notify mayor directly so it can present on next attach
  gc mail send --to mayor -s "escalation" \
    -m "Convergence escalated for bead $BEAD_ID (reason: $TERMINAL_REASON). Worker→judge loop exhausted after max iterations. Review via bd show $BEAD_ID." \
    2>/dev/null || true

  # Fallback notification for when human is not attached to mayor
  notify "[${CITY_NAME}] Convergence escalated: bead ${BEAD_ID} — ${TERMINAL_REASON}"

  # Clean up worktree and branch on escalation
  cleanup_branch "$BRANCH" "${WORKSPACE}/${WORKTREE_PATH}"
}

# ---------------------------------------------------------------------------
# Approved (terminal_reason == approved)
# ---------------------------------------------------------------------------

handle_approved() {
  echo "post-gate: convergence approved for bead $BEAD_ID"

  # Close the work bead — convergence succeeded, work is done. Without this,
  # the bead stays in_progress with gc.routed_to set, causing dispatch.sh to
  # count it as demand and the fallback bead picker to hand it to new workers.
  bd close "$BEAD_ID" 2>/dev/null || true

  # Notify judge to merge — judge owns the actual git operations
  # (fast-forward, rebase, worktree cleanup). This nudge includes the
  # bead ID so the judge can look up the branch and perform merge.
  gc session nudge judge \
    "Merge approved bead $BEAD_ID — branch gc-${BEAD_ID}. Run merge step now." \
    2>/dev/null || true

  # Create deploy bead
  create_deploy_bead

  # Notification
  notify "[${CITY_NAME}] Convergence approved: bead ${BEAD_ID} — judge notified to merge"
}

# ---------------------------------------------------------------------------
# Deploy bead creation
# ---------------------------------------------------------------------------

create_deploy_bead() {
  local summary
  summary="$(bd show "$BEAD_ID" --json 2>/dev/null | head -1)" || summary=""

  local title
  title="$(echo "$summary" | grep -o '"title":"[^"]*"' | head -1 | cut -d'"' -f4)" || title="$BEAD_ID"

  local deploy_id
  deploy_id="$(bd create \
    --title="Deploy: ${title}" \
    --description="Deploy change from bead ${BEAD_ID}. Merged branch gc-${BEAD_ID} to main." \
    --type=task \
    --priority=2 \
    --labels="deploy,gc-deploy" \
    --silent 2>/dev/null)" || deploy_id=""

  if [[ -z "$deploy_id" ]]; then
    echo "post-gate: warning — failed to create deploy bead" >&2
    return 0
  fi

  echo "post-gate: created deploy bead $deploy_id"

  # Determine whether to flag for director approval or auto-deploy
  if has_auto_deploy && is_low_risk; then
    echo "post-gate: auto-deploy eligible (low-risk + Auto-deploy configured)"
    bd update "$deploy_id" --set-metadata "auto_deploy=true" 2>/dev/null || true
  else
    # Default: flag for director approval
    bd label add "$deploy_id" human 2>/dev/null || true
    notify "[${CITY_NAME}] Deploy approval needed: ${title} (bead ${deploy_id})"
  fi
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

case "$TERMINAL_REASON" in
  approved)
    handle_approved
    ;;
  *)
    handle_escalation
    ;;
esac
