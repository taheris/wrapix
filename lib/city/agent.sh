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
  local prompt
  prompt="$(build_prompt)"

  local -a claude_flags=(-p)
  if [[ -f "${WRAPIX_SYSTEM_PROMPT_FILE:-}" ]]; then
    claude_flags+=(--append-system-prompt-file "${WRAPIX_SYSTEM_PROMPT_FILE}")
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
