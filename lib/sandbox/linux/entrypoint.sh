#!/bin/bash
set -euo pipefail
cd /workspace
exec claude --dangerously-skip-permissions --append-system-prompt "$(cat /etc/wrapix-prompt)"
