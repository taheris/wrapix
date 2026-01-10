#!/bin/bash
set -euo pipefail

# Create writable overlay on /nix to enable Nix builds
# The container image has /nix/store populated but read-only; fuse-overlayfs makes it writable
# This allows both store writes and creation of /nix/var/nix for the database
if [ -c /dev/fuse ] && command -v fuse-overlayfs >/dev/null 2>&1; then
  mkdir -p /tmp/nix-upper /tmp/nix-work
  fuse-overlayfs -o lowerdir=/nix,upperdir=/tmp/nix-upper,workdir=/tmp/nix-work /nix 2>/dev/null || true
fi

cd /workspace

# Configure SSH to use deploy key if available
if [ -n "${WRAPIX_DEPLOY_KEY:-}" ] && [ -f "$WRAPIX_DEPLOY_KEY" ]; then
  mkdir -p "$HOME/.ssh"
  cat > "$HOME/.ssh/config" <<EOF
Host github.com
    HostName github.com
    User git
    IdentityFile $WRAPIX_DEPLOY_KEY
    IdentitiesOnly yes
EOF
  chmod 600 "$HOME/.ssh/config"
  chmod 700 "$HOME/.ssh"
fi

# Initialize container-local beads database from workspace JSONL if available
# This provides isolation while syncing changes back via JSONL -> host daemon
if [ -f /workspace/.beads/issues.jsonl ] && [ -f /workspace/.beads/config.yaml ]; then
  PREFIX=$(grep 'issue-prefix:' /workspace/.beads/config.yaml | sed 's/.*"\([^"]*\)".*/\1/' || echo "")
  if [ -n "$PREFIX" ]; then
    bd init --prefix "$PREFIX" --from-jsonl --quiet 2>/dev/null || true
  fi
fi

exec claude --dangerously-skip-permissions --append-system-prompt "$(cat /etc/wrapix-prompt)"
