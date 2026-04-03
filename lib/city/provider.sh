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

# gc's exec provider sends data on stdin for some methods (start, nudge,
# set-meta, process-alive). Read stdin once and store it.
STDIN_DATA=""
if [[ "$METHOD" == "start" || "$METHOD" == "nudge" || "$METHOD" == "set-meta" || "$METHOD" == "process-alive" ]]; then
  STDIN_DATA="$(cat)"
fi


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

container_name() {
  echo "gc-${GC_CITY_NAME:?}-${SESSION:?}"
}

is_worker() {
  [[ "${SESSION}" == worker* ]]
}

is_judge() {
  [[ "${SESSION}" == judge* ]]
}

# Standard labels applied to every container
container_labels() {
  local role
  if is_worker; then
    role="worker"
  elif [[ "${SESSION}" == scout* ]]; then
    role="scout"
  elif [[ "${SESSION}" == judge* ]]; then
    role="judge"
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
# Persistent role helpers (scout, judge) — tmux as PID 1
# ---------------------------------------------------------------------------

persistent_start() {
  local name ws_mode
  name="$(container_name)"

  # Judge needs read-write workspace access for merge operations;
  # other persistent roles (scout, mayor) get read-only.
  if is_judge; then
    ws_mode="rw"
  else
    ws_mode="ro"
  fi

  # shellcheck disable=SC2046
  podman run -d \
    --replace \
    --name "$name" \
    --network "${GC_PODMAN_NETWORK:?}" \
    --workdir /workspace \
    $(container_labels) \
    $(resource_flags "${SESSION}") \
    -v "${GC_WORKSPACE:?}:/workspace:${ws_mode}" \
    -v "${GC_WORKSPACE}/.beads:/workspace/.beads:rw" \
    ${GC_SECRET_FLAGS:-} \
    -e "GC_ROLE=${SESSION}" \
    -e "GC_CITY_NAME=${GC_CITY_NAME}" \
    -e "TERM=xterm" \
    "${GC_AGENT_IMAGE:?}" \
    bash -c 'tmux new-session -d -s main "claude --dangerously-skip-permissions" && exec tmux wait-for gc-shutdown'
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

  # gc does not pass GC_BEAD_ID — discover the bead via gc's pull model:
  # claim the first unassigned bead routed to worker.
  bead_id="${GC_BEAD_ID:-}"
  if [[ -z "$bead_id" ]]; then
    bead_id="$(cd "${GC_WORKSPACE}" && bd ready --metadata-field gc.routed_to=worker --unassigned --json 2>/dev/null \
      | jq -r '.[0].id // empty' 2>/dev/null)" || bead_id=""
  fi
  if [[ -z "$bead_id" ]]; then
    echo "worker Start: no bead routed to worker" >&2
    return 1
  fi
  # Claim the bead so other workers don't pick it up
  (cd "${GC_WORKSPACE}" && bd update "$bead_id" --claim) 2>/dev/null || true
  worktree_path=".wrapix/worktree/gc-${bead_id}"

  # Create git worktree on the host
  if [[ ! -d "${GC_WORKSPACE}/${worktree_path}" ]]; then
    git -C "${GC_WORKSPACE}" worktree add "${worktree_path}" -b "gc-${bead_id}" 2>/dev/null || \
      git -C "${GC_WORKSPACE}" worktree add "${worktree_path}" "gc-${bead_id}"
  fi

  # Rewrite worktree .git reference for container-internal mount path.
  # The host worktree's .git file points to <host-abs>/.git/worktrees/gc-<id>,
  # which doesn't exist inside the container. Mount the main .git at /mnt/git
  # and rewrite the gitdir to match.
  echo "gitdir: /mnt/git/worktrees/gc-${bead_id}" > "${GC_WORKSPACE}/${worktree_path}/.git"

  # Build task file from bead description, acceptance criteria, and judge notes
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
    # Append judge notes from prior attempts (if any)
    local judge_notes
    judge_notes="$(bd show "${bead_id}" --json 2>/dev/null | jq -r '.[0].metadata.merge_failure // empty' 2>/dev/null)" || judge_notes=""
    if [[ -n "$judge_notes" ]]; then
      printf '\n## Prior Rejection\n\n%s\n' "$judge_notes"
    fi
  } > "$task_file" 2>/dev/null || true

  # Record dispatch timestamp for cooldown pacing
  local state_dir="${GC_WORKSPACE}/.wrapix/state"
  mkdir -p "$state_dir"
  date +%s > "$state_dir/last-dispatch"

  # shellcheck disable=SC2046
  podman run -d \
    --replace \
    --name "$name" \
    --network "${GC_PODMAN_NETWORK:?}" \
    --workdir /workspace \
    $(container_labels) \
    $(resource_flags worker) \
    -v "${GC_WORKSPACE}/${worktree_path}:/workspace:rw" \
    -v "${GC_WORKSPACE}/.git:/mnt/git:rw" \
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
      bd update "${bead_id}" --set-metadata "commit_range=${merge_base}..${branch}" 2>/dev/null || true
      bd update "${bead_id}" --set-metadata "branch_name=${branch}" 2>/dev/null || true
    fi
  ) &
}

# ---------------------------------------------------------------------------
# Method dispatch
# ---------------------------------------------------------------------------

case "$METHOD" in

  start)
    if is_worker; then
      worker_start
    else
      persistent_start
    fi
    ;;

  stop)
    name="$(container_name)"
    podman stop "$name" 2>/dev/null || true
    podman rm -f "$name" 2>/dev/null || true
    ;;

  interrupt)
    if is_worker; then
      : # no-op for workers
    else
      persistent_exec tmux send-keys -t main C-c
    fi
    ;;

  is-running)
    name="$(container_name)"
    running="$(podman inspect --format '{{.State.Running}}' "$name" 2>/dev/null || echo "false")"
    echo "$running"
    ;;

  attach)
    if is_worker; then
      : # no-op
    else
      name="$(container_name)"
      podman exec -it "$name" tmux attach -t main
    fi
    ;;

  peek)
    name="$(container_name)"
    if is_worker; then
      podman logs --tail "${1:-50}" "$name" 2>&1
    else
      persistent_exec tmux capture-pane -t main -p
    fi
    ;;

  send-keys)
    if is_worker; then
      : # no-op
    else
      persistent_exec tmux send-keys -t main "$@"
    fi
    ;;

  nudge)
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
      # gc sends nudge message on stdin; send it as tmux keys
      if [[ -n "$STDIN_DATA" ]]; then
        persistent_exec tmux send-keys -t main "$STDIN_DATA" Enter
      elif [[ $# -gt 0 ]]; then
        persistent_exec tmux send-keys -t main "$@"
      fi
    fi
    ;;

  get-last-activity)
    if is_worker; then
      echo ""
    else
      # gc expects RFC3339 or empty; tmux returns Unix epoch
      _gc_epoch="$(persistent_exec tmux display-message -t main -p '#{pane_last_activity}' 2>/dev/null)" || _gc_epoch=""
      if [[ -n "$_gc_epoch" && "$_gc_epoch" != "0" ]]; then
        date -u -d "@${_gc_epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo ""
      else
        echo ""
      fi
    fi
    ;;

  clear-scrollback)
    if is_worker; then
      : # no-op
    else
      persistent_exec tmux clear-history -t main
    fi
    ;;

  is-attached)
    echo "false"
    ;;

  list-running)
    podman ps --filter "label=gc-city=${GC_CITY_NAME}" --format '{{.Names}}' 2>/dev/null
    ;;

  set-meta)
    name="$(container_name)"
    key="${1:?set-meta requires key}"
    # gc sends value on stdin; fall back to positional arg for direct calls
    value="${STDIN_DATA:-${2:-}}"
    # Store metadata as a file inside the container
    podman exec "$name" sh -c "mkdir -p /tmp/gc-meta && echo '${value}' > /tmp/gc-meta/${key}" 2>/dev/null
    ;;

  get-meta)
    name="$(container_name)"
    key="${1:?get-meta requires key}"
    podman exec "$name" cat "/tmp/gc-meta/${key}" 2>/dev/null || echo ""
    ;;

  remove-meta)
    name="$(container_name)"
    key="${1:?remove-meta requires key}"
    podman exec "$name" rm -f "/tmp/gc-meta/${key}" 2>/dev/null || true
    ;;

  copy-to)
    name="$(container_name)"
    src="${1:?copy-to requires source path}"
    dst="${2:?copy-to requires destination path}"
    podman cp "$src" "${name}:${dst}"
    ;;

  process-alive)
    name="$(container_name)"
    # gc sends process names on stdin (one per line); fall back to positional arg
    _gc_proc_names="${STDIN_DATA:-${1:-}}"
    if [[ -n "$_gc_proc_names" ]]; then
      # Check each process name — return true if any is alive
      while IFS= read -r pname; do
        [[ -z "$pname" ]] && continue
        if podman exec "$name" pgrep -x "$pname" >/dev/null 2>&1; then
          echo "true"
          exit 0
        fi
      done <<< "$_gc_proc_names"
      echo "false"
    else
      # No process names — check if the container itself is running
      podman inspect --format '{{.State.Running}}' "$name" 2>/dev/null || echo "false"
    fi
    ;;

  check-image)
    image="${1:?check-image requires image name}"
    podman image exists "$image" 2>/dev/null && echo "true" || echo "false"
    ;;

  run-live)
    : # unsupported by exec provider — no-op
    ;;

  capabilities)
    echo "{}"
    ;;

  *)
    # Exit 2 = unknown operation (forward-compatible no-op per gc exec protocol)
    exit 2
    ;;
esac
