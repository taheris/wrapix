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
exec claude --dangerously-skip-permissions --append-system-prompt "$(cat /etc/wrapix-prompt)"
