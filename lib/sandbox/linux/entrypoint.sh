#!/bin/bash
set -euo pipefail

# Add user entry with host UID (passwd is writable at runtime)
echo "$HOST_USER:x:$HOST_UID:$HOST_UID::/workspace:/bin/bash" >> /etc/passwd
echo "$HOST_USER:x:$HOST_UID:" >> /etc/group

export USER="$HOST_USER"
export HOME="/workspace"

# Set up SSH configuration
# Note: known_hosts is bind-mounted from Nix store
mkdir -p "$HOME/.ssh"

# Configure SSH to use deploy key if available
if [ -n "${DEPLOY_KEY_NAME:-}" ] && [ -f "$HOME/.ssh/deploy_keys/$DEPLOY_KEY_NAME" ]; then
  cat > "$HOME/.ssh/config" <<EOF
Host github.com
    HostName github.com
    User git
    IdentityFile $HOME/.ssh/deploy_keys/$DEPLOY_KEY_NAME
    IdentitiesOnly yes
EOF
  chmod 600 "$HOME/.ssh/config"
fi

# Fix ownership and permissions (known_hosts is read-only mount, skip it)
chown "$HOST_UID:$HOST_UID" "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
[ -f "$HOME/.ssh/config" ] && chown "$HOST_UID:$HOST_UID" "$HOME/.ssh/config"

cd /workspace

exec setpriv --reuid="$HOST_UID" --regid="$HOST_UID" --init-groups \
  claude --dangerously-skip-permissions --append-system-prompt "$(cat /etc/wrapix-prompt)"
