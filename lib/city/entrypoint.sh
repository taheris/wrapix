#!/usr/bin/env bash
# Gas City container entrypoint — init checks, event watcher, then exec gc.
#
# 1. Prints informational summary of pending reviews (including scaffolding
#    beads created by ralph sync). Does not block — the mayor presents these
#    items to the human on attach.
# 2. Runs crash recovery — reconciles orphaned containers and worktrees.
# 3. Starts a background process watching podman events for service container
#    lifecycle events (die, oom, restart) and wakes the scout via gc nudge.
# 4. Execs gc start --foreground
#
# Environment variables (set by mkCity / systemd unit):
#   GC_CITY_NAME       — city name (required)
#   GC_WORKSPACE       — host workspace path (required)
#   GC_PODMAN_NETWORK  — podman network name (required)
#   NOTIFY_SOCKET_PATH — notify socket path (optional, for wrapix-notifyd)
set -euo pipefail

CITY_NAME="${GC_CITY_NAME:?entrypoint.sh requires GC_CITY_NAME}"
: "${GC_WORKSPACE:?entrypoint.sh requires GC_WORKSPACE}"

# ---------------------------------------------------------------------------
# Step 1: Print informational summary of pending reviews
# ---------------------------------------------------------------------------

print_pending_reviews() {
  local pending
  pending="$(bd human list --json 2>/dev/null)" || pending="[]"

  local count
  count="$(echo "$pending" | jq 'length' 2>/dev/null)" || count="0"

  if [[ "$count" -gt 0 ]]; then
    echo "Pending review items (${count}):"
    echo "$pending" | jq -r '.[] | "  - \(.id): \(.title)"' 2>/dev/null
    echo ""
    echo "The mayor will present these on attach."
  fi
}

print_pending_reviews

# ---------------------------------------------------------------------------
# Step 2: Crash recovery — reconcile orphaned containers and worktrees
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/recovery.sh"

# ---------------------------------------------------------------------------
# Step 3: Start podman events watcher (background)
# ---------------------------------------------------------------------------

# Watch for service container lifecycle events and nudge the scout.
# Only watches containers in our city's network, excludes gc-managed agent
# containers (which have the gc-city label).
start_events_watcher() {
  (
    podman events \
      --filter="type=container" \
      --filter="event=die" \
      --filter="event=oom" \
      --filter="event=restart" \
      --format='{{.Actor.Attributes.name}} {{.Status}}' 2>/dev/null |
    while IFS=' ' read -r container_name event_type; do
      # Skip gc-managed containers (agent sessions)
      if [[ "$container_name" == gc-"${CITY_NAME}"-* ]]; then
        continue
      fi

      # Nudge the scout with event details
      gc session nudge scout "Service container event: ${container_name} ${event_type}" 2>/dev/null || true
    done
  ) &
}

start_events_watcher

# ---------------------------------------------------------------------------
# Step 4: Exec gc start --foreground
# ---------------------------------------------------------------------------

exec gc start --foreground
