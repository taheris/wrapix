#!/bin/bash
set -euo pipefail

# Record session start for audit trail
SESSION_START_EPOCH=$(date +%s)
SESSION_START_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# UID mapping strategy for Darwin VirtioFS:
#
# VirtioFS maps all files to UID 0 inside the container. To get correct UID
# matching, we use unshare(1) to create a user namespace at exec time that
# maps inner HOST_UID to outer UID 0. This means:
#   - Setup runs as root (can modify /etc/passwd, create files, set permissions)
#   - All root-owned files automatically appear as HOST_UID inside the namespace
#   - VirtioFS mounts (/workspace) appear as HOST_UID — no ownership mismatch
#   - No chown to HOST_UID needed (counterproductive: outer HOST_UID maps to nobody)
#
# Compare Linux entrypoint which uses Podman's --userns=keep-id for the same effect.

# Update wrapix user to use host UID so id(1) resolves the correct username
sed -i "s/^wrapix:x:1000:1000:/wrapix:x:$HOST_UID:$HOST_UID:/" /etc/passwd
sed -i "s/^wrapix:x:1000:/wrapix:x:$HOST_UID:/" /etc/group

export USER="wrapix"
export HOME="/home/wrapix"

# Safe path expansion: only expand ~ and $HOME/$USER, not arbitrary commands
expand_path() {
    local p="$1"
    p="${p/#\~/$HOME}"
    p="${p//\$HOME/$HOME}"
    p="${p//\$USER/$USER}"
    echo "$p"
}

# Validate mount mapping format: must be "src:dst" with exactly one colon
validate_mount_mapping() {
    local mapping="$1"
    [[ "$mapping" =~ ^[^:]+:[^:]+$ ]]
}

# Copy directories from staging to destination
# VirtioFS maps files as root; unshare namespace remaps root to HOST_UID
# This must run BEFORE SSH setup so deploy keys are in place
if [ -n "${WRAPIX_DIR_MOUNTS:-}" ]; then
    IFS=',' read -ra DIR_MOUNTS <<< "$WRAPIX_DIR_MOUNTS"
    for mapping in "${DIR_MOUNTS[@]}"; do
        [ -z "$mapping" ] && continue
        if ! validate_mount_mapping "$mapping"; then
            echo "Warning: Skipping malformed dir mount: $mapping" >&2
            continue
        fi
        src="${mapping%%:*}"
        dst=$(expand_path "${mapping#*:}")
        if [ -d "$src" ]; then
            mkdir -p "$(dirname "$dst")"
            cp -r "$src" "$dst"
        fi
    done
fi

# Copy files from staging to destination
# This includes deploy keys which are needed for SSH config
if [ -n "${WRAPIX_FILE_MOUNTS:-}" ]; then
    IFS=',' read -ra MOUNTS <<< "$WRAPIX_FILE_MOUNTS"
    for mapping in "${MOUNTS[@]}"; do
        [ -z "$mapping" ] && continue
        if ! validate_mount_mapping "$mapping"; then
            echo "Warning: Skipping malformed file mount: $mapping" >&2
            continue
        fi
        src="${mapping%%:*}"
        dst=$(expand_path "${mapping#*:}")
        if [ -f "$src" ]; then
            mkdir -p "$(dirname "$dst")"
            cp "$src" "$dst"
        fi
    done
fi

# Fix socket permissions - VirtioFS may mount sockets with 0000 permissions
if [ -n "${WRAPIX_SOCK_MOUNTS:-}" ]; then
    IFS=',' read -ra SOCKS <<< "$WRAPIX_SOCK_MOUNTS"
    for sock in "${SOCKS[@]}"; do
        [ -z "$sock" ] && continue
        sock=$(expand_path "$sock")
        if [ -e "$sock" ]; then
            chmod 777 "$sock" 2>/dev/null || true
        fi
    done
fi

# Set up SSH configuration
# Note: known_hosts directory is bind-mounted from Nix store (VirtioFS only supports dirs)
mkdir -p "$HOME/.ssh"
KNOWN_HOSTS_SRC="$HOME/.ssh/known_hosts_dir/known_hosts"
[ -f "$KNOWN_HOSTS_SRC" ] && cp "$KNOWN_HOSTS_SRC" "$HOME/.ssh/known_hosts"

# Configure SSH to use deploy key if available (copied by WRAPIX_FILE_MOUNTS above)
WRAPIX_DEPLOY_KEY="${WRAPIX_DEPLOY_KEY:-}"
if [ -n "${WRAPIX_DEPLOY_KEY:-}" ] && [ -f "$WRAPIX_DEPLOY_KEY" ]; then
  cat > "$HOME/.ssh/config" <<EOF
Host github.com
    HostName github.com
    User git
    IdentityFile $WRAPIX_DEPLOY_KEY
    IdentitiesOnly yes
EOF
  chmod 600 "$HOME/.ssh/config"
fi

# Configure git SSH signing using separate signing key
# (GitHub doesn't allow same key for deploy and signing)
WRAPIX_SIGNING_KEY="${WRAPIX_SIGNING_KEY:-}"
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

# Fix permissions
chmod 700 "$HOME/.ssh"

cd /workspace

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
      # Dolt mode: copy dolt-remote as working database, then init
      mkdir -p /workspace/.beads/dolt
      cp -r "$DOLT_REMOTE/." /workspace/.beads/dolt/beads/
      bd init --prefix "$PREFIX" --backend dolt --quiet --skip-hooks --skip-merge-driver 2>/dev/null || true
      # bd init overwrites .gitignore with its template (missing dolt/ rule)
      git checkout -- .beads/.gitignore 2>/dev/null || true
    elif [ -f /workspace/.beads/issues.jsonl ]; then
      # SQLite/fallback mode: init from JSONL
      bd init --prefix "$PREFIX" --from-jsonl --quiet --skip-hooks --skip-merge-driver
    fi
    # bd init generates AGENTS.md; restore workspace copy if it existed
    git checkout -- AGENTS.md 2>/dev/null || true
  fi
fi

# Build system prompt with optional context pinning
SYSTEM_PROMPT=$(cat /etc/wrapix-prompts/wrapix-prompt)

# Context pinning: append specs/README.md if it exists
if [ -f /workspace/specs/README.md ]; then
  SYSTEM_PROMPT="$SYSTEM_PROMPT

## Project Context (from specs/README.md)

$(cat /workspace/specs/README.md)"
fi

# Apply network filtering when WRAPIX_NETWORK=limit
# Runs as root (before unshare), so iptables works without extra capabilities
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

# Drop to HOST_UID via user namespace (maps inner HOST_UID to outer root,
# so VirtioFS root-owned files appear as HOST_UID — proper UID mapping)
# Run without exec so session log can be written after exit
MAIN_EXIT=0
if [ $# -gt 0 ]; then
  # Command override: run the specified command instead of Claude/Ralph
  unshare --user --map-user="$HOST_UID" --map-group="$HOST_UID" -- \
    "$@" || MAIN_EXIT=$?
elif [ "${RALPH_MODE:-}" = "1" ]; then
  # RALPH_CMD and RALPH_ARGS set by launcher (default: help)
  # shellcheck disable=SC2086 # Intentional word splitting for RALPH_ARGS
  unshare --user --map-user="$HOST_UID" --map-group="$HOST_UID" -- \
    ralph "${RALPH_CMD:-help}" ${RALPH_ARGS:-} || MAIN_EXIT=$?
else
  unshare --user --map-user="$HOST_UID" --map-group="$HOST_UID" -- \
    claude --dangerously-skip-permissions --append-system-prompt "$SYSTEM_PROMPT" || MAIN_EXIT=$?
fi

write_session_log "$MAIN_EXIT"
exit "$MAIN_EXIT"
