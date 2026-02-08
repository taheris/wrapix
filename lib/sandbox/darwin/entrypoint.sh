#!/bin/bash
set -euo pipefail

# Update wrapix user to use host UID (passwd is writable at runtime)
# The wrapix user is pre-created in the image with UID 1000; we update it to match host
sed -i "s/^wrapix:x:1000:1000:/wrapix:x:$HOST_UID:$HOST_UID:/" /etc/passwd
sed -i "s/^wrapix:x:1000:/wrapix:x:$HOST_UID:/" /etc/group

export USER="wrapix"
export HOME="/home/wrapix"

# Fix home directory ownership (image has 1000:1000, we need HOST_UID)
chown "$HOST_UID:$HOST_UID" "$HOME"

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

# Copy directories from staging to destination with correct ownership
# VirtioFS maps files as root, so we copy and fix ownership
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
            chown -R "$HOST_UID:$HOST_UID" "$dst"
        fi
    done
fi

# Copy files from staging to destination with correct ownership
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
            chown "$HOST_UID:$HOST_UID" "$dst"
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
    chown "$HOST_UID:$HOST_UID" "$HOME/.config/git/allowed_signers"
  fi
  chown -R "$HOST_UID:$HOST_UID" "$HOME/.config"

  # Enable auto-signing by default when signing key is configured
  # Set WRAPIX_GIT_SIGN=0 to disable
  if [ "${WRAPIX_GIT_SIGN:-1}" != "0" ]; then
    git config --global commit.gpgsign true
  fi
fi

# Fix ownership and permissions
chown "$HOST_UID:$HOST_UID" "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
[ -f "$HOME/.ssh/config" ] && chown "$HOST_UID:$HOST_UID" "$HOME/.ssh/config"

cd /workspace

# Initialize Claude config (always update to match container image)
mkdir -p "$HOME/.claude"
cp /etc/wrapix/claude-config.json "$HOME/.claude.json"
cp /etc/wrapix/claude-settings.json "$HOME/.claude/settings.json"
chmod 644 "$HOME/.claude.json" "$HOME/.claude/settings.json"
# Note: $HOME/.claude is a VirtioFS mount, so we can't chown the directory itself
chown "$HOST_UID:$HOST_UID" "$HOME/.claude.json" "$HOME/.claude/settings.json"

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
      bd init --prefix "$PREFIX" --backend dolt --quiet 2>/dev/null || true
    elif [ -f /workspace/.beads/issues.jsonl ]; then
      # SQLite/fallback mode: init from JSONL
      bd init --prefix "$PREFIX" --from-jsonl --quiet
    fi
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

# Check for ralph mode
if [ "${RALPH_MODE:-}" = "1" ]; then
  # RALPH_CMD and RALPH_ARGS set by launcher (default: help)
  # shellcheck disable=SC2086 # Intentional word splitting for RALPH_ARGS
  exec setpriv --reuid="$HOST_UID" --regid="$HOST_UID" --init-groups \
    ralph "${RALPH_CMD:-help}" ${RALPH_ARGS:-}
else
  exec setpriv --reuid="$HOST_UID" --regid="$HOST_UID" --init-groups \
    claude --dangerously-skip-permissions --append-system-prompt "$SYSTEM_PROMPT"
fi
