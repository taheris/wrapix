#!/bin/bash
# extract-oauth-token.sh - Extract Claude OAuth token from Keychain for Linux container
#
# Claude Code stores OAuth credentials in macOS Keychain, but the Linux container
# expects them in ~/.claude/.credentials.json. This script extracts the token
# and writes it to the correct location.
#
# Usage: Run once after logging into Claude Code (run 'claude' and use /login)
#
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
CREDENTIALS_FILE="$CLAUDE_DIR/.credentials.json"
KEYCHAIN_SERVICE="Claude Code-credentials"

# Check if .claude directory exists
if [ ! -d "$CLAUDE_DIR" ]; then
  echo "Error: $CLAUDE_DIR not found."
  echo "Run 'claude' first to create it, then use /login to authenticate."
  exit 1
fi

# Extract OAuth token from Keychain
echo "Extracting OAuth token from Keychain..."
if ! OAUTH_TOKEN=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null); then
  echo "Error: Could not read '$KEYCHAIN_SERVICE' from Keychain."
  echo ""
  echo "Make sure you're logged into Claude Code:"
  echo "  1. Run 'claude' in terminal"
  echo "  2. Use /login to authenticate"
  echo "  3. Run this script again"
  exit 1
fi

# Check if token is non-empty
if [ -z "$OAUTH_TOKEN" ]; then
  echo "Error: OAuth token is empty."
  exit 1
fi

# Check if credentials file already exists
if [ -f "$CREDENTIALS_FILE" ]; then
  echo "Credentials file already exists at $CREDENTIALS_FILE"
  read -p "Overwrite? [y/N] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# Write token to credentials file
echo "Writing token to $CREDENTIALS_FILE..."
echo "$OAUTH_TOKEN" > "$CREDENTIALS_FILE"
chmod 600 "$CREDENTIALS_FILE"

echo ""
echo "✓ OAuth token written to ~/.claude/.credentials.json"
echo ""
echo "You can now run wrapix:"
echo "  nix run .#wrapix -- /path/to/project"
