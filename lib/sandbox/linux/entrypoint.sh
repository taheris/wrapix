#!/bin/bash
set -euo pipefail

cd /workspace

# Configure SSH to use deploy key if available
# Use GIT_SSH_COMMAND instead of config file to avoid permission issues
# (the .ssh directory may be created by the known_hosts bind mount with root ownership)
if [ -n "${WRAPIX_DEPLOY_KEY:-}" ] && [ -f "$WRAPIX_DEPLOY_KEY" ]; then
  export GIT_SSH_COMMAND="ssh -i $WRAPIX_DEPLOY_KEY -o IdentitiesOnly=yes"

  # Configure git SSH signing using deploy key
  git config --global gpg.format ssh
  git config --global user.signingkey "$WRAPIX_DEPLOY_KEY"

  # Create allowed_signers for signature verification
  # Write temp file to writable location (deploy key dir may be read-only mount)
  mkdir -p "$HOME/.config/git"
  PUBKEY_TMP="$HOME/.config/git/deploy_key.pub.tmp"
  if ssh-keygen -y -f "$WRAPIX_DEPLOY_KEY" > "$PUBKEY_TMP" 2>/dev/null; then
    echo "${GIT_AUTHOR_EMAIL:-sandbox@wrapix.dev} $(cat "$PUBKEY_TMP")" > "$HOME/.config/git/allowed_signers"
    rm "$PUBKEY_TMP"
    git config --global gpg.ssh.allowedSignersFile "$HOME/.config/git/allowed_signers"
  fi
fi

# Enable auto-signing if requested
if [ "${WRAPIX_GIT_SIGN:-}" = "1" ] || [ "${WRAPIX_GIT_SIGN:-}" = "true" ]; then
  git config --global commit.gpgsign true
fi

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

exec claude --dangerously-skip-permissions --append-system-prompt "$(cat /etc/wrapix-prompt)"
