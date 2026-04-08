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
# Step 0: Ensure dolt is healthy (clean stale locks, verify connectivity)
# ---------------------------------------------------------------------------

ensure_dolt_healthy() {
  local beads_dir="${GC_WORKSPACE}/.beads"
  [[ -d "$beads_dir/dolt" ]] || return 0

  local port_file="$beads_dir/dolt-server.port"
  local host_file="$beads_dir/dolt-server.host"
  local config="$beads_dir/dolt/config.yaml"
  local port=""
  [[ -f "$port_file" ]] && port="$(cat "$port_file" 2>/dev/null)"

  # Discover podman bridge gateway — containers reach the host via this IP.
  # Falls back to 127.0.0.1 when running outside a city (no podman network).
  local gateway="127.0.0.1"
  if [[ -n "${GC_PODMAN_NETWORK:-}" ]]; then
    gateway="$(podman network inspect "${GC_PODMAN_NETWORK}" 2>/dev/null \
      | jq -r '.[0].subnets[0].gateway // empty' 2>/dev/null)" || gateway=""
    gateway="${gateway:-127.0.0.1}"
  fi

  # Persist gateway for scale_check commands and other host-side consumers
  echo "$gateway" > "$host_file"

  # Check if dolt config needs a bind address update
  local needs_restart=false
  if [[ -f "$config" ]]; then
    local current_host
    current_host="$(awk '/^  host:/ {print $2}' "$config" 2>/dev/null)" || current_host=""
    if [[ "$current_host" != "$gateway" ]]; then
      sed -i "s/^  host: .*/  host: ${gateway}/" "$config"
      needs_restart=true
    fi
  fi

  # If a dolt process is already running and bind address hasn't changed, trust it
  if pgrep -f "dolt sql-server" &>/dev/null; then
    if [[ "$needs_restart" == "true" ]]; then
      echo "Dolt bind address changed → restarting on ${gateway}..."
      bd dolt stop 2>/dev/null || true
      sleep 1
    else
      if [[ -n "$port" ]]; then
        export BEADS_DOLT_PORT="$port"
        export BEADS_DOLT_HOST="$gateway"
      fi
      return 0
    fi
  fi

  # Clean stale locks and start fresh
  echo "Starting dolt server on ${gateway}..."
  find "$beads_dir/dolt" -name "LOCK" -delete 2>/dev/null || true
  rm -f "$beads_dir/dolt-server.lock" "$beads_dir/dolt-server.pid" 2>/dev/null || true

  if bd dolt start 2>/dev/null; then
    [[ -f "$port_file" ]] && port="$(cat "$port_file" 2>/dev/null)"
    if [[ -n "$port" ]]; then
      export BEADS_DOLT_PORT="$port"
      export BEADS_DOLT_HOST="$gateway"
      echo "Dolt server started on ${gateway}:${port}"
    fi
  else
    echo "Warning: could not start dolt server — bd commands may fail"
  fi
}

ensure_dolt_healthy

# ---------------------------------------------------------------------------
# Step 0.5: Generate fresh session IDs for persistent roles
# ---------------------------------------------------------------------------

generate_session_ids() {
  local sessions_dir="${GC_WORKSPACE}/.gc/sessions"
  mkdir -p "$sessions_dir"

  for role in mayor scout judge; do
    cat /proc/sys/kernel/random/uuid > "$sessions_dir/${role}.session-id"
  done
  echo "Generated fresh session IDs for persistent roles"
}

generate_session_ids

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

# recovery.sh lives alongside the other city scripts in .gc/scripts/ —
# the app and shellHook copy them there from the Nix store.  Fall back to
# SCRIPT_DIR for the integration test which patches this line.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECOVERY="${GC_WORKSPACE:-.}/.gc/scripts/recovery.sh"
if [[ ! -x "$RECOVERY" ]]; then
  RECOVERY="${SCRIPT_DIR}/recovery.sh"
fi
"$RECOVERY"

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
