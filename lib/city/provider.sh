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
  local prefix="gc-${GC_CITY_NAME:?}-"
  # Avoid double-prefixing: gc passes bare names on first start
  # ("mayor") but fully-qualified names after config reload ("gc-dev-mayor").
  if [[ "${SESSION:?}" == "${prefix}"* ]]; then
    echo "${SESSION}"
  else
    echo "${prefix}${SESSION}"
  fi
}

is_worker() {
  [[ "${SESSION}" == worker* || "${SESSION}" == *-worker* ]]
}

is_judge() {
  [[ "${SESSION}" == judge* || "${SESSION}" == *-judge* ]]
}

is_mayor() {
  [[ "${SESSION}" == mayor* || "${SESSION}" == *-mayor* ]]
}

# Base role name (mayor, scout, judge, worker) regardless of session prefix
role_name() {
  if is_worker; then echo "worker"
  elif is_mayor; then echo "mayor"
  elif is_judge; then echo "judge"
  else echo "scout"
  fi
}

# Stage .beads config files for container-local database isolation.
# Each container gets its own .beads with just config — no host mount.
stage_beads() {
  local staging
  staging="${GC_WORKSPACE}/.gc/beads-staging/$(container_name)"
  rm -rf "$staging"
  mkdir -p "$staging"
  chmod 700 "$staging"
  local beads="${GC_WORKSPACE}/.beads"
  [ -f "$beads/config.yaml" ] && cp "$beads/config.yaml" "$staging/"
  [ -f "$beads/metadata.json" ] && cp "$beads/metadata.json" "$staging/"
  [ -f "$beads/issues.jsonl" ] && cp "$beads/issues.jsonl" "$staging/"
  echo "$staging"
}

# Standard labels applied to every container
container_labels() {
  local role
  if is_worker; then
    role="worker"
  elif [[ "${SESSION}" == scout* || "${SESSION}" == *-scout* ]]; then
    role="scout"
  elif is_judge; then
    role="judge"
  elif is_mayor; then
    role="mayor"
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

  # Containers reach dolt via podman network DNS (container name), not
  # localhost. The entrypoint sets GC_BEADS_DOLT_CONTAINER to the
  # beads-dolt container name and attaches it to the city network.
  local dolt_host="${GC_BEADS_DOLT_CONTAINER:?provider requires GC_BEADS_DOLT_CONTAINER}"
  local dolt_port="${BEADS_DOLT_SERVER_PORT:?provider requires BEADS_DOLT_SERVER_PORT}"

  local role beads_staging
  role="$(role_name)"
  beads_staging="$(stage_beads)"

  # shellcheck disable=SC2046
  podman run -d \
    --replace \
    --name "$name" \
    --entrypoint "" \
    --network "${GC_PODMAN_NETWORK:?}" \
    --userns=keep-id \
    --passwd-entry "wrapix:*:$(id -u):$(id -g)::/home/wrapix:/bin/bash" \
    --mount type=tmpfs,destination=/home/wrapix,U=true \
    --mount type=tmpfs,destination=/tmp,U=true \
    --workdir /workspace \
    $(container_labels) \
    $(resource_flags "${SESSION}") \
    -v "${GC_WORKSPACE:?}:/workspace:${ws_mode}" \
    -v "${beads_staging}:/workspace/.beads" \
    -v "${GC_WORKSPACE}/.wrapix:/workspace/.wrapix:rw" \
    -v "${GC_WORKSPACE}/.claude:/workspace/.claude:rw" \
    ${GC_SECRET_FLAGS:-} \
    -e "BEADS_DOLT_AUTO_START=0" \
    -e "BEADS_DOLT_SERVER_HOST=${dolt_host}" \
    -e "BEADS_DOLT_SERVER_PORT=${dolt_port}" \
    -e "GC_DOLT_HOST=${dolt_host}" \
    -e "GC_DOLT_PORT=${dolt_port}" \
    -e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}" \
    -e "GC_CITY_NAME=${GC_CITY_NAME}" \
    -e "GC_SESSION=${SESSION}" \
    -e "GC_AGENT=${role}" \
    -e "GC_ALIAS=${role}" \
    -e "WRAPIX_CITY_DIR=/workspace/.wrapix/city/current" \
    -e "HOME=/home/wrapix" \
    -e "TERM=xterm-256color" \
    "${GC_AGENT_IMAGE:?}" \
    bash -c '
      # shellcheck disable=SC1091
      [[ -f /git-ssh-setup.sh ]] && . /git-ssh-setup.sh
      mkdir -p "$HOME/.claude"
      cp /etc/wrapix/claude-config.json "$HOME/.claude.json"
      cp "$WRAPIX_CITY_DIR/claude-settings.json" "$HOME/.claude/settings.json"
      cp "$WRAPIX_CITY_DIR/tmux.conf" "$HOME/.tmux.conf"
      tmux new-session -d -s "$GC_AGENT" "claude --dangerously-skip-permissions"
      exec tmux wait-for gc-shutdown
    '
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

  # Must match worker scale_check in city.toml: `bd ready` excludes
  # in_progress, which would let orphaned beads spin the reconciler.
  bead_id="${GC_BEAD_ID:-}"
  if [[ -z "$bead_id" ]]; then
    bead_id="$(cd "${GC_WORKSPACE}" && bd list --metadata-field gc.routed_to=worker --status open,in_progress --no-assignee --json 2>/dev/null \
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

  cp "${GC_WORKSPACE}/.wrapix/city/current/prompts/worker.md" \
     "${GC_WORKSPACE}/${worktree_path}/.role-prompt"

  # Record dispatch timestamp for cooldown pacing
  local state_dir="${GC_WORKSPACE}/.wrapix/state"
  mkdir -p "$state_dir"
  date +%s > "$state_dir/last-dispatch"

  # Prefer env var (set by entrypoint) over port file (can be corrupted by
  # agents running bd dolt start inside containers with .beads mounted rw).
  # Containers reach dolt via podman network DNS (container name), not
  # localhost. The entrypoint sets GC_BEADS_DOLT_CONTAINER to the
  # beads-dolt container name and attaches it to the city network.
  local dolt_host="${GC_BEADS_DOLT_CONTAINER:?provider requires GC_BEADS_DOLT_CONTAINER}"
  local dolt_port="${BEADS_DOLT_SERVER_PORT:?provider requires BEADS_DOLT_SERVER_PORT}"
  local beads_staging
  beads_staging="$(stage_beads)"

  # shellcheck disable=SC2046
  podman run -d \
    --replace \
    --name "$name" \
    --entrypoint "" \
    --network "${GC_PODMAN_NETWORK:?}" \
    --userns=keep-id \
    --passwd-entry "wrapix:*:$(id -u):$(id -g)::/home/wrapix:/bin/bash" \
    --mount type=tmpfs,destination=/home/wrapix,U=true \
    --mount type=tmpfs,destination=/tmp,U=true \
    --workdir /workspace \
    $(container_labels) \
    $(resource_flags worker) \
    -v "${GC_WORKSPACE}/${worktree_path}:/workspace:rw" \
    -v "${GC_WORKSPACE}/.git:/mnt/git:rw" \
    -v "${beads_staging}:/workspace/.beads" \
    -v "${task_file}:/workspace/.task:ro" \
    ${GC_SECRET_FLAGS:-} \
    -e "BEADS_DOLT_AUTO_START=0" \
    -e "BEADS_DOLT_SERVER_HOST=${dolt_host}" \
    -e "BEADS_DOLT_SERVER_PORT=${dolt_port}" \
    -e "GC_DOLT_HOST=${dolt_host}" \
    -e "GC_DOLT_PORT=${dolt_port}" \
    -e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}" \
    -e "GC_BEAD_ID=${bead_id}" \
    -e "GC_CITY_NAME=${GC_CITY_NAME}" \
    -e "GC_SESSION=worker" \
    -e "GC_AGENT=worker" \
    -e "WRAPIX_CITY_DIR=/workspace/.wrapix/city/current" \
    -e "HOME=/home/wrapix" \
    -e "WRAPIX_PROMPT_FILE=/workspace/.task" \
    -e "WRAPIX_SYSTEM_PROMPT_FILE=/workspace/.role-prompt" \
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
  ) </dev/null >/dev/null 2>&1 &
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
      persistent_exec tmux send-keys -t "$(role_name)" C-c
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
      podman exec -it "$name" tmux attach -t "$(role_name)"
      # Restore terminal state after detach (cursor, alternate screen)
      printf '\033[?25h\033[?1049l' 2>/dev/null
      stty sane 2>/dev/null || true
    fi
    ;;

  peek)
    name="$(container_name)"
    if is_worker; then
      podman logs --tail "${1:-50}" "$name" 2>&1
    else
      persistent_exec tmux capture-pane -t "$(role_name)" -p
    fi
    ;;

  send-keys)
    if is_worker; then
      : # no-op
    else
      persistent_exec tmux send-keys -t "$(role_name)" "$@"
    fi
    ;;

  nudge)
    if is_worker; then
      : # no-op
    else
      name="$(container_name)"
      tmux_target="$(role_name)"
      # Wait for idle (no recent activity in last 2 seconds), then send keys
      _gc_last=0
      _gc_now=0
      for _ in $(seq 1 30); do
        _gc_last="$(persistent_exec tmux display-message -t "$tmux_target" -p '#{pane_last_activity}' 2>/dev/null || echo "0")"
        _gc_now="$(date +%s)"
        if [[ $((_gc_now - _gc_last)) -ge 2 ]]; then
          break
        fi
        sleep 1
      done
      # gc sends nudge message on stdin; send it as tmux keys
      if [[ -n "$STDIN_DATA" ]]; then
        persistent_exec tmux send-keys -t "$tmux_target" "$STDIN_DATA" Enter
      elif [[ $# -gt 0 ]]; then
        persistent_exec tmux send-keys -t "$tmux_target" "$@"
      fi
    fi
    ;;

  get-last-activity)
    if is_worker; then
      echo ""
    else
      # gc expects RFC3339 or empty; tmux returns Unix epoch
      _gc_epoch="$(persistent_exec tmux display-message -t "$(role_name)" -p '#{pane_last_activity}' 2>/dev/null)" || _gc_epoch=""
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
      persistent_exec tmux clear-history -t "$(role_name)"
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
