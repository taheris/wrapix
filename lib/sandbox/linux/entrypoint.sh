#!/bin/bash
set -euo pipefail

cd /workspace

# Nix flake check note:
# The container's /nix/store is incomplete (runtime packages only, no build deps).
# Full `nix flake check` requires the host's complete Nix store.
# Use `nix flake check --no-build` to verify evaluation without building.
# For full checks, run outside the container on a host with Nix installed.

# Configure SSH to use deploy key if available
# Use GIT_SSH_COMMAND instead of config file to avoid permission issues
# (the .ssh directory may be created by the known_hosts bind mount with root ownership)
if [ -n "${WRAPIX_DEPLOY_KEY:-}" ] && [ -f "$WRAPIX_DEPLOY_KEY" ]; then
  export GIT_SSH_COMMAND="ssh -i $WRAPIX_DEPLOY_KEY -o IdentitiesOnly=yes"
fi

# Initialize container-local beads database from workspace JSONL if available
# This provides isolation while syncing changes back via JSONL -> host daemon
if [ -f /workspace/.beads/issues.jsonl ] && [ -f /workspace/.beads/config.yaml ]; then
  PREFIX=$(yq -r '.["issue-prefix"] // ""' /workspace/.beads/config.yaml 2>/dev/null || echo "")
  if [ -n "$PREFIX" ]; then
    bd init --prefix "$PREFIX" --from-jsonl --quiet
  fi
fi

exec claude --dangerously-skip-permissions --append-system-prompt "$(cat /etc/wrapix-prompt)"
