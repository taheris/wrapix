#!/usr/bin/env bash
# Gas City container entrypoint — init checks, event watcher, then exec gc.
#
# 1. Prints informational summary of pending reviews (including scaffolding
#    beads created by ralph sync). Does not block — the mayor presents these
#    items to the human on attach.
# 2. Runs crash recovery — reconciles orphaned containers and worktrees.
# 3. Starts a background process watching podman events for service container
#    lifecycle events (die, oom, restart) and wakes the scout via gc nudge.
# 4. Stages gc home (via stage-gc-home.sh) and execs gc start --foreground.
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
# Step 0: Start dolt container on the city network
# ---------------------------------------------------------------------------

DOLT_CONTAINER="gc-${CITY_NAME}-dolt"
DOLT_PORT="${GC_DOLT_PORT:-3306}"

start_dolt_container() {
  local beads_dir="${GC_WORKSPACE}/.beads"
  local city_dolt="${GC_WORKSPACE}/.gc/dolt"
  [[ -d "$beads_dir/dolt" ]] || return 0

  # If the dolt container is already running, verify the port is actually responding.
  # A container can report Running=true while dolt inside has crashed.
  if podman inspect --format '{{.State.Running}}' "$DOLT_CONTAINER" 2>/dev/null | grep -q true; then
    if bash -c "echo > /dev/tcp/127.0.0.1/${DOLT_PORT}" 2>/dev/null; then
      echo "Dolt container already running (${DOLT_CONTAINER}:${DOLT_PORT})"
      export BEADS_DOLT_SERVER_HOST="127.0.0.1"
      export BEADS_DOLT_SERVER_PORT="$DOLT_PORT"
      return 0
    fi
    echo "Dolt container exists but port ${DOLT_PORT} not responding — restarting..."
    podman rm -f "$DOLT_CONTAINER" 2>/dev/null || true
  fi

  # Initialize city dolt from host on first start (one-time copy).
  # City dolt is completely separate from the host's — no conflicts.
  if [[ ! -d "$city_dolt/beads" ]]; then
    echo "Initializing city dolt from host .beads/dolt..."
    mkdir -p "$city_dolt"
    cp -a "$beads_dir/dolt/." "$city_dolt/"
  fi

  # Clean stale state in city's dolt dir (not host's)
  find "$city_dolt" -name "LOCK" -delete 2>/dev/null || true

  # Remove any stopped dolt container from a previous run
  podman rm -f "$DOLT_CONTAINER" 2>/dev/null || true

  # If port is already responding (stale container, host dolt, etc.), reuse it
  if bash -c "echo > /dev/tcp/127.0.0.1/${DOLT_PORT}" 2>/dev/null; then
    echo "Port ${DOLT_PORT} already in use — reusing existing dolt server"
    export BEADS_DOLT_SERVER_HOST="127.0.0.1"
    export BEADS_DOLT_SERVER_PORT="$DOLT_PORT"
    return 0
  fi

  # Grant root@% so agent containers on the podman network can connect.
  # Default dolt only creates root@localhost; containers appear as 10.89.x.x.
  (cd "$city_dolt" && \
    dolt sql -q 'CREATE USER IF NOT EXISTS root@"%"; GRANT ALL ON *.* TO root@"%" WITH GRANT OPTION' \
  ) 2>/dev/null || true

  echo "Starting dolt container on ${GC_PODMAN_NETWORK}..."
  podman run -d \
    --name "$DOLT_CONTAINER" \
    --entrypoint "" \
    --network "${GC_PODMAN_NETWORK:?}" \
    --userns=keep-id \
    -p "127.0.0.1:${DOLT_PORT}:${DOLT_PORT}" \
    -v "${city_dolt}:/doltdb:rw" \
    "${GC_AGENT_IMAGE:?}" \
    bash -c 'cd /doltdb && exec dolt sql-server -H 0.0.0.0 -P "$1"' -- "${DOLT_PORT}"

  # Wait for readiness — check from host via published port
  local retries=50
  while [[ $retries -gt 0 ]]; do
    if bash -c "echo > /dev/tcp/127.0.0.1/${DOLT_PORT}" 2>/dev/null; then
      echo "Dolt container ready (${DOLT_CONTAINER}:${DOLT_PORT})"
      export BEADS_DOLT_SERVER_HOST="127.0.0.1"
      export BEADS_DOLT_SERVER_PORT="$DOLT_PORT"
      return 0
    fi
    sleep 0.2
    retries=$((retries - 1))
  done

  echo "Error: dolt container did not become ready" >&2
  podman logs "$DOLT_CONTAINER" 2>&1 | tail -5 >&2
  exit 1
}

start_dolt_container

# NOTE: Do NOT write dolt-server.port to the host's .beads/ — that
# hijacks host-side bd to the city container, which can't pull/push
# (the file remote isn't mounted). gc home has its own port file
# via stage-gc-home.sh; host bd uses its own auto-started dolt.

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
# Step 4: exec gc start
# ---------------------------------------------------------------------------

# City dolt is managed by the container started in step 0.
# GC_DOLT=skip prevents gc's embedded dolt pack from starting a duplicate.
# gc home isolates gc from the host's .beads/ — gc writes dolt.auto-start
# and dolt-server.port to .gc/home/.beads/ instead of corrupting the host.
export GC_DOLT=skip
GC_CITY="$("${SCRIPT_DIR}/stage-gc-home.sh")"
export GC_CITY
cd "$GC_CITY"

# Run gc in background + wait so the shell stays alive for the trap.
# On exit (signal or natural), forward SIGTERM to gc and stop dolt.
_gc_cleanup() {
  [ -n "${_GC_PID:-}" ] && kill -TERM "$_GC_PID" 2>/dev/null || true
  [ -n "${_GC_PID:-}" ] && wait "$_GC_PID" 2>/dev/null || true
  podman stop -t 5 "$DOLT_CONTAINER" 2>/dev/null || true
  podman rm -f "$DOLT_CONTAINER" 2>/dev/null || true
}
trap _gc_cleanup EXIT INT TERM

gc start --foreground &
_GC_PID=$!
wait "$_GC_PID"
