#!/bin/bash
set -euo pipefail

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

# Initialize Claude settings if not already present (from workspace mount)
if [ ! -f "$HOME/.claude/settings.json" ]; then
  mkdir -p "$HOME/.claude"
  cp /etc/wrapix/claude-settings.json "$HOME/.claude/settings.json"
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

# Initialize container-local beads database
# Detect backend from metadata.json and use appropriate init strategy
if [ -f /workspace/.beads/config.yaml ]; then
  PREFIX=$(yq -r '.["issue-prefix"] // ""' /workspace/.beads/config.yaml 2>/dev/null || echo "")
  if [ -n "$PREFIX" ]; then
    # Check for Dolt backend (metadata.json will have "backend": "dolt" after migration)
    BACKEND=$(jq -r '.backend // "sqlite"' /workspace/.beads/metadata.json 2>/dev/null || echo "sqlite")

    if [ "$BACKEND" = "dolt" ] && [ -d /workspace/.beads/dolt-remote ]; then
      # Dolt mode: copy dolt-remote as working database, then init
      mkdir -p /workspace/.beads/dolt
      cp -r /workspace/.beads/dolt-remote/. /workspace/.beads/dolt/beads/
      bd init --prefix "$PREFIX" --backend dolt --quiet 2>/dev/null || true
    elif [ -f /workspace/.beads/issues.jsonl ]; then
      # SQLite/fallback mode: init from JSONL
      bd init --prefix "$PREFIX" --from-jsonl --quiet
    fi
  fi
fi

exec claude --dangerously-skip-permissions --append-system-prompt "$(cat /etc/wrapix-prompt)"
