#!/usr/bin/env bash
# Gas City exec:<script> provider — translates gc commands to podman operations.
#
# Called by gc as: provider.sh <method> <session-name> [args...]
#
# Environment variables (set by mkCity / entrypoint):
#   GC_CITY_NAME    — city name for container labeling
#   GC_WORKSPACE    — host workspace path (mounted into containers)
#   GC_AGENT_IMAGE  — OCI image for agent containers
#   GC_PODMAN_NETWORK — podman network name (wrapix-<city>)
set -euo pipefail

METHOD="${1:?missing method}"
SESSION="${2:-}"
shift 2 || shift $#

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

container_name() {
  echo "gc-${GC_CITY_NAME:?}-${SESSION:?}"
}

is_worker() {
  [[ "${SESSION}" == worker* ]]
}

# Standard labels applied to every container
container_labels() {
  local role
  if is_worker; then
    role="worker"
  elif [[ "${SESSION}" == scout* ]]; then
    role="scout"
  elif [[ "${SESSION}" == reviewer* ]]; then
    role="reviewer"
  else
    role="${SESSION}"
  fi

  echo "--label=gc-city=${GC_CITY_NAME}"
  echo "--label=gc-role=${role}"
  if is_worker && [[ -n "${GC_BEAD_ID:-}" ]]; then
    echo "--label=gc-bead=${GC_BEAD_ID}"
  fi
}

# Resource limit flags for a role
resource_flags() {
  local role="$1"
  local flags=""
  if [[ -n "${GC_CPUS:-}" ]]; then
    flags+=" --cpus=${GC_CPUS}"
  fi
  if [[ -n "${GC_MEMORY:-}" ]]; then
    flags+=" --memory=${GC_MEMORY}"
  fi
  echo "$flags"
}

# ---------------------------------------------------------------------------
# Persistent role helpers (scout, reviewer) — tmux as PID 1
# ---------------------------------------------------------------------------

persistent_start() {
  local name
  name="$(container_name)"

  # shellcheck disable=SC2046
  podman run -d \
    --name "$name" \
    --network "${GC_PODMAN_NETWORK:?}" \
    $(container_labels) \
    $(resource_flags "${SESSION}") \
    -v "${GC_WORKSPACE:?}:/workspace:ro" \
    -v "${GC_WORKSPACE}/.beads:/workspace/.beads:rw" \
    ${GC_SECRET_FLAGS:-} \
    -e "GC_ROLE=${SESSION}" \
    -e "GC_CITY_NAME=${GC_CITY_NAME}" \
    "${GC_AGENT_IMAGE:?}" \
    tmux new-session -d -s main \; wait-for -S init
}

persistent_exec() {
  local name
  name="$(container_name)"
  podman exec "$name" "$@"
}

# ---------------------------------------------------------------------------
# Ephemeral worker helpers — task command, no tmux
# ---------------------------------------------------------------------------

worker_start() {
  local name bead_id worktree_path
  name="$(container_name)"
  bead_id="${GC_BEAD_ID:?worker Start requires GC_BEAD_ID}"
  worktree_path=".wrapix/worktree/gc-${bead_id}"

  # Create git worktree on the host
  if [[ ! -d "${GC_WORKSPACE}/${worktree_path}" ]]; then
    git -C "${GC_WORKSPACE}" worktree add "${worktree_path}" -b "gc-${bead_id}" 2>/dev/null || \
      git -C "${GC_WORKSPACE}" worktree add "${worktree_path}" "gc-${bead_id}"
  fi

  # Build task file from bead description, acceptance criteria, and reviewer notes
  local task_file="${GC_WORKSPACE}/${worktree_path}/.task"
  {
    local bead_json
    bead_json="$(bd show "${bead_id}" --json 2>/dev/null)" || bead_json=""
    if [[ -n "$bead_json" ]]; then
      echo "$bead_json" | jq -r '.description // empty' 2>/dev/null
      local acceptance
      acceptance="$(echo "$bead_json" | jq -r '.acceptance // empty' 2>/dev/null)"
      if [[ -n "$acceptance" ]]; then
        printf '\n## Acceptance Criteria\n\n%s\n' "$acceptance"
      fi
    fi
    # Append reviewer notes from prior attempts (if any)
    local reviewer_notes
    reviewer_notes="$(bd meta get "${bead_id}" merge_failure 2>/dev/null)" || reviewer_notes=""
    if [[ -n "$reviewer_notes" ]]; then
      printf '\n## Prior Rejection\n\n%s\n' "$reviewer_notes"
    fi
  } > "$task_file" 2>/dev/null || true

  # shellcheck disable=SC2046
  podman run -d \
    --name "$name" \
    --network "${GC_PODMAN_NETWORK:?}" \
    $(container_labels) \
    $(resource_flags worker) \
    -v "${GC_WORKSPACE}/${worktree_path}:/workspace:rw" \
    -v "${GC_WORKSPACE}/.beads:/workspace/.beads:ro" \
    -v "${task_file}:/workspace/.task:ro" \
    ${GC_SECRET_FLAGS:-} \
    -e "GC_ROLE=worker" \
    -e "GC_BEAD_ID=${bead_id}" \
    -e "GC_CITY_NAME=${GC_CITY_NAME}" \
    -e "WRAPIX_PROMPT_FILE=/workspace/.task" \
    "${GC_AGENT_IMAGE}" \
    wrapix-agent run

  # Monitor worker exit in background — set bead metadata when done
  (
    podman wait "$name" >/dev/null 2>&1 || true

    # Determine commit range on the worker branch
    local branch="gc-${bead_id}"
    local merge_base
    merge_base="$(git -C "${GC_WORKSPACE}" merge-base main "${branch}" 2>/dev/null || echo "")"
    if [[ -n "$merge_base" ]]; then
      bd meta set "${bead_id}" commit_range "${merge_base}..${branch}" 2>/dev/null || true
      bd meta set "${bead_id}" branch_name "${branch}" 2>/dev/null || true
    fi
  ) &
}

# ---------------------------------------------------------------------------
# Method dispatch
# ---------------------------------------------------------------------------

case "$METHOD" in

  # --- Start ---
  Start)
    if is_worker; then
      worker_start
    else
      persistent_start
    fi
    ;;

  # --- Stop ---
  Stop)
    name="$(container_name)"
    podman stop "$name" 2>/dev/null || true
    podman rm -f "$name" 2>/dev/null || true
    ;;

  # --- Interrupt ---
  Interrupt)
    if is_worker; then
      : # no-op for workers
    else
      persistent_exec tmux send-keys -t main C-c
    fi
    ;;

  # --- IsRunning ---
  IsRunning)
    name="$(container_name)"
    running="$(podman inspect --format '{{.State.Running}}' "$name" 2>/dev/null || echo "false")"
    echo "$running"
    ;;

  # --- Attach ---
  Attach)
    if is_worker; then
      : # no-op
    else
      name="$(container_name)"
      podman exec -it "$name" tmux attach -t main
    fi
    ;;

  # --- Peek ---
  Peek)
    name="$(container_name)"
    if is_worker; then
      podman logs --tail "${1:-50}" "$name" 2>&1
    else
      persistent_exec tmux capture-pane -t main -p
    fi
    ;;

  # --- SendKeys ---
  SendKeys)
    if is_worker; then
      : # no-op
    else
      persistent_exec tmux send-keys -t main "$@"
    fi
    ;;

  # --- Nudge ---
  Nudge)
    if is_worker; then
      : # no-op
    else
      name="$(container_name)"
      # Wait for idle (no recent activity in last 2 seconds), then send keys
      _gc_last=0
      _gc_now=0
      for _ in $(seq 1 30); do
        _gc_last="$(persistent_exec tmux display-message -t main -p '#{pane_last_activity}' 2>/dev/null || echo "0")"
        _gc_now="$(date +%s)"
        if [[ $((_gc_now - _gc_last)) -ge 2 ]]; then
          break
        fi
        sleep 1
      done
      persistent_exec tmux send-keys -t main "$@"
    fi
    ;;

  # --- GetLastActivity ---
  GetLastActivity)
    if is_worker; then
      echo "0"
    else
      persistent_exec tmux display-message -t main -p '#{pane_last_activity}' 2>/dev/null || echo "0"
    fi
    ;;

  # --- ClearScrollback ---
  ClearScrollback)
    if is_worker; then
      : # no-op
    else
      persistent_exec tmux clear-history -t main
    fi
    ;;

  # --- IsAttached ---
  IsAttached)
    echo "false"
    ;;

  # --- ListRunning ---
  ListRunning)
    podman ps --filter "label=gc-city=${GC_CITY_NAME}" --format '{{.Names}}' 2>/dev/null
    ;;

  # --- SetMeta ---
  SetMeta)
    name="$(container_name)"
    key="${1:?SetMeta requires key}"
    value="${2:?SetMeta requires value}"
    # Store metadata as container labels via podman container rename is not
    # supported — use a label file inside the container instead
    podman exec "$name" sh -c "mkdir -p /tmp/gc-meta && echo '${value}' > /tmp/gc-meta/${key}" 2>/dev/null
    ;;

  # --- GetMeta ---
  GetMeta)
    name="$(container_name)"
    key="${1:?GetMeta requires key}"
    podman exec "$name" cat "/tmp/gc-meta/${key}" 2>/dev/null || echo ""
    ;;

  # --- RemoveMeta ---
  RemoveMeta)
    name="$(container_name)"
    key="${1:?RemoveMeta requires key}"
    podman exec "$name" rm -f "/tmp/gc-meta/${key}" 2>/dev/null || true
    ;;

  # --- CopyTo ---
  CopyTo)
    name="$(container_name)"
    src="${1:?CopyTo requires source path}"
    dst="${2:?CopyTo requires destination path}"
    podman cp "$src" "${name}:${dst}"
    ;;

  # --- ProcessAlive ---
  ProcessAlive)
    name="$(container_name)"
    if is_worker; then
      # Delegates to IsRunning for ephemeral workers
      running="$(podman inspect --format '{{.State.Running}}' "$name" 2>/dev/null || echo "false")"
      echo "$running"
    else
      process="${1:?ProcessAlive requires process name}"
      podman exec "$name" pgrep -x "$process" >/dev/null 2>&1 && echo "true" || echo "false"
    fi
    ;;

  # --- CheckImage ---
  CheckImage)
    image="${1:?CheckImage requires image name}"
    podman image exists "$image" 2>/dev/null && echo "true" || echo "false"
    ;;

  # --- Capabilities ---
  Capabilities)
    echo "{}"
    ;;

  *)
    echo "unknown method: $METHOD" >&2
    exit 1
    ;;
esac
