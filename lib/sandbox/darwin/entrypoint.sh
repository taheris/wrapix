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

# Set up SSH configuration
# Note: known_hosts directory is bind-mounted from Nix store (VirtioFS only supports dirs)
mkdir -p "$HOME/.ssh"
[ -f "$HOME/.ssh/known_hosts_dir/known_hosts" ] && cp "$HOME/.ssh/known_hosts_dir/known_hosts" "$HOME/.ssh/known_hosts"

# Configure SSH to use deploy key if available (Darwin mounts to /home/$USER/.ssh/deploy_keys/)
if [ -d "$HOME/.ssh/deploy_keys" ] && [ -n "$(ls -A $HOME/.ssh/deploy_keys 2>/dev/null)" ]; then
  DEPLOY_KEY=$(ls $HOME/.ssh/deploy_keys/* | head -1)
  cat > "$HOME/.ssh/config" <<EOF
Host github.com
    HostName github.com
    User git
    IdentityFile $DEPLOY_KEY
    IdentitiesOnly yes
EOF
  chmod 600 "$HOME/.ssh/config"
fi

# Fix ownership and permissions (known_hosts is read-only mount, skip it)
chown "$HOST_UID:$HOST_UID" "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
[ -f "$HOME/.ssh/config" ] && chown "$HOST_UID:$HOST_UID" "$HOME/.ssh/config"

# Copy directories from staging to destination with correct ownership
# VirtioFS maps files as root, so we copy and fix ownership
if [ -n "${WRAPIX_DIR_MOUNTS:-}" ]; then
    IFS=',' read -ra DIR_MOUNTS <<< "$WRAPIX_DIR_MOUNTS"
    for mapping in "${DIR_MOUNTS[@]}"; do
        src="${mapping%%:*}"
        dst=$(eval echo "${mapping#*:}")
        if [ -d "$src" ]; then
            mkdir -p "$(dirname "$dst")"
            cp -r "$src" "$dst"
            chown -R "$HOST_UID:$HOST_UID" "$dst"
        fi
    done
fi

# Copy files from staging to destination with correct ownership
if [ -n "${WRAPIX_FILE_MOUNTS:-}" ]; then
    IFS=',' read -ra MOUNTS <<< "$WRAPIX_FILE_MOUNTS"
    for mapping in "${MOUNTS[@]}"; do
        src="${mapping%%:*}"
        dst=$(eval echo "${mapping#*:}")
        if [ -f "$src" ]; then
            mkdir -p "$(dirname "$dst")"
            cp "$src" "$dst"
            chown "$HOST_UID:$HOST_UID" "$dst"
        fi
    done
fi

cd /workspace

exec setpriv --reuid="$HOST_UID" --regid="$HOST_UID" --init-groups \
  claude --dangerously-skip-permissions --append-system-prompt "$(cat /etc/wrapix/wrapix-prompt)"
