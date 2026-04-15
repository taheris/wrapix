#!/usr/bin/env bash
# wrapix-agent — CLI wrapper abstracting agent tool invocation.
#
# Translates role-based invocation into agent-specific CLI calls.
# Currently supports: claude
#
# Usage:
#   wrapix-agent run     — ephemeral worker: execute prompt file and exit
#   wrapix-agent session — persistent role: start interactive session
#
# Environment:
#   WRAPIX_AGENT       — agent type (default: claude)
#   WRAPIX_PROMPT_FILE — path to task prompt (required for 'run')
#   WRAPIX_DOCS_DIR    — docs directory for context (default: /workspace/docs)
#   WRAPIX_OUTPUT_FILE — capture output to file (optional)
set -euo pipefail

log() { echo "[wrapix-agent] $*" >&2; }

AGENT="${WRAPIX_AGENT:-claude}"
MODE="${1:-run}"
DOCS_DIR="${WRAPIX_DOCS_DIR:-/workspace/docs}"

# ---------------------------------------------------------------------------
# Prompt construction
# ---------------------------------------------------------------------------

# Build a prompt from the task file with docs context prepended.
build_prompt() {
  local prompt_file="${WRAPIX_PROMPT_FILE:?wrapix-agent run requires WRAPIX_PROMPT_FILE}"

  if [[ ! -f "$prompt_file" ]]; then
    echo "error: prompt file not found: ${prompt_file}" >&2
    exit 1
  fi

  # Prepend docs context when available
  if [[ -d "$DOCS_DIR" ]]; then
    echo "# Project Context"
    echo ""
    for doc in "${DOCS_DIR}"/*.md; do
      [[ -f "$doc" ]] || continue
      echo "## $(basename "$doc")"
      echo ""
      cat "$doc"
      echo ""
    done
    echo "---"
    echo ""
  fi

  echo "# Task"
  echo ""
  cat "$prompt_file"
}

# ---------------------------------------------------------------------------
# Agent: claude
# ---------------------------------------------------------------------------

claude_run() {
  if [[ -n "${WRAPIX_CITY_DIR:-}" ]]; then
    log "provisioning claude config"
    mkdir -p "$HOME/.claude"
    if [[ -f /etc/wrapix/claude-config.json ]]; then
      cp /etc/wrapix/claude-config.json "$HOME/.claude.json"
      log "copied claude-config.json"
    fi
    if [[ -f "${WRAPIX_CITY_DIR}/claude-settings.json" ]]; then
      cp "${WRAPIX_CITY_DIR}/claude-settings.json" "$HOME/.claude/settings.json"
      log "copied claude-settings.json"
    fi
    if [[ -f "${WRAPIX_CITY_DIR}/tmux.conf" ]]; then
      cp "${WRAPIX_CITY_DIR}/tmux.conf" "$HOME/.tmux.conf"
      log "copied tmux.conf"
    fi
  fi

  local prompt
  prompt="$(build_prompt)"
  log "prompt built (${#prompt} chars)"

  local -a claude_flags=(-p --dangerously-skip-permissions)
  if [[ -f "${WRAPIX_SYSTEM_PROMPT_FILE:-}" ]]; then
    claude_flags+=(--append-system-prompt-file "${WRAPIX_SYSTEM_PROMPT_FILE}")
  fi

  if [[ -n "${WRAPIX_CITY_DIR:-}" ]]; then
    log "starting claude in tmux session"
    local run_sh="/tmp/.wrapix-run.sh"
    {
      printf '#!/usr/bin/env bash\n'
      printf 'set -euo pipefail\n'
      printf 'claude'
      for arg in "${claude_flags[@]}"; do printf ' %q' "$arg"; done
      printf ' %q 2>&1 | tee /workspace/logs/worker.log\n' "$prompt"
      printf 'rc=${PIPESTATUS[0]}\n'
      printf 'echo "[wrapix-agent] claude exited with code ${rc}" >&2\n'
      printf 'tmux wait-for -S worker-exit\n'
    } > "$run_sh"
    chmod +x "$run_sh"

    tmux start-server
    tmux new-session -d -s worker "$run_sh"
    exec tmux wait-for worker-exit
  fi

  if [[ -n "${WRAPIX_OUTPUT_FILE:-}" ]]; then
    claude "${claude_flags[@]}" "$prompt" 2>&1 | tee "${WRAPIX_OUTPUT_FILE}"
  else
    claude "${claude_flags[@]}" "$prompt"
  fi
}

claude_session() {
  exec claude
}

# ---------------------------------------------------------------------------
# Agent registry — dispatch to the configured agent
# ---------------------------------------------------------------------------

case "$AGENT" in
  claude)
    case "$MODE" in
      run)     claude_run ;;
      session) claude_session ;;
      *)
        echo "unknown mode: ${MODE}" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "unknown agent: ${AGENT}" >&2
    echo "supported agents: claude" >&2
    exit 1
    ;;
esac
