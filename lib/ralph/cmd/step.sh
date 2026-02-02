#!/usr/bin/env bash
set -euo pipefail

# DEPRECATED: Use 'ralph run --once' instead
# This command forwards to ralph-run with --once flag

echo "Warning: 'ralph step' is deprecated. Use 'ralph run --once' instead." >&2

exec ralph-run --once "$@"
