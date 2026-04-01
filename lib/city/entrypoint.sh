#!/usr/bin/env bash
# Gas City container entrypoint — init checks, event watcher, then exec gc.
#
# 1. Checks for unresolved scaffolding beads (created by ralph sync).
#    If any exist, prints warning listing pending reviews and exits.
# 2. Starts a background process watching podman events for service container
#    lifecycle events (die, oom, restart) and wakes the scout via gc nudge.
# 3. Execs gc start --foreground
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
# Step 1: Check for unresolved scaffolding beads
# ---------------------------------------------------------------------------

check_scaffolding_beads() {
  local pending
  pending="$(bd human list --json 2>/dev/null)" || pending="[]"

  # Filter for scaffolding-related beads (created by ralph sync)
  local scaffolding
  scaffolding="$(echo "$pending" | jq -r '
    [.[] | select(.title | test("scaffol|docs/|Scaffol"; "i"))]
  ' 2>/dev/null)" || scaffolding="[]"

  local count
  count="$(echo "$scaffolding" | jq 'length' 2>/dev/null)" || count="0"

  if [[ "$count" -gt 0 ]]; then
    echo "ERROR: ${count} unresolved scaffolding bead(s) require director review before starting gc." >&2
    echo "" >&2
    echo "Pending reviews:" >&2
    echo "$scaffolding" | jq -r '.[] | "  - \(.id): \(.title)"' 2>/dev/null >&2
    echo "" >&2
    echo "Review and resolve these beads, then restart:" >&2
    echo "  bd human respond <id>    # review each bead" >&2
    echo "  bd human dismiss <id>    # dismiss after review" >&2
    return 1
  fi

  return 0
}

if ! check_scaffolding_beads; then
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Start podman events watcher (background)
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
      gc nudge scout --message "Service container event: ${container_name} ${event_type}" 2>/dev/null || true
    done
  ) &
}

start_events_watcher

# ---------------------------------------------------------------------------
# Step 3: Exec gc start --foreground
# ---------------------------------------------------------------------------

exec gc start --foreground
