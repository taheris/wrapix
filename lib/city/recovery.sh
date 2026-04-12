#!/usr/bin/env bash
# Crash recovery — reconcile running containers and worktrees after gc restart.
#
# Called by entrypoint.sh before exec'ing gc start --foreground.
# Scans podman for running gc containers, reconciles against beads state,
# stops orphans, and prunes stale worktrees. Metadata for finished workers
# is computed by gate.sh on demand (idempotent, crash-recoverable).
#
# Environment variables (set by mkCity / systemd unit):
#   GC_CITY_NAME  — city name (required)
#   GC_WORKSPACE  — host workspace path (required)
set -euo pipefail

CITY_NAME="${GC_CITY_NAME:?recovery.sh requires GC_CITY_NAME}"
WORKSPACE="${GC_WORKSPACE:?recovery.sh requires GC_WORKSPACE}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# List running containers belonging to this city.
list_city_containers() {
  podman ps --filter "label=gc-city=${CITY_NAME}" \
    --format '{{.Names}} {{.Labels}}' 2>/dev/null || true
}

# Get the gc-bead label from a container.
get_container_bead() {
  local container="$1"
  podman inspect --format '{{index .Config.Labels "gc-bead"}}' "$container" 2>/dev/null || echo ""
}

# Get the gc-role label from a container.
get_container_role() {
  local container="$1"
  podman inspect --format '{{index .Config.Labels "gc-role"}}' "$container" 2>/dev/null || echo ""
}

# Check if a bead is in_progress.
bead_in_progress() {
  local bead_id="$1"
  local status
  status="$(bd show "$bead_id" --json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)" || status=""
  [[ "$status" == "in_progress" ]]
}

# Check if a bead is open (not closed/done).
bead_is_open() {
  local bead_id="$1"
  local status
  status="$(bd show "$bead_id" --json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)" || status=""
  [[ "$status" == "open" || "$status" == "in_progress" ]]
}

# Stop and remove a container.
stop_container() {
  local container="$1"
  echo "recovery: stopping orphaned container $container"
  podman stop "$container" 2>/dev/null || true
  podman rm -f "$container" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Step 1: Reconcile running worker containers against beads state
# ---------------------------------------------------------------------------

reconcile_workers() {
  local containers
  containers="$(podman ps --filter "label=gc-city=${CITY_NAME}" \
    --filter "label=gc-role=worker" \
    --format '{{.Names}}' 2>/dev/null)" || containers=""

  [[ -z "$containers" ]] && return 0

  while IFS= read -r container; do
    [[ -z "$container" ]] && continue

    local bead_id
    bead_id="$(get_container_bead "$container")"

    if [[ -z "$bead_id" ]]; then
      # No bead label — orphan
      stop_container "$container"
      continue
    fi

    if ! bead_in_progress "$bead_id"; then
      # Bead is not in_progress — orphaned worker
      stop_container "$container"
      continue
    fi

    # Worker is still associated with an in-progress bead — leave it running.
    # gc will reconcile when it starts.
    echo "recovery: worker container $container for bead $bead_id still in progress"
  done <<< "$containers"
}

# ---------------------------------------------------------------------------
# Step 2: Clean up stale worktrees
# ---------------------------------------------------------------------------

cleanup_stale_worktrees() {
  # Prune worktrees whose backing directory has been removed
  git -C "$WORKSPACE" worktree prune 2>/dev/null || true

  # Remove worktrees for beads that are no longer open
  local worktrees
  worktrees="$(find "${WORKSPACE}/.wrapix/worktree" -maxdepth 1 -name 'gc-*' -type d 2>/dev/null)" || worktrees=""

  [[ -z "$worktrees" ]] && return 0

  while IFS= read -r worktree_path; do
    [[ -z "$worktree_path" ]] && continue

    local dir_name bead_id
    dir_name="$(basename "$worktree_path")"
    bead_id="${dir_name#gc-}"

    # If bead is still open, keep the worktree
    if bead_is_open "$bead_id"; then
      continue
    fi

    echo "recovery: removing stale worktree for bead $bead_id"
    # Use rm -rf + prune instead of git worktree remove, because provider.sh
    # rewrites the .git file with a container-internal path that git can't resolve
    rm -rf "$worktree_path"
    git -C "$WORKSPACE" worktree prune 2>/dev/null || true

    # Also clean up the branch if it still exists
    local branch="gc-${bead_id}"
    if git -C "$WORKSPACE" rev-parse --verify "$branch" >/dev/null 2>&1; then
      git -C "$WORKSPACE" branch -d "$branch" 2>/dev/null || \
        git -C "$WORKSPACE" branch -D "$branch" 2>/dev/null || true
    fi
  done <<< "$worktrees"
}

# ---------------------------------------------------------------------------
# Step 3: Stop orphaned persistent containers (scout/judge) that gc
# will re-create on start
# ---------------------------------------------------------------------------

cleanup_persistent_containers() {
  local containers
  containers="$(podman ps --filter "label=gc-city=${CITY_NAME}" \
    --format '{{.Names}}' 2>/dev/null)" || containers=""

  [[ -z "$containers" ]] && return 0

  while IFS= read -r container; do
    [[ -z "$container" ]] && continue

    local role
    role="$(get_container_role "$container")"

    # gc will recreate persistent roles on start — stop stale ones
    if [[ "$role" == "scout" || "$role" == "judge" ]]; then
      echo "recovery: stopping stale persistent container $container (gc will recreate)"
      podman stop "$container" 2>/dev/null || true
      podman rm -f "$container" 2>/dev/null || true
    fi
  done <<< "$containers"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "recovery: scanning for containers from city ${CITY_NAME}..."

reconcile_workers
cleanup_stale_worktrees
cleanup_persistent_containers

echo "recovery: reconciliation complete"
