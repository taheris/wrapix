#!/bin/bash
set -euo pipefail

# Record session start for audit trail
SESSION_START_EPOCH=$(date +%s)
SESSION_START_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cd /workspace

# Configure SSH to use deploy key if available
# Use GIT_SSH_COMMAND instead of config file to avoid permission issues
# (the .ssh directory may be created by the known_hosts bind mount with root ownership)
if [ -n "${WRAPIX_DEPLOY_KEY:-}" ] && [ -f "$WRAPIX_DEPLOY_KEY" ]; then
  export GIT_SSH_COMMAND="ssh -i $WRAPIX_DEPLOY_KEY -o IdentitiesOnly=yes"
fi

# Configure git SSH signing using separate signing key
# (GitHub doesn't allow same key for deploy and signing)
if [ -n "${WRAPIX_SIGNING_KEY:-}" ] && [ -f "$WRAPIX_SIGNING_KEY" ]; then
  git config --global gpg.format ssh
  git config --global user.signingkey "$WRAPIX_SIGNING_KEY"

  # Create allowed_signers for signature verification
  # Write temp file to writable location (signing key dir may be read-only mount)
  mkdir -p "$HOME/.config/git"
  PUBKEY_TMP="$HOME/.config/git/signing_key.pub.tmp"
  if ssh-keygen -y -f "$WRAPIX_SIGNING_KEY" > "$PUBKEY_TMP" 2>/dev/null; then
    echo "${GIT_AUTHOR_EMAIL:-sandbox@wrapix.dev} $(cat "$PUBKEY_TMP")" > "$HOME/.config/git/allowed_signers"
    rm "$PUBKEY_TMP"
    git config --global gpg.ssh.allowedSignersFile "$HOME/.config/git/allowed_signers"
  fi

  # Enable auto-signing by default when signing key is configured
  # Set WRAPIX_GIT_SIGN=0 to disable
  if [ "${WRAPIX_GIT_SIGN:-1}" != "0" ]; then
    git config --global commit.gpgsign true
  fi
fi

# Initialize Claude config (always update to match container image)
mkdir -p "$HOME/.claude"
cp /etc/wrapix/claude-config.json "$HOME/.claude.json"
cp /etc/wrapix/claude-settings.json "$HOME/.claude/settings.json"
chmod 644 "$HOME/.claude.json" "$HOME/.claude/settings.json"

# Initialize rustup with stable toolchain and rust-analyzer if RUSTUP_HOME is set
# Use "rustup which cargo" instead of "rustup show active-toolchain" because the latter
# can succeed when toolchain is configured but binaries don't exist (e.g., stale RUSTUP_HOME)
if [ -n "${RUSTUP_HOME:-}" ] && command -v rustup &>/dev/null; then
  if ! rustup which cargo &>/dev/null 2>&1; then
    rustup default stable
    rustup component add rust-analyzer
  fi
fi

# Initialize container-local beads database
# Detect backend from metadata.json and use appropriate init strategy
# --skip-hooks: prek manages git hooks, bd must not touch them
# --skip-merge-driver: prevents bd from creating .gitattributes
if [ -f /workspace/.beads/config.yaml ]; then
  PREFIX=$(yq -r '.["issue-prefix"] // ""' /workspace/.beads/config.yaml 2>/dev/null || echo "")
  if [ -n "$PREFIX" ]; then
    # Check for Dolt backend (metadata.json will have "backend": "dolt" after migration)
    BACKEND=$(jq -r '.backend // "sqlite"' /workspace/.beads/metadata.json 2>/dev/null || echo "sqlite")

    # Dolt remote lives in beads branch worktree
    DOLT_REMOTE="/workspace/.git/beads-worktrees/beads/.beads/dolt-remote"
    if [ "$BACKEND" = "dolt" ] && [ -d "$DOLT_REMOTE" ]; then
      # Dolt mode: clone dolt-remote as working database with proper tracking refs
      # bd connects to database "beads_${PREFIX}" (the directory name under .beads/dolt/)
      mkdir -p /workspace/.beads/dolt
      dolt clone "file://$DOLT_REMOTE" "/workspace/.beads/dolt/beads_${PREFIX}" 2>/dev/null || true
      # Defensive: restore .gitignore in case future changes overwrite it
      git checkout -- .beads/.gitignore 2>/dev/null || true
    elif [ -f /workspace/.beads/issues.jsonl ]; then
      # Legacy fallback: init from JSONL (pre-Dolt repos)
      bd init --prefix "$PREFIX" --from-jsonl --quiet --skip-hooks --skip-merge-driver
    fi
    # bd init generates AGENTS.md; restore workspace copy if it existed
    git checkout -- AGENTS.md 2>/dev/null || true
  fi
fi

# Build system prompt with optional context pinning
SYSTEM_PROMPT=$(cat /etc/wrapix-prompt)

# Context pinning: append specs/README.md if it exists
if [ -f /workspace/specs/README.md ]; then
  SYSTEM_PROMPT="$SYSTEM_PROMPT

## Project Context (from specs/README.md)

$(cat /workspace/specs/README.md)"
fi

# Apply network filtering when WRAPIX_NETWORK=limit
# Resolves allowlisted domains to IPs and configures iptables OUTPUT chain
if [ "${WRAPIX_NETWORK:-open}" = "limit" ]; then
  echo "Network mode: limit (restricting outbound to allowlist)" >&2

  if iptables -P OUTPUT DROP 2>/dev/null; then
    # Allow loopback traffic
    iptables -A OUTPUT -o lo -j ACCEPT

    # Allow established/related connections (responses to allowed requests)
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Allow DNS (needed to resolve allowlisted domains at runtime)
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

    # Resolve and allow each domain in the allowlist
    IFS=',' read -ra DOMAINS <<< "${WRAPIX_NETWORK_ALLOWLIST:-}"
    for domain in "${DOMAINS[@]}"; do
      [ -z "$domain" ] && continue
      # Resolve domain to IPv4 addresses
      while IFS=' ' read -r ip _rest; do
        [ -z "$ip" ] && continue
        iptables -A OUTPUT -d "$ip" -j ACCEPT
      done < <(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    done

    # IPv6: set default drop policy and allow same exceptions
    if ip6tables -P OUTPUT DROP 2>/dev/null; then
      ip6tables -A OUTPUT -o lo -j ACCEPT
      ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
      ip6tables -A OUTPUT -p udp --dport 53 -j ACCEPT
      ip6tables -A OUTPUT -p tcp --dport 53 -j ACCEPT

      for domain in "${DOMAINS[@]}"; do
        [ -z "$domain" ] && continue
        while IFS=' ' read -r ip _rest; do
          [ -z "$ip" ] && continue
          ip6tables -A OUTPUT -d "$ip" -j ACCEPT
        done < <(getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
      done
    fi

    echo "Network filtering active: ${WRAPIX_NETWORK_ALLOWLIST:-}" >&2
  else
    echo "Warning: iptables not available, network filtering disabled" >&2
    echo "  WRAPIX_NETWORK=limit requires NET_ADMIN capability (microVM recommended)" >&2
  fi
fi

# Session audit trail: write structured log entry on exit
# Log format documented in specs/security-review.md
write_session_log() {
  local exit_code="${1:-0}"
  local end_epoch
  end_epoch=$(date +%s)
  local end_iso
  end_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local duration=$(( end_epoch - SESSION_START_EPOCH ))

  local mode="interactive"
  if [ "${RALPH_MODE:-}" = "1" ]; then
    mode="ralph"
  fi

  # Read bead ID if ralph wrote one during the session
  local bead_id=""
  if [ -f /tmp/wrapix-bead-id ]; then
    bead_id=$(cat /tmp/wrapix-bead-id 2>/dev/null || true)
  fi

  # Find most recent claude session ID from history
  local claude_session_id=""
  if [ -f /workspace/.claude/history.jsonl ]; then
    claude_session_id=$(tail -1 /workspace/.claude/history.jsonl 2>/dev/null \
      | jq -r '.sessionId // empty' 2>/dev/null || true)
  fi

  mkdir -p /workspace/.wrapix/log
  local log_file="/workspace/.wrapix/log/${SESSION_START_ISO//[:.]/-}.json"

  # Build JSON with jq to ensure proper escaping
  jq -n \
    --arg start "$SESSION_START_ISO" \
    --arg end "$end_iso" \
    --argjson duration "$duration" \
    --argjson exit_code "$exit_code" \
    --arg mode "$mode" \
    --arg bead_id "$bead_id" \
    --arg session_id "${WRAPIX_SESSION_ID:-}" \
    --arg claude_session_id "$claude_session_id" \
    --arg claude_session_dir "/workspace/.claude" \
    '{
      timestamp_start: $start,
      timestamp_end: $end,
      duration_seconds: $duration,
      exit_code: $exit_code,
      mode: $mode,
      bead_id: (if $bead_id == "" then null else $bead_id end),
      wrapix_session_id: (if $session_id == "" then null else $session_id end),
      claude_session_id: (if $claude_session_id == "" then null else $claude_session_id end),
      claude_session_dir: $claude_session_dir
    }' > "$log_file" 2>/dev/null || true
}

# Run main process (without exec, so EXIT trap can write session log)
MAIN_EXIT=0
if [ $# -gt 0 ]; then
  # Command override: run the specified command instead of Claude/Ralph
  "$@" || MAIN_EXIT=$?
elif [ "${RALPH_MODE:-}" = "1" ]; then
  # RALPH_CMD and RALPH_ARGS set by launcher (default: help)
  # shellcheck disable=SC2086 # Intentional word splitting for RALPH_ARGS
  ralph "${RALPH_CMD:-help}" ${RALPH_ARGS:-} || MAIN_EXIT=$?
else
  claude --dangerously-skip-permissions --append-system-prompt "$SYSTEM_PROMPT" || MAIN_EXIT=$?
fi

write_session_log "$MAIN_EXIT"
exit "$MAIN_EXIT"
