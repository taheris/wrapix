#!/usr/bin/env bash
# Worker setup — creates worktree and task context for a worker bead.
#
# Shared by provider.sh (live workers) and integration tests (scaffolded
# workers). Keeps worktree creation, bead claiming, and task file
# generation in one place so tests exercise the live code path.
#
# Exit codes:
#   0 — setup complete, worktree ready
#   1 — no bead found or setup failed
#
# Environment variables:
#   GC_BEAD_ID     — bead to work on (optional; falls back to routed bead picker)
#   GC_WORKSPACE   — host workspace path (required)
set -euo pipefail

WORKSPACE="${GC_WORKSPACE:?worker-setup.sh requires GC_WORKSPACE}"

# Resolve bead — explicit or fallback picker
bead_id="${GC_BEAD_ID:-}"
if [[ -z "$bead_id" ]]; then
  # best-effort: bd may not be reachable yet during early startup
  bead_id="$(cd "${WORKSPACE}" && bd list --metadata-field gc.routed_to=worker --status open,in_progress --json 2>/dev/null \
    | jq -r '.[0].id // empty' 2>/dev/null)" || bead_id=""
fi
if [[ -z "$bead_id" ]]; then
  echo "worker-setup: no bead routed to worker" >&2
  exit 1
fi

# Claim the bead and mark in_progress. In the live flow gc sling sets
# in_progress before the worker starts; we do it here so callers that
# bypass sling (recovery tests, escalation tests) get the same state.
# Without --claim, two workers can be dispatched to the same bead concurrently.
if ! (cd "${WORKSPACE}" && bd update "$bead_id" --claim --status=in_progress) >/dev/null; then
  echo "worker-setup: WARNING: failed to claim bead $bead_id — may race with another worker" >&2
fi

worktree_path=".wrapix/worktree/gc-${bead_id}"

# Create git worktree on the host
if [[ ! -d "${WORKSPACE}/${worktree_path}" ]]; then
  git -C "${WORKSPACE}" worktree add "${worktree_path}" -b "gc-${bead_id}" 2>&1 || \
    git -C "${WORKSPACE}" worktree add "${worktree_path}" "gc-${bead_id}" 2>&1
fi

# Build task file from bead description, acceptance criteria, and judge notes
task_file="${WORKSPACE}/${worktree_path}/.task"
{
  # best-effort: bead may have been created without description
  local_json="$(bd show "${bead_id}" --json 2>/dev/null)" || local_json=""
  if [[ -n "$local_json" ]]; then
    # gc sling inline text creates beads where description is missing from JSON
    # (wx-30sbo); fall back to title so the .task file is never empty.
    echo "$local_json" | jq -r '.[0].description // .[0].title // empty' 2>/dev/null || true
    acceptance="$(echo "$local_json" | jq -r '.[0].acceptance // empty' 2>/dev/null)" || acceptance=""
    if [[ -n "$acceptance" ]]; then
      printf '\n## Acceptance Criteria\n\n%s\n' "$acceptance"
    fi
  fi
  judge_notes="$(bd show "${bead_id}" --json 2>/dev/null | jq -r '.[0].metadata.merge_failure // empty' 2>/dev/null)" || judge_notes=""
  if [[ -n "$judge_notes" ]]; then
    printf '\n## Prior Rejection\n\n%s\n' "$judge_notes"
  fi
} > "$task_file" || echo "worker-setup: WARNING: failed to write task file $task_file" >&2

# Copy worker role prompt if available
if [[ -f "${WORKSPACE}/.wrapix/city/current/prompts/worker.md" ]]; then
  cp -f "${WORKSPACE}/.wrapix/city/current/prompts/worker.md" \
     "${WORKSPACE}/${worktree_path}/.role-prompt"
fi

# Record dispatch timestamp for cooldown pacing
state_dir="${WORKSPACE}/.wrapix/state"
mkdir -p "$state_dir"
date +%s > "$state_dir/last-dispatch"
