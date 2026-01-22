#!/bin/bash
# Shared Claude configuration initialization for containers
# Source this script in entrypoint.sh to initialize .claude.json

# Initialize Claude config if not present (suppress onboarding prompts)
if [ ! -f "$HOME/.claude.json" ]; then
  cat > "$HOME/.claude.json" <<'EOF'
{
  "hasCompletedOnboarding": true,
  "autoUpdates": false,
  "numStartups": 1,
  "bypassPermissionsModeAccepted": true,
  "officialMarketplaceAutoInstallAttempted": true
}
EOF
fi
