#!/usr/bin/env bash
# Gas City entrypoint — dolt, recovery, events, gc home, then gc start.
#
# 0. Starts dolt container on the city network.
# 1. Prints informational summary of pending reviews (including scaffolding
#    beads created by ralph sync). Does not block — the mayor presents these
#    items to the human on attach.
# 2. Runs crash recovery — reconciles orphaned containers and worktrees.
# 3. Starts a background process watching podman events for service container
#    lifecycle events (die, oom, restart) and wakes the scout via gc nudge.
# 4. Stages gc home (via stage-gc-home.sh) and runs gc start --foreground
#    in the background with a trap to clean up dolt on exit.
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
# Step 0: Ensure the per-workspace beads-dolt container is running and
#         attach it to the city podman network so role containers can
#         reach it by container hostname.
# ---------------------------------------------------------------------------

if ! command -v beads-dolt >/dev/null 2>&1; then
  echo "Error: beads-dolt not on PATH" >&2
  exit 1
fi

beads-dolt start "$GC_WORKSPACE"
DOLT_CONTAINER="$(beads-dolt name "$GC_WORKSPACE")"
DOLT_PORT="$(beads-dolt port "$GC_WORKSPACE")"
DOLT_HOST="127.0.0.1"

beads-dolt attach "${GC_PODMAN_NETWORK:?}" "$GC_WORKSPACE"

export BEADS_DOLT_SERVER_HOST="$DOLT_HOST"
export BEADS_DOLT_SERVER_PORT="$DOLT_PORT"
export BEADS_DOLT_AUTO_START=0
export GC_DOLT_PORT="$DOLT_PORT"
export GC_BEADS_DOLT_CONTAINER="$DOLT_CONTAINER"

# Substitute the dolt port sentinel in city.toml. The host field is
# already 127.0.0.1 (host gc daemon needs that); the provider script
# overrides BEADS_DOLT_SERVER_HOST per-container with $DOLT_CONTAINER.
if [[ -f "${GC_WORKSPACE}/city.toml" ]]; then
  sed -i \
    -e "s|port = 99999|port = ${DOLT_PORT}|" \
    "${GC_WORKSPACE}/city.toml"
fi

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

# All city scripts (recovery, stage-gc-home, etc.) are co-located in the
# same Nix derivation (scriptsDir), so SCRIPT_DIR always has siblings.
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
# Step 4: stage gc home and run gc start
# ---------------------------------------------------------------------------

# City dolt is managed by the container started in step 0.
# GC_DOLT=skip prevents gc's embedded dolt pack from starting a duplicate.
# gc home isolates gc from the host's .beads/ — gc writes dolt.auto-start
# and dolt-server.port to .gc/home/.beads/ instead of corrupting the host.
export GC_DOLT=skip
GC_CITY="$("${SCRIPT_DIR}/stage-gc-home.sh")"
export GC_CITY
cd "$GC_CITY"

# Symlink controller socket from workspace .gc/ so host-side `gc stop`
# (which resolves cityPath to the workspace, not gc home) can find it.
# The daemon creates the socket at gc_home/.gc/controller.sock; this
# symlink lets the workspace path reach it.
mkdir -p "${GC_WORKSPACE}/.gc"
ln -sfn "$GC_CITY/.gc/controller.sock" "${GC_WORKSPACE}/.gc/controller.sock"
ln -sfn "$GC_CITY/.gc/controller.lock" "${GC_WORKSPACE}/.gc/controller.lock"
ln -sfn "$GC_CITY/.gc/controller.token" "${GC_WORKSPACE}/.gc/controller.token"

# Run gc in background + wait so the shell stays alive for the trap.
# On exit (signal or natural), forward SIGTERM to gc. The beads-dolt
# container is shared with the devShell and persists across city runs.
_gc_cleanup() {
  [ -n "${_GC_PID:-}" ] && kill -TERM "$_GC_PID" 2>/dev/null || true
  [ -n "${_GC_PID:-}" ] && wait "$_GC_PID" 2>/dev/null || true
  # Detach (but don't stop) the beads-dolt container from this city's network.
  podman network disconnect "${GC_PODMAN_NETWORK}" "$DOLT_CONTAINER" 2>/dev/null || true
  rm -f "${GC_WORKSPACE}/.gc/controller.sock" "${GC_WORKSPACE}/.gc/controller.lock" "${GC_WORKSPACE}/.gc/controller.token"
}
trap _gc_cleanup EXIT INT TERM

gc start --foreground &
_GC_PID=$!
wait "$_GC_PID"
