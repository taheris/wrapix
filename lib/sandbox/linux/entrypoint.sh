#!/bin/bash
set -euo pipefail

# Add user entry with host UID (passwd is writable at runtime)
echo "$HOST_USER:x:$HOST_UID:$HOST_UID::/workspace:/bin/bash" >> /etc/passwd
echo "$HOST_USER:x:$HOST_UID:" >> /etc/group

export USER="$HOST_USER"
export HOME="/workspace"

cd /workspace

exec setpriv --reuid="$HOST_UID" --regid="$HOST_UID" --init-groups \
  claude --dangerously-skip-permissions --append-system-prompt "$WRAPIX_PROMPT"
