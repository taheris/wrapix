#!/bin/bash
set -euo pipefail

# Add user entry with host UID (passwd is writable at runtime)
# Note: home directory must be /home/$HOST_USER to match where we copy .claude.json
echo "$HOST_USER:x:$HOST_UID:$HOST_UID::/home/$HOST_USER:/bin/bash" >> /etc/passwd
echo "$HOST_USER:x:$HOST_UID:" >> /etc/group

export USER="$HOST_USER"

# Use container-local HOME for Darwin VMs (VirtioFS maps files as root)
mkdir -p "/home/$HOST_USER"
chown "$HOST_UID:$HOST_UID" "/home/$HOST_USER"
export HOME="/home/$HOST_USER"

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
# The mount uses literal $USER path due to VirtioFS constraints
mkdir -p "$HOME/.ssh"
# shellcheck disable=SC2016 # $USER is intentionally literal - VirtioFS mount path
KNOWN_HOSTS_SRC='/home/$USER/.ssh/known_hosts_dir/known_hosts'
[ -f "$KNOWN_HOSTS_SRC" ] && cp "$KNOWN_HOSTS_SRC" "$HOME/.ssh/known_hosts"

# Configure SSH to use deploy key if available (copied by WRAPIX_FILE_MOUNTS above)
# Expand $USER in the path since FILE_MOUNTS copies to the expanded destination
WRAPIX_DEPLOY_KEY=$(expand_path "${WRAPIX_DEPLOY_KEY:-}")
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
WRAPIX_SIGNING_KEY=$(expand_path "${WRAPIX_SIGNING_KEY:-}")
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

# Initialize rustup with stable toolchain and rust-analyzer if RUSTUP_HOME is set
# Use "rustup which cargo" instead of "rustup show active-toolchain" because the latter
# can succeed when toolchain is configured but binaries don't exist (e.g., stale RUSTUP_HOME)
if [ -n "${RUSTUP_HOME:-}" ] && command -v rustup &>/dev/null; then
  if ! rustup which cargo &>/dev/null 2>&1; then
    rustup default stable
    rustup component add rust-analyzer
  fi
fi

# Initialize container-local beads database from workspace JSONL if available
# This provides isolation while syncing changes back via JSONL -> host daemon
if [ -f /workspace/.beads/issues.jsonl ] && [ -f /workspace/.beads/config.yaml ]; then
  PREFIX=$(yq -r '.["issue-prefix"] // ""' /workspace/.beads/config.yaml 2>/dev/null || echo "")
  if [ -n "$PREFIX" ]; then
    bd init --prefix "$PREFIX" --from-jsonl --quiet
  fi
fi

exec setpriv --reuid="$HOST_UID" --regid="$HOST_UID" --init-groups \
  claude --dangerously-skip-permissions --append-system-prompt "$(cat /etc/wrapix/wrapix-prompt)"
